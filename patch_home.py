import re

with open('lib/ui/home_screen.dart', 'r') as f:
    content = f.read()

# Add import
content = content.replace("import 'package:fast_share/core/services/signaling_service.dart';", "import 'package:fast_share/core/services/signaling_service.dart';\nimport 'package:fast_share/core/services/connection_manager.dart';")

# Replace variables and properties
bad_vars = """  final Map<String, DeviceInfo> _localDevices = {};
  final Map<String, DeviceInfo> _globalDevices = {};

  // Computed unified list
  List<DeviceInfo> get _unifiedDevices {
    final Map<String, DeviceInfo> merged = {};
    
    // Add global first
    for (final d in _globalDevices.values) {
      merged[d.id] = d;
    }
    
    // Add local (overwrites global with local protocol for priority speed!)
    for (final d in _localDevices.values) {
      merged[d.id] = d;
    }
    
    return merged.values.toList();
  }"""

good_vars = """  List<DeviceInfo> _unifiedDevices = [];
  StreamSubscription? _connSub;"""

content = content.replace(bad_vars, good_vars)

# Replace _startDiscovery
bad_discovery = """  void _startDiscovery() async {
    await _transport.initialize();
    await _transport.startDiscovery();
    final selfInfo = _transport.selfInfo;
    if (selfInfo != null) {
      await _signaling.initialize(selfInfo.name, selfInfo.os);
    }

    _transport.devices.listen((d) {
      if (mounted) {
        setState(() {
          _localDevices[d.id] = d;
        });
      }
    });

    _signaling.onlineUsers.listen((devices) {
      if (mounted) {
        setState(() {
          _globalDevices.clear();
          for (final d in devices) {
            _globalDevices[d.id] = d.copyWith(protocol: 'webrtc');
          }
        });
      }
    });
  }"""

good_discovery = """  void _startDiscovery() async {
    await _transport.initialize();
    await _transport.startDiscovery();
    final selfInfo = _transport.selfInfo;
    if (selfInfo != null) {
      await _signaling.initialize(selfInfo.name, selfInfo.os);
    }
    
    ConnectionManager().init();
    
    _connSub = ConnectionManager().unifiedDevicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _unifiedDevices = devices;
        });
      }
    });
  }
  
  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }"""

content = content.replace(bad_discovery, good_discovery)

# Replace UI indicator
bad_ui = """                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: CircleAvatar(
                              radius: 10,
                              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                              child: Icon(
                                isGlobal ? Icons.public : Icons.wifi,
                                size: 12,
                                color: isGlobal ? primaryColor : Colors.green,
                              ),
                            ),
                          )"""
                          
good_ui = """                          if (device.hasLocalRoute || device.hasGlobalRoute)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: CircleAvatar(
                                radius: 10,
                                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (device.hasLocalRoute)
                                      const Icon(Icons.wifi, size: 10, color: Colors.green),
                                    if (device.hasGlobalRoute)
                                      Icon(Icons.public, size: 10, color: primaryColor),
                                  ],
                                ),
                              ),
                            )"""

# Wait, `isGlobal` was used for `CircleAvatar` background too. Let's patch that.
bad_avatar_bg = """                          CircleAvatar(
                            radius: 28,
                            backgroundColor: isGlobal ? primaryColor.withOpacity(0.2) : Colors.green.withOpacity(0.2),
                            child: Icon(Icons.person, color: isGlobal ? primaryColor : Colors.green, size: 28),
                          ),"""
good_avatar_bg = """                          CircleAvatar(
                            radius: 28,
                            backgroundColor: device.hasLocalRoute ? Colors.green.withOpacity(0.2) : primaryColor.withOpacity(0.2),
                            child: Icon(Icons.person, color: device.hasLocalRoute ? Colors.green : primaryColor, size: 28),
                          ),"""

content = content.replace(bad_avatar_bg, good_avatar_bg)
content = content.replace(bad_ui, good_ui)

# Replace `_unifiedDevices.firstWhere` in `recentChats` because it now uses `ConnectionManager().getDevice`
bad_get_device = """final remoteDevice = _unifiedDevices.firstWhere((d) => d.id == remoteId, orElse: () => DeviceInfo(id: remoteId, name: msg.remoteName, os: 'Unknown', ip: '', port: 0));"""
good_get_device = """final remoteDevice = ConnectionManager().getDevice(remoteId, fallbackName: msg.remoteName);"""
content = content.replace(bad_get_device, good_get_device)

with open('lib/ui/home_screen.dart', 'w') as f:
    f.write(content)
