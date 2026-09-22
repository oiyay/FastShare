import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';

/// Abstract interface that all transport layers must implement.
///
/// This allows the TransportManager to seamlessly switch between
/// HTTP (cross-platform) and Nearby Connections (Android-to-Android).
abstract class TransportInterface {
  /// Initialize the transport layer (start servers, etc.)
  Future<void> initialize();

  /// Clean up resources.
  Future<void> dispose();

  /// Discover devices on the network. Emits DeviceInfo as they are found.
  Stream<DeviceInfo> discoverDevices();

  /// Start advertising this device so others can find it.
  Future<void> startAdvertising(DeviceInfo selfInfo);

  /// Stop advertising.
  Future<void> stopAdvertising();

  /// Send a transfer request to the target device.
  /// Returns the target's response (accepted/rejected + token).
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request,
  );

  /// Stream-send a file to the target device.
  /// Uses streaming so large files don't crash the app.
  Future<void> sendFile(
    DeviceInfo target,
    String token,
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  });

  /// Stream of incoming transfer requests from other devices.
  Stream<TransferRequest> get incomingRequests;

  /// Accept an incoming transfer and save files to [savePath].
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  });

  /// Reject an incoming transfer.
  Future<void> rejectTransfer(TransferRequest request);
}
