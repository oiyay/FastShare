import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/transport/transport_interface.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

/// Nearby Connections transport for Android-to-Android file sharing.
///
/// Uses Google's Nearby Connections API which leverages Wi-Fi Direct,
/// so no router is needed. Only available on Android.
class NearbyTransport implements TransportInterface {
  static bool get isSupported => Platform.isAndroid;

  final _deviceController = StreamController<DeviceInfo>.broadcast();
  final _requestController = StreamController<TransferRequest>.broadcast();

  final Map<String, DeviceInfo> _discoveredDevices = {};

  @override
  Future<void> initialize() async {
    if (!Platform.isAndroid) return;

    // Request permissions using permission_handler
    await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
    ].request();

    // Nearby Connections specifically requires Global Location Services (GPS) to be ON.
    if (!await Nearby().checkLocationEnabled()) {
      await Nearby().enableLocationServices();
    }
  }

  @override
  Future<void> dispose() async {
    if (!Platform.isAndroid) return;
    await Nearby().stopAllEndpoints();
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();
    await _deviceController.close();
    await _requestController.close();
  }

  @override
  Stream<DeviceInfo> discoverDevices() {
    if (!Platform.isAndroid) return const Stream.empty();

    Nearby().startDiscovery(
      "FastShare",
      Strategy.P2P_STAR,
      onEndpointFound: (String endpointId, String endpointName, String serviceId) {
        final device = DeviceInfo(
          id: endpointId,
          name: endpointName,
          os: 'android',
          ip: 'nearby',
          port: 0,
          protocol: 'fastshare',
        );
        _discoveredDevices[endpointId] = device;
        _deviceController.add(device);
      },
      onEndpointLost: (String? endpointId) {
        if (endpointId != null) {
          _discoveredDevices.remove(endpointId);
        }
      },
    );
    return _deviceController.stream;
  }

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {
    if (!Platform.isAndroid) return;

    await Nearby().startAdvertising(
      selfInfo.name,
      Strategy.P2P_STAR,
      onConnectionInitiated: (String endpointId, ConnectionInfo info) async {
        // Automatically accept the connection to simplify the handshake
        await Nearby().acceptConnection(
          endpointId,
          onPayLoadRecieved: (String endpointId, Payload payload) {
            _handleIncomingPayload(endpointId, payload);
          },
          onPayloadTransferUpdate: (String endpointId, PayloadTransferUpdate update) {
            // Monitor transfer progress if needed
          },
        );
      },
      onConnectionResult: (String endpointId, Status status) {
        // Handle connection results (e.g., connected, rejected)
      },
      onDisconnected: (String endpointId) {
        // Handle disconnection
      },
    );
  }

  @override
  Future<void> stopAdvertising() async {
    if (!Platform.isAndroid) return;
    await Nearby().stopAdvertising();
  }

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request, {String? pin,}
  ) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('NearbyTransport is only supported on Android.');
    }

    final completer = Completer<TransferResponse>();

    await Nearby().requestConnection(
      request.senderName,
      target.id,
      onConnectionInitiated: (String endpointId, ConnectionInfo info) async {
        await Nearby().acceptConnection(
          endpointId,
          onPayLoadRecieved: (String endpointId, Payload payload) {
            if (payload.type == PayloadType.BYTES) {
              final str = String.fromCharCodes(payload.bytes!);
              try {
                final response = TransferResponse.fromJsonString(str);
                if (!completer.isCompleted) {
                  completer.complete(response);
                }
              } catch (e) {
                if (!completer.isCompleted) {
                  completer.completeError(e);
                }
              }
            }
          },
          onPayloadTransferUpdate: (String endpointId, PayloadTransferUpdate update) {},
        );

        // After initiating and accepting locally, send the transfer request payload
        final bytes = Uint8List.fromList(utf8.encode(request.toJsonString()));
        await Nearby().sendBytesPayload(endpointId, bytes);
      },
      onConnectionResult: (String endpointId, Status status) {
        if (status == Status.REJECTED || status == Status.ERROR) {
          if (!completer.isCompleted) {
            completer.complete(TransferResponse(accepted: false));
          }
        }
      },
      onDisconnected: (String endpointId) {
        if (!completer.isCompleted) {
          completer.complete(TransferResponse(accepted: false));
        }
      },
    );

    return completer.future;
  }

  @override
  Future<void> sendFile(
    DeviceInfo target,
    String token,
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('NearbyTransport is only supported on Android.');
    }

    // Using Payload.File equivalent in nearby_connections to send the actual file
    await Nearby().sendFilePayload(target.id, filePath);
  }

  @override
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  @override
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) return;

    final response = TransferResponse(accepted: true, token: 'nearby');
    final bytes = Uint8List.fromList(utf8.encode(response.toJsonString()));
    await Nearby().sendBytesPayload(request.senderId, bytes);
  }

  @override
  Future<void> rejectTransfer(TransferRequest request) async {
    if (!Platform.isAndroid) return;

    final response = TransferResponse(accepted: false);
    final bytes = Uint8List.fromList(utf8.encode(response.toJsonString()));
    await Nearby().sendBytesPayload(request.senderId, bytes);
  }

  void _handleIncomingPayload(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final str = String.fromCharCodes(payload.bytes!);
      try {
        final request = TransferRequest.fromJsonString(str);
        // Replace senderId with endpointId so we can reply to the correct endpoint
        final modifiedRequest = TransferRequest(
          senderName: request.senderName,
          senderId: endpointId,
          files: request.files,
        );
        _requestController.add(modifiedRequest);
      } catch (e) {
        // Not a TransferRequest, ignore or handle other payloads
      }
    } else if (payload.type == PayloadType.FILE) {
      // nearby_connections automatically saves files to the Downloads directory.
      // More complex logic would move it to the requested savePath.
    }
  }
}
