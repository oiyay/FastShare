import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/transport/transport_interface.dart';
import 'package:fast_share/core/transport/http_transport.dart';
import 'package:fast_share/core/transport/nearby_transport.dart';

/// Smart transport manager that auto-selects the best transport.
///
/// Logic:
/// - Android <-> Android: Use NearbyTransport (Wi-Fi Direct, no router needed)
/// - Android <-> Windows: Use HttpTransport (via local network)
/// - Windows <-> Windows: Use HttpTransport (via local network)
class TransportManager {
  final HttpTransport _httpTransport = HttpTransport();
  final NearbyTransport _nearbyTransport = NearbyTransport();

  final _deviceController = StreamController<DeviceInfo>.broadcast();
  final _requestController = StreamController<TransferRequest>.broadcast();

  DeviceInfo? _selfInfo;
  bool _initialized = false;

  /// Initialize all available transport layers.
  Future<void> initialize() async {
    if (_initialized) return;

    // Build self info
    final localIp = await HttpTransport.getLocalIp();
    final deviceName = Platform.localHostname;
    final os = _getCurrentOS();

    _selfInfo = DeviceInfo(
      id: Uuid().v4(),
      name: deviceName.isNotEmpty ? deviceName : 'FastShare Device',
      os: os,
      ip: localIp,
      port: 53317,
    );

    // Always initialize HTTP transport (works everywhere)
    await _httpTransport.initialize();

    // Initialize Nearby only on Android
    if (NearbyTransport.isSupported) {
      await _nearbyTransport.initialize();
    }

    // Merge incoming request streams
    _httpTransport.incomingRequests.listen((req) {
      _requestController.add(req);
    });

    if (NearbyTransport.isSupported) {
      _nearbyTransport.incomingRequests.listen((req) {
        _requestController.add(req);
      });
    }

    _initialized = true;
    print('[TransportManager] Initialized as ${_selfInfo!.name} ($os) at $localIp');
  }

  /// Start discovering devices and advertising self.
  Future<void> startDiscovery() async {
    if (_selfInfo == null) return;

    // Start advertising on HTTP
    await _httpTransport.startAdvertising(_selfInfo!);

    // Listen for HTTP-discovered devices
    _httpTransport.discoverDevices().listen((device) {
      _deviceController.add(device);
    });

    // Also start Nearby discovery if on Android
    if (NearbyTransport.isSupported) {
      await _nearbyTransport.startAdvertising(_selfInfo!);
      _nearbyTransport.discoverDevices().listen((device) {
        _deviceController.add(device);
      });
    }
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
    final response = await transport.sendTransferRequest(target, request);

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
  Future<void> acceptTransfer(TransferRequest request, String savePath) async {
    // Try both transports — only the one with the pending request will act
    await _httpTransport.acceptTransfer(request, savePath);
    if (NearbyTransport.isSupported) {
      await _nearbyTransport.acceptTransfer(request, savePath);
    }
  }

  /// Reject an incoming transfer request.
  Future<void> rejectTransfer(TransferRequest request) async {
    await _httpTransport.rejectTransfer(request);
    if (NearbyTransport.isSupported) {
      await _nearbyTransport.rejectTransfer(request);
    }
  }

  /// Select the best transport for the given target device.
  TransportInterface _selectTransport(DeviceInfo target) {
    // Use Nearby Connections if both devices are Android
    if (NearbyTransport.isSupported && target.os == 'android') {
      print('[TransportManager] Using Nearby Connections (Android-to-Android)');
      // For now, fall through to HTTP since Nearby is a stub
      // TODO: return _nearbyTransport; when fully implemented
    }

    // Default: HTTP transport (works everywhere)
    print('[TransportManager] Using HTTP transport');
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
    await _httpTransport.dispose();
    await _nearbyTransport.dispose();
    await _deviceController.close();
    await _requestController.close();
  }
}
