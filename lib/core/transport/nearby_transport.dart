import 'dart:async';
import 'dart:io';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/transport/transport_interface.dart';

/// Nearby Connections transport for Android-to-Android file sharing.
///
/// Uses Google's Nearby Connections API which leverages Wi-Fi Direct,
/// so no router is needed. Only available on Android.
///
/// Current status: This transport gracefully reports as unsupported
/// and falls back to HttpTransport. When the nearby_connections package
/// is added to pubspec.yaml and this class is implemented, it will
/// enable direct Android-to-Android transfers without a router.
class NearbyTransport implements TransportInterface {
  /// Check if Nearby Connections is supported on this platform.
  /// Currently always returns false until the nearby_connections
  /// package is integrated.
  static bool get isSupported => false; // Will be Platform.isAndroid when implemented

  final _deviceController = StreamController<DeviceInfo>.broadcast();
  final _requestController = StreamController<TransferRequest>.broadcast();

  @override
  Future<void> initialize() async {
    // Nearby Connections is not yet integrated.
    // When implemented, this will request location and storage permissions
    // and initialize the Nearby Connections API.
    print('[NearbyTransport] Not yet integrated — using HTTP transport as fallback');
  }

  @override
  Future<void> dispose() async {
    await _deviceController.close();
    await _requestController.close();
  }

  @override
  Stream<DeviceInfo> discoverDevices() {
    // Returns empty stream — all discovery happens via HttpTransport
    return _deviceController.stream;
  }

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {
    // No-op until Nearby Connections is integrated
  }

  @override
  Future<void> stopAdvertising() async {
    // No-op until Nearby Connections is integrated
  }

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request,
  ) async {
    // Should never be called since isSupported returns false.
    // TransportManager will always route to HttpTransport.
    throw StateError(
      'NearbyTransport.sendTransferRequest called but Nearby is not yet integrated. '
      'TransportManager should route to HttpTransport instead.',
    );
  }

  @override
  Future<void> sendFile(
    DeviceInfo target,
    String token,
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    // Should never be called since isSupported returns false.
    throw StateError(
      'NearbyTransport.sendFile called but Nearby is not yet integrated. '
      'TransportManager should route to HttpTransport instead.',
    );
  }

  @override
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  @override
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    // No-op — HttpTransport handles all transfers
  }

  @override
  Future<void> rejectTransfer(TransferRequest request) async {
    // No-op — HttpTransport handles all transfers
  }
}
