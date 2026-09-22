import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/transport/transport_interface.dart';

/// HTTP-based transport for cross-platform file sharing (Android <-> Windows).
///
/// Discovery: UDP broadcast on fixed port 53317
/// Transfer: HTTP server/client on a dynamically assigned port
class HttpTransport implements TransportInterface {
  static const int _udpPort = 53317;
  static const int _broadcastIntervalMs = 2000;

  final _uuid = Uuid();

  // UDP Discovery
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;
  DeviceInfo? _selfInfo;

  // HTTP Server
  HttpServer? _httpServer;
  int get httpPort => _httpServer?.port ?? 0;

  // Stream controllers
  final _deviceController = StreamController<DeviceInfo>.broadcast();
  final _requestController = StreamController<TransferRequest>.broadcast();

  // State
  final Map<String, DeviceInfo> _discoveredDevices = {};
  final Map<String, Completer<TransferResponse>> _pendingRequests = {};
  final Map<String, String> _acceptedTokens = {}; // token -> savePath
  final Map<String, void Function(String fileName, double progress)> _progressCallbacks = {};

  @override
  Future<void> initialize() async {
    await _startHttpServer();
  }

  @override
  Future<void> dispose() async {
    _broadcastTimer?.cancel();
    _udpSocket?.close();
    await _httpServer?.close();
    await _deviceController.close();
    await _requestController.close();
  }

  // ──────────────────────────────────────────
  // DISCOVERY via UDP Broadcast
  // ──────────────────────────────────────────

  @override
  Stream<DeviceInfo> discoverDevices() {
    _startUdpDiscovery();
    return _deviceController.stream;
  }

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {
    _selfInfo = selfInfo;
    _startUdpBroadcast();
  }

