import 'package:fast_share/core/transport/webrtc_transport.dart';
import 'dart:async';
import 'dart:io';

import "package:cryptography/cryptography.dart" hide Hmac;
import "package:fast_share/core/services/signaling_service.dart";
import "package:fast_share/core/models/transfer_message.dart";
import "package:fast_share/core/services/database_service.dart";
import "package:fast_share/core/services/transfer_state_manager.dart";
import 'package:uuid/uuid.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/models/exceptions.dart';
import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/core/transport/transport_interface.dart';
import 'package:fast_share/core/transport/http_transport.dart';
import 'package:fast_share/core/transport/localsend_transport.dart';
import 'package:fast_share/core/transport/nearby_transport.dart';
import 'package:fast_share/core/transport/fastshare_tcp_transport.dart';
/// - Target is LocalSend: Use LocalSendTransport
/// - Target is FastShare: Use FastShareTcpTransport (Raw TCP Frame Protocol)
/// - Android <-> Android offline fallback: Use NearbyTransport
class TransportManager {
  static final TransportManager _instance = TransportManager._internal();
  factory TransportManager() => _instance;
  TransportManager._internal();

  final HttpTransport _httpTransport = HttpTransport();
  final NearbyTransport _nearbyTransport = NearbyTransport();
  final LocalSendTransport _localSendTransport = LocalSendTransport();
  final FastShareTcpTransport _tcpTransport = FastShareTcpTransport();
  final WebRtcTransport _webrtcTransport = WebRtcTransport();

  final _deviceController = StreamController<DeviceInfo>.broadcast();
  final _requestController = StreamController<TransferRequest>.broadcast();

  DeviceInfo? _selfInfo;
  bool _initialized = false;

  /// Initialize all available transport layers.
  Future<void> initialize() async {
    if (_initialized) return;

    await _tcpTransport.initialize();
    await _httpTransport.initialize();
    await _localSendTransport.initialize();
    await _webrtcTransport.initialize();

    final localIp = await HttpTransport.getLocalIp();
    final settings = SettingsService();
    final deviceName = settings.deviceName;
    final os = _getCurrentOS();

    _selfInfo = DeviceInfo(
      id: SettingsService().deviceId,
      name: deviceName,
      os: os,
      ip: localIp,
      port: _httpTransport.httpPort,
      tcpPort: _tcpTransport.tcpPort,
    );

    if (NearbyTransport.isSupported) {
      await _nearbyTransport.initialize();
    }

    _httpTransport.incomingRequests.listen((req) => _requestController.add(req));
    _localSendTransport.incomingRequests.listen((req) => _requestController.add(req));
    _tcpTransport.incomingRequests.listen((req) => _requestController.add(req));
    _webrtcTransport.incomingRequests.listen((req) => _requestController.add(req));
    if (NearbyTransport.isSupported) {
      _nearbyTransport.incomingRequests.listen((req) => _requestController.add(req));
    }

    settings.onSettingsChanged.listen((_) {
      if (_selfInfo != null) {
        final newName = settings.deviceName;
        if (_selfInfo!.name != newName) {
          _selfInfo = _selfInfo!.copyWith(name: newName);
          _httpTransport.startAdvertising(_selfInfo!);
          if (NearbyTransport.isSupported) {
            _nearbyTransport.startAdvertising(_selfInfo!);
          }
        }
      }
    });

    _initialized = true;
    print('[TransportManager] Initialized as ${_selfInfo!.name} ($os) at $localIp');
  }

  /// Start discovering devices and advertising self.
  Future<void> startDiscovery() async {
    if (_selfInfo == null) return;

    await _httpTransport.startAdvertising(_selfInfo!);
    _httpTransport.discoverDevices().listen((device) {
      _discoveredCache[device.id] = device;
      _deviceController.add(device);
    });

    if (NearbyTransport.isSupported) {
      try {
        await _nearbyTransport.startAdvertising(_selfInfo!);
        _nearbyTransport.discoverDevices().listen((device) {
          _discoveredCache[device.id] = device;
          _deviceController.add(device);
        });
      } catch (e) {
        print('[TransportManager] NearbyTransport failed to start (likely missing permissions): $e');
      }
    }
  }

