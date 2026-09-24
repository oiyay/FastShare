import 'package:fast_share/core/transport/webrtc_transport.dart';
import 'dart:async';
import 'dart:io';

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
    final username = settings.effectiveUsername;
    final os = _getCurrentOS();

    _selfInfo = DeviceInfo(
      id: const Uuid().v4(),
      name: username,
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
        final newName = settings.effectiveUsername;
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
      _deviceController.add(device);
    });

    if (NearbyTransport.isSupported) {
      await _nearbyTransport.startAdvertising(_selfInfo!);
      _nearbyTransport.discoverDevices().listen((device) {
        _deviceController.add(device);
      });
    }
  }

  /// Trigger a manual refresh for devices
  void refreshDiscovery() {
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
  Stream<DeviceInfo> get devices => _deviceController.stream;

  /// Stream of incoming transfer requests from all transports.
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  /// Get current device info.
  DeviceInfo? get selfInfo => _selfInfo;

  /// Send file(s) to a target device.
  /// Automatically selects the best transport.
  Future<void> sendFiles(
    DeviceInfo target,
    List<String> filePaths, {
    void Function(double progress)? onProgress,
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
      final fileProgress = (double p) {
        // Calculate overall progress across all files
        final overallProgress = (i + p) / filePaths.length;
        onProgress?.call(overallProgress);
      };

      await transport.sendFile(
        target,
        response.token!,
        files[i].id,
        filePaths[i],
        onProgress: fileProgress,
      );
    }

    print('[TransportManager] All files sent successfully!');
  }

  /// Accept an incoming transfer request.
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    // Try all transports — only the one with the pending request will act
    await _tcpTransport.acceptTransfer(request, savePath, onProgress: onProgress);
    await _httpTransport.acceptTransfer(request, savePath, onProgress: onProgress);
    await _webrtcTransport.acceptTransfer(request, savePath, onProgress: onProgress);
    if (NearbyTransport.isSupported) {
      await _nearbyTransport.acceptTransfer(request, savePath, onProgress: onProgress);
    }
  }

  /// Reject an incoming transfer request.
  Future<void> rejectTransfer(TransferRequest request) async {
    await _tcpTransport.rejectTransfer(request);
    await _httpTransport.rejectTransfer(request);
    await _webrtcTransport.rejectTransfer(request);
    if (NearbyTransport.isSupported) {
      await _nearbyTransport.rejectTransfer(request);
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
