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
/// NOTE: This is a stub implementation. The nearby_connections package
/// will only be available on Android at runtime.
class NearbyTransport implements TransportInterface {
  /// Check if Nearby Connections is supported on this platform.
  static bool get isSupported => Platform.isAndroid;

  final _deviceController = StreamController<DeviceInfo>.broadcast();
  final _requestController = StreamController<TransferRequest>.broadcast();

  @override
  Future<void> initialize() async {
    if (!isSupported) {
      print('[NearbyTransport] Not supported on this platform');
      return;
    }

    // TODO: Initialize Nearby Connections
    // Nearby().askLocationPermission();
    // Nearby().askExternalStoragePermission();
    print('[NearbyTransport] Initialized (stub)');
  }

  @override
  Future<void> dispose() async {
    await _deviceController.close();
    await _requestController.close();

    if (isSupported) {
      // TODO: Nearby().stopDiscovery();
      // TODO: Nearby().stopAdvertising();
    }
  }

  @override
  Stream<DeviceInfo> discoverDevices() {
    if (!isSupported) return const Stream.empty();

    // TODO: Implement using Nearby().startDiscovery()
    // Strategy: Strategy.P2P_STAR
    //
    // Nearby().startDiscovery(
    //   userName,
    //   Strategy.P2P_STAR,
    //   onEndpointFound: (id, name, serviceId) {
    //     _deviceController.add(DeviceInfo(
    //       id: id,
    //       name: name,
    //       os: 'android',
    //       ip: '', // Not used for Nearby
    //       port: 0,
    //     ));
    //   },
    //   onEndpointLost: (id) {
    //     // Handle endpoint lost
    //   },
    // );

    print('[NearbyTransport] Discovery started (stub)');
    return _deviceController.stream;
  }

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {
    if (!isSupported) return;

    // TODO: Implement using Nearby().startAdvertising()
    //
    // Nearby().startAdvertising(
    //   selfInfo.name,
    //   Strategy.P2P_STAR,
    //   onConnectionInitiated: (id, info) {
    //     // Accept connection
    //     Nearby().acceptConnection(id,
    //       onPayLoadRecieved: (endpointId, payload) {
    //         // Handle incoming data
    //       },
    //     );
    //   },
    //   onConnectionResult: (id, status) {
    //     // Connection result
    //   },
    //   onDisconnected: (id) {
    //     // Handle disconnect
    //   },
    // );

    print('[NearbyTransport] Advertising started (stub)');
  }

  @override
  Future<void> stopAdvertising() async {
    if (!isSupported) return;
    // TODO: Nearby().stopAdvertising();
    print('[NearbyTransport] Advertising stopped (stub)');
  }

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request,
  ) async {
    if (!isSupported) {
      throw UnsupportedError('Nearby Connections not supported on this platform');
    }

    // TODO: Implement via Nearby().requestConnection()
    // then send TransferRequest as Payload.BYTES
    // wait for response Payload.BYTES

    throw UnimplementedError('Nearby transfer request not yet implemented');
  }

  @override
  Future<void> sendFile(
    DeviceInfo target,
    String token,
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Nearby Connections not supported on this platform');
    }

    // TODO: Implement using Nearby().sendFilePayload()
    //
    // Nearby().sendFilePayload(
    //   target.id,
    //   filePath,
    // );
    //
    // Listen for progress via PayloadTransferUpdate

    throw UnimplementedError('Nearby file send not yet implemented');
  }

  @override
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  @override
  Future<void> acceptTransfer(TransferRequest request, String savePath) async {
    if (!isSupported) return;
    // TODO: Accept Nearby connection and start receiving payload
    print('[NearbyTransport] Accept transfer (stub)');
  }

  @override
  Future<void> rejectTransfer(TransferRequest request) async {
    if (!isSupported) return;
    // TODO: Reject Nearby connection
    print('[NearbyTransport] Reject transfer (stub)');
  }
}