  /// Trigger a manual refresh for devices
  void refreshDiscovery() {
    _discoveredCache.clear();
    _httpTransport.refreshDiscovery();
  }

  /// Stop all discovery and advertising.
  Future<void> stopDiscovery() async {
    await _httpTransport.stopAdvertising();
    if (NearbyTransport.isSupported) {
      await _nearbyTransport.stopAdvertising();
    }
  }

  /// Stream of discovered devices from all transports.
  final Map<String, DeviceInfo> _discoveredCache = {};

  Stream<DeviceInfo> get devices async* {
    for (final d in _discoveredCache.values) {
      yield d;
    }
    yield* _deviceController.stream;
  }

  /// Stream of incoming transfer requests from all transports.
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  /// Get current device info.
  DeviceInfo? get selfInfo => _selfInfo;

  /// Send file(s) to a target device.
  /// Automatically selects the best transport.

  /// Send a text chat message to a target device (P2P Local or Global).
  Future<void> sendChatText(DeviceInfo target, String text) async {
    if (_selfInfo == null) throw StateError('TransportManager not initialized');
    
    // Create DB entry first
    final payloadId = const Uuid().v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    
    final dbMsg = TransferMessage(
      id: payloadId,
      senderId: _selfInfo!.id,
      targetId: target.id,
      remoteName: target.name,
      messageType: 'text',
      textContent: text,
      timestamp: timestamp,
      isSentByMe: true,
      status: 'completed',
    );
    await DatabaseService().saveMessage(dbMsg);

    // Build payload and sign it
    final payload = {'id': payloadId, 'text': text, 'ts': timestamp};
    final payloadStr = jsonEncode(payload);

    final keyPair = SettingsService().keyPair;
    final sig = await Ed25519().sign(utf8.encode(payloadStr), keyPair: keyPair);
    final sigBase64 = base64Encode(sig.bytes);

    if (target.protocol == 'webrtc') {
      // Send via WebRTC Signaling Server
      await SignalingService().sendChatMessage(target.id, text);
    } else {
      // Send via Local HTTP POST
      final url = Uri.parse('http://${target.ip}:${target.port}/api/chat');
      final body = jsonEncode({
        'payload': payloadStr,
        'sig': sigBase64,
        'senderUid': _selfInfo!.id,
      });
      
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 3);
        final request = await client.postUrl(url);
        request.headers.contentType = ContentType.json;
        request.write(body);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw Exception('Target returned ${response.statusCode}');
        }
      } catch (e) {
        // If HTTP fails, mark as failed in DB
        await DatabaseService().updateMessageStatus(payloadId, 'failed');
        print('[TransportManager] Local chat delivery failed: $e');
        rethrow;
      }
    }
  }

  Future<void> sendFiles(
    DeviceInfo target,
    List<String> filePaths, {
    void Function(String fileName, double fileProgress, double overallProgress)? onProgress,
    String? pin,
  }) async {
    if (_selfInfo == null) throw StateError('TransportManager not initialized');
    
    // Choose transport
    final transport = _selectTransport(target);

    // Build transfer request
    final files = <FileMetadata>[];
    for (final path in filePaths) {
      final file = File(path);
      final stat = await file.stat();
      files.add(FileMetadata(
        id: Uuid().v4(),
        name: file.uri.pathSegments.last,
        size: stat.size,
      ));
    }

    final request = TransferRequest(
      senderName: _selfInfo!.name,
      senderId: _selfInfo!.id,
      files: files,
    );

    // Send request (handshake)
    print('[TransportManager] Sending transfer request to ${target.name}...');
    final response = await transport.sendTransferRequest(target, request, pin: pin);

    if (!response.accepted) {
      throw Exception('Transfer rejected by ${target.name}');
    }

    // Send each file
    for (int i = 0; i < filePaths.length; i++) {
      final fileName = files[i].name;
      final fileId = files[i].id;
      final fileSize = files[i].size;
      
      final dbMsg = TransferMessage(
        id: fileId,
        senderId: _selfInfo!.id,
        targetId: target.id,
        remoteName: target.name,
        fileName: fileName,
        fileSize: fileSize,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isSentByMe: true,
        status: 'transferring',
      );
      await DatabaseService().saveMessage(dbMsg);

      final fileProgress = (double p) {
        final overallProgress = (i + p) / filePaths.length;
        onProgress?.call(fileName, p, overallProgress);
        TransferStateManager().updateProgress(fileId, p, 'transferring');
      };

      try {
        await transport.sendFile(
          target,
          response.token!,
          fileId,
          filePaths[i],
          onProgress: fileProgress,
        );
        TransferStateManager().updateProgress(fileId, 1.0, 'completed');
        await DatabaseService().updateMessageStatus(fileId, 'completed');
      } catch (e) {
        TransferStateManager().updateProgress(fileId, 0.0, 'failed');
        await DatabaseService().updateMessageStatus(fileId, 'failed');
        rethrow;
      }
    }

    print('[TransportManager] All files sent successfully!');
  }

  /// Accept an incoming transfer request.
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    for (final file in request.files) {
      final dbMsg = TransferMessage(
        id: file.id,
        senderId: request.senderId,
        remoteName: request.senderName,
        targetId: _selfInfo!.id,
        fileName: file.name,
        fileSize: file.size,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isSentByMe: false,
        status: 'transferring',
      );
      await DatabaseService().saveMessage(dbMsg);
    }

    final wrappedProgress = (String fileName, double progress) {
      onProgress?.call(fileName, progress);
      final fileId = request.files.firstWhere((f) => f.name == fileName, orElse: () => FileMetadata(id: '', name: '', size: 0)).id;
      if (fileId.isNotEmpty) {
        TransferStateManager().updateProgress(fileId, progress, progress >= 1.0 ? 'completed' : 'transferring');
        if (progress >= 1.0) {
          DatabaseService().updateMessageStatus(fileId, 'completed');
        }
      }
    };

    // Try all transports safely
    try { await _tcpTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    try { await _httpTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    try { await _webrtcTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    if (NearbyTransport.isSupported) {
      try { await _nearbyTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    }
  }

  /// Reject an incoming transfer request.
  Future<void> rejectTransfer(TransferRequest request) async {
    try { await _tcpTransport.rejectTransfer(request); } catch (_) {}
    try { await _httpTransport.rejectTransfer(request); } catch (_) {}
    try { await _webrtcTransport.rejectTransfer(request); } catch (_) {}
    if (NearbyTransport.isSupported) {
      try { await _nearbyTransport.rejectTransfer(request); } catch (_) {}
    }
  }

  /// Select the best transport for the given target device.
  TransportInterface _selectTransport(DeviceInfo target) {
    if (target.protocol == 'webrtc') {
      print('[TransportManager] Using WebRTC transport for Global P2P');
      return _webrtcTransport;
    }

    if (target.protocol == 'localsend') {
      print('[TransportManager] Using LocalSend transport');
      return _localSendTransport;
    }

    if (target.protocol == 'fastshare' && target.tcpPort != null) {
      print('[TransportManager] Using FastShare Raw TCP protocol');
      return _tcpTransport;
    }

    // Use Nearby Connections if both devices are Android and Nearby is available
    if (NearbyTransport.isSupported && target.os == 'android') {
      print('[TransportManager] Using Nearby Connections (Android-to-Android)');
      return _nearbyTransport;
    }

    // Default: HTTP transport (fallback)
    print('[TransportManager] Using HTTP transport (fallback)');
    return _httpTransport;
  }

  String _getCurrentOS() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// Clean up all resources.
  Future<void> dispose() async {
    await stopDiscovery();
    await _tcpTransport.dispose();
    await _httpTransport.dispose();
    await _nearbyTransport.dispose();
    await _localSendTransport.dispose();
    await _deviceController.close();
    await _requestController.close();
  }
}
