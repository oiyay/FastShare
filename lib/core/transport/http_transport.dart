import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  void _sendBroadcast() async {
    if (_selfInfo == null || _udpSocket == null) return;

    try {
      final data = utf8.encode(_selfInfo!.toJsonString());

      // Global broadcast (works on some networks)
      _udpSocket!.send(data, InternetAddress('255.255.255.255'), _udpPort);

      // Subnet-specific broadcasts (critical for Mobile Hotspots and Windows Multi-NIC)
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            // Assume /24 subnet (standard for hotspots and home Wi-Fi)
            // e.g., 192.168.43.51 -> 192.168.43.255
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              parts[3] = '255';
              final subnetBroadcast = parts.join('.');
              try {
                _udpSocket!.send(data, InternetAddress(subnetBroadcast), _udpPort);
              } catch (_) {}
            }
          }
        }
      }
    } catch (e) {
      print('[HttpTransport] Broadcast error: $e');
    }
  }

  void _handleDiscoveryPacket(Datagram datagram) {
    try {
      final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;

      DeviceInfo? device;

      if (json['app'] == 'FastShare') {
        // FastShare Protocol
        device = DeviceInfo.fromJson(json);
      } else if (json.containsKey('alias') && json.containsKey('fingerprint')) {
        // LocalSend Protocol Intercept!
        // LocalSend sends: alias, version, deviceModel, deviceType, fingerprint, port, protocol
        device = DeviceInfo(
          id: json['fingerprint'] ?? 'localsend-${datagram.address.address}',
          name: '${json['alias'] ?? 'LocalSend Device'}',
          os: (json['deviceModel'] ?? 'Unknown').toString().toLowerCase(),
          ip: datagram.address.address,
          port: json['port'] ?? 53317,
          protocol: 'localsend',
        );
      } else {
        // Unknown protocol
        return;
      }

      // Ignore self (matching ID)
      if (_selfInfo != null && device.id == _selfInfo!.id) return;

      // Update or add device
      final updated = device.copyWith(
        ip: datagram.address.address, // Always trust the actual packet IP
        lastSeen: DateTime.now(),
      );
      
      _discoveredDevices[updated.id] = updated;
      _deviceController.add(updated);

      // Cleanup stale devices
      _cleanupStaleDevices();
    } catch (e) {
      // Ignore malformed packets
    }
  }

  /// Remove devices that haven't been seen for 10+ seconds.
  void _cleanupStaleDevices() {
    final now = DateTime.now();
    final staleIds = <String>[];
    for (final entry in _discoveredDevices.entries) {
      if (now.difference(entry.value.lastSeen).inSeconds > 10) {
        staleIds.add(entry.key);
      }
    }
    for (final id in staleIds) {
      _discoveredDevices.remove(id);
    }
  }

  // ──────────────────────────────────────────
  // HTTP SERVER (Receiving files)
  // ──────────────────────────────────────────

  Future<void> _startHttpServer() async {
    try {
      // Pipeline without compression — file data is already binary/compressed
      final handler = const shelf.Pipeline().addHandler(_router);
      _httpServer = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        0,
        shared: true,
        poweredByHeader: null, // remove unnecessary header
      );
      _httpServer!.autoCompress = false; // don't waste CPU compressing binary file data
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
    if (request.method == 'GET' && path == 'api/info') {
      return shelf.Response.ok(
        jsonEncode({
          'app': 'FastShare',
          'version': '2.0',
          'protocol': 2,
          'device_name': _selfInfo?.name ?? 'Unknown',
          'os': _selfInfo?.os ?? 'unknown',
        }),
        headers: {'Content-Type': 'application/json'},
      );
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
      int lastProgressReport = 0;
      const int progressThrottleMs = 100;

      // Use a 1MB memory buffer to prevent Android FUSE filesystem bottleneck
      // Tiny writes to /storage/emulated/0 on Android 11+ cause massive overhead.
      final writeBuffer = BytesBuilder(copy: false);
      const int maxBufferSize = 1024 * 1024; // 1 MB

      await for (final chunk in request.read()) {
        writeBuffer.add(chunk);
        bytesReceived += chunk.length;

        // Flush buffer to disk when it reaches 1MB
        if (writeBuffer.length >= maxBufferSize) {
          sink.add(writeBuffer.takeBytes());
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        if (_progressCallbacks.containsKey(token) &&
            fileName != null &&
            (now - lastProgressReport) >= progressThrottleMs) {
          lastProgressReport = now;
          _progressCallbacks[token]!(fileName, bytesReceived / totalSize);
        }
      }

      // Flush any remaining data in the buffer
      if (writeBuffer.isNotEmpty) {
        sink.add(writeBuffer.takeBytes());
      }

      // Fire 100% completion
      if (_progressCallbacks.containsKey(token) && fileName != null) {
        _progressCallbacks[token]!(fileName, 1.0);
        _progressCallbacks.remove(token);
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
    // Verify device is reachable first
    try {
      final pingUri = Uri.parse('http://${target.ip}:${target.port}/api/ping');
      await http.get(pingUri).timeout(const Duration(seconds: 3));
    } on TimeoutException {
      throw Exception('Device "${target.name}" is unreachable (timeout)');
    } on SocketException {
      throw Exception('Device "${target.name}" is unreachable (connection refused)');
    } catch (e) {
      throw Exception('Device "${target.name}" is unreachable: $e');
    }

    // Send the actual transfer request
    try {
      final uri = Uri.parse('http://${target.ip}:${target.port}/api/prepare-receive');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: request.toJsonString(),
      ).timeout(const Duration(seconds: 65)); // 60s user decision + 5s buffer

      if (response.statusCode == 200) {
        return TransferResponse.fromJsonString(response.body);
      }

      throw Exception('Transfer request failed: ${response.statusCode}');
    } on TimeoutException {
      throw Exception('Transfer request to "${target.name}" timed out');
    } on SocketException {
      throw Exception('Lost connection to "${target.name}"');
    }
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
      '?token=$token&fileId=$fileId&fileName=${Uri.encodeComponent(fileName)}',
    );

    // STREAMING: Large 4MB chunks for maximum LAN throughput
    final request = http.StreamedRequest('POST', uri);
    request.headers['Content-Type'] = 'application/octet-stream';
    request.contentLength = fileSize;

    int bytesSent = 0;
    int lastProgressReport = 0;
    const int progressThrottleMs = 100; // Report UI progress max every 100ms

    // Transform stream to track progress WHILE respecting backpressure
    final progressStream = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          bytesSent += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (onProgress != null && (now - lastProgressReport) >= progressThrottleMs) {
            lastProgressReport = now;
            onProgress(bytesSent / fileSize);
          }
          sink.add(chunk); // Forward data to the HTTP sink
        },
      ),
    );

    final client = http.Client();
    try {
      // IMPORTANT: We must start the HTTP send() BEFORE or CONCURRENTLY 
      // while we add to the sink to prevent deadlocks and memory bloat.
      final responseFuture = client.send(request);

      // addStream respects backpressure. It will automatically PAUSE reading 
      // from the file disk if the Wi-Fi network socket is full.
      // This guarantees the progress bar accurately reflects network speed!
      await request.sink.addStream(progressStream);
      request.sink.close();
      onProgress?.call(1.0); // always fire 100% at end

      final response = await responseFuture;

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw Exception('File send failed: ${response.statusCode} - $body');
      }

      print('[HttpTransport] Sent file: $filePath');
    } catch (e) {
      request.sink.addError(e);
      request.sink.close();
      rethrow;
    } finally {
      client.close();
    }
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