  @override
  Future<void> stopAdvertising() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
  }

  void _startUdpDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            _handleDiscoveryPacket(datagram);
          }
        }
      });

      print('[HttpTransport] UDP discovery started on port $_udpPort');
    } catch (e) {
      print('[HttpTransport] Failed to start UDP discovery: $e');
    }
  }

  void _startUdpBroadcast() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      Duration(milliseconds: _broadcastIntervalMs),
      (_) => _sendBroadcast(),
    );
    // Send first broadcast immediately
    _sendBroadcast();
  }

  void _sendBroadcast() {
    if (_selfInfo == null || _udpSocket == null) return;

    try {
      final data = utf8.encode(_selfInfo!.toJsonString());
      _udpSocket!.send(
        data,
        InternetAddress('255.255.255.255'),
        _udpPort,
      );
    } catch (e) {
      print('[HttpTransport] Broadcast error: $e');
    }
  }

  void _handleDiscoveryPacket(Datagram datagram) {
    try {
      final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;

      // Ignore non-FastShare packets
      if (json['app'] != 'FastShare') return;

      final device = DeviceInfo.fromJson(json);

      // Ignore self
      if (_selfInfo != null && device.id == _selfInfo!.id) return;

      // Update or add device
      final updated = device.copyWith(
        ip: datagram.address.address,
        lastSeen: DateTime.now(),
      );
      _discoveredDevices[updated.id] = updated;
      _deviceController.add(updated);
    } catch (e) {
      // Ignore malformed packets
    }
  }

  // ──────────────────────────────────────────
  // HTTP SERVER (Receiving files)
  // ──────────────────────────────────────────

  Future<void> _startHttpServer() async {
    try {
      final handler = const shelf.Pipeline().addHandler(_router);
      _httpServer = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0, shared: true);
      print('[HttpTransport] HTTP server running on dynamically assigned port $httpPort');
    } catch (e) {
      print('[HttpTransport] Failed to start HTTP server: $e');
    }
  }

  Future<shelf.Response> _router(shelf.Request request) async {
    final path = request.url.path;

    if (request.method == 'POST' && path == 'api/prepare-receive') {
      return _handlePrepareReceive(request);
    }
    if (request.method == 'POST' && path == 'api/receive') {
      return _handleReceiveFile(request);
    }
    if (request.method == 'GET' && path == 'api/ping') {
      return shelf.Response.ok(jsonEncode({'status': 'ok', 'app': 'FastShare'}));
    }

    return shelf.Response.notFound('Not found');
  }

  /// Handle incoming transfer request (handshake).
  Future<shelf.Response> _handlePrepareReceive(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final transferRequest = TransferRequest.fromJsonString(body);

      // Create a completer so we can wait for user's accept/reject
      final completer = Completer<TransferResponse>();
      _pendingRequests[transferRequest.senderId] = completer;

      // Notify listeners (UI will show accept/reject dialog)
      _requestController.add(transferRequest);

      // Wait for user decision (with 60s timeout)
      final response = await completer.future.timeout(
        Duration(seconds: 60),
        onTimeout: () => TransferResponse(accepted: false),
      );

      return shelf.Response.ok(
        response.toJsonString(),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  /// Handle incoming file data (streaming).
  Future<shelf.Response> _handleReceiveFile(shelf.Request request) async {
    final token = request.url.queryParameters['token'];
    final fileId = request.url.queryParameters['fileId'];
    final fileName = request.url.queryParameters['fileName'];

    if (token == null || !_acceptedTokens.containsKey(token)) {
      return shelf.Response.forbidden(jsonEncode({'error': 'Invalid token'}));
    }

    final savePath = _acceptedTokens[token]!;
    final filePath = '$savePath/$fileName';

    try {
      // STREAMING: Write directly to disk, never load full file to memory
      final file = File(filePath);
      final sink = file.openWrite();
      final totalSize = request.contentLength ?? 1;
      int bytesReceived = 0;

      await for (final chunk in request.read()) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (_progressCallbacks.containsKey(token) && fileName != null) {
          _progressCallbacks[token]!(fileName, bytesReceived / totalSize);
        }
      }

      await sink.flush();
      await sink.close();

      print('[HttpTransport] Received file: $filePath');
      return shelf.Response.ok(
        jsonEncode({'status': 'received', 'file_id': fileId}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      print('[HttpTransport] Error receiving file: $e');
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
      );
    }
  }

  // ──────────────────────────────────────────
  // HTTP CLIENT (Sending files)
  // ──────────────────────────────────────────

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request,
  ) async {
    final uri = Uri.parse('http://${target.ip}:${target.port}/api/prepare-receive');

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: request.toJsonString(),
    );

    if (response.statusCode == 200) {
      return TransferResponse.fromJsonString(response.body);
    }

    throw Exception('Transfer request failed: ${response.statusCode}');
  }

  @override
  Future<void> sendFile(
    DeviceInfo target,
    String token,
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    final fileSize = await file.length();
    final fileName = file.uri.pathSegments.last;

    final uri = Uri.parse(
      'http://${target.ip}:${target.port}/api/receive'
      '?token=$token&fileId=$fileId&fileName=$fileName',
    );

    // STREAMING: Read file in chunks and pipe to HTTP request
    final request = http.StreamedRequest('POST', uri);
    request.headers['Content-Type'] = 'application/octet-stream';
    request.contentLength = fileSize;

    int bytesSent = 0;

    // Pipe file stream with progress tracking
    file.openRead().listen(
      (chunk) {
        request.sink.add(chunk);
        bytesSent += chunk.length;
        onProgress?.call(bytesSent / fileSize);
      },
      onDone: () {
        request.sink.close();
      },
      onError: (error) {
        request.sink.addError(error);
      },
    );

    final response = await http.Client().send(request);

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception('File send failed: ${response.statusCode} - $body');
    }

    print('[HttpTransport] Sent file: $filePath');
  }

  // ──────────────────────────────────────────
  // Transfer Accept/Reject
  // ──────────────────────────────────────────

  @override
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  @override
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    final token = _uuid.v4();
    _acceptedTokens[token] = savePath;
    if (onProgress != null) {
      _progressCallbacks[token] = onProgress;
    }

    final completer = _pendingRequests.remove(request.senderId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(TransferResponse(accepted: true, token: token));
    }
  }

  @override
  Future<void> rejectTransfer(TransferRequest request) async {
    final completer = _pendingRequests.remove(request.senderId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(TransferResponse(accepted: false));
    }
  }

  /// Get the local IP address of this device.
  static Future<String> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface_ in interfaces) {
        for (final addr in interface_.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('[HttpTransport] Error getting local IP: $e');
    }
    return '0.0.0.0';
  }
}
