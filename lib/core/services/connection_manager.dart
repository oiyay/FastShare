import 'dart:async';
import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/transport/transport_manager.dart';
import 'package:fast_share/core/services/signaling_service.dart';

class ConnectionManager {
  static final ConnectionManager _instance = ConnectionManager._internal();
  factory ConnectionManager() => _instance;
  ConnectionManager._internal();

  final Map<String, DeviceInfo> _localDevices = {};
  final Map<String, DeviceInfo> _globalDevices = {};

  final _unifiedDevicesController = StreamController<List<DeviceInfo>>.broadcast();
  Stream<List<DeviceInfo>> get unifiedDevicesStream => _unifiedDevicesController.stream;

  List<DeviceInfo> get currentUnifiedDevices => _mergeDevices();

  StreamSubscription? _localSub;
  StreamSubscription? _globalSub;

  void init() {
    _localSub = TransportManager().devices.listen((device) {
      _localDevices[device.id] = device;
      _emitUnified();
    });

    _globalSub = SignalingService().onlineUsers.listen((devices) {
      _globalDevices.clear();
      for (final d in devices) {
        _globalDevices[d.id] = d;
      }
      _emitUnified();
    });
  }

  void _emitUnified() {
    _unifiedDevicesController.add(_mergeDevices());
  }

  List<DeviceInfo> _mergeDevices() {
    final merged = <String, DeviceInfo>{};

    // 1. Add all global devices first
    for (final d in _globalDevices.values) {
      merged[d.id] = d.copyWith(
        hasGlobalRoute: true,
        hasLocalRoute: false,
        protocol: 'webrtc', // Default fallback
      );
    }

    // 2. Overwrite / merge with local devices
    for (final d in _localDevices.values) {
      if (merged.containsKey(d.id)) {
        // Device is on both routes! 
        merged[d.id] = d.copyWith(
          hasLocalRoute: true,
          hasGlobalRoute: true,
          // Keep local IP and Port details from d
        );
      } else {
        // Device is only local
        merged[d.id] = d.copyWith(
          hasLocalRoute: true,
          hasGlobalRoute: false,
        );
      }
    }

    return merged.values.toList();
  }

  // Get a specific device by ID, falling back to a dummy if totally unknown
  DeviceInfo getDevice(String id, {String? fallbackName}) {
    final merged = _mergeDevices();
    try {
      return merged.firstWhere((d) => d.id == id);
    } catch (_) {
      return DeviceInfo(
        id: id,
        name: fallbackName ?? 'Unknown',
        os: 'Unknown',
        ip: '',
        port: 0,
        hasLocalRoute: false,
        hasGlobalRoute: false,
      );
    }
  }

  void clear() {
    _localDevices.clear();
    _globalDevices.clear();
    _emitUnified();
  }

  void dispose() {
    _localSub?.cancel();
    _globalSub?.cancel();
    _unifiedDevicesController.close();
  }
}
