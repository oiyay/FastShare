import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_message.dart';
import 'package:fast_share/core/services/database_service.dart';
import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/core/services/signaling_service.dart';
import 'package:fast_share/core/transport/transport_manager.dart';
import 'package:fast_share/ui/chat_screen.dart';
import 'package:fast_share/ui/settings_screen.dart';
import 'package:intl/intl.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TransportManager _transport = TransportManager();
  final SignalingService _signaling = SignalingService();

  final Map<String, DeviceInfo> _localDevices = {};
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
  }

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  void _startDiscovery() async {
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
  }

  void _startDiscovery() async {
    await _transport.initialize();
    await _transport.startDiscovery();
    final selfInfo = _transport.selfInfo;
    if (selfInfo != null) {
      await _signaling.initialize(selfInfo.name, selfInfo.os);
    }

    _transport.devices.listen((d) {
      if (mounted) setState(() => _onlineDevices[d.id] = d);
    });

    _signaling.onlineUsers.listen((devices) {
      if (mounted) {
        setState(() {
          for (final d in devices) {
            _onlineDevices[d.id] = d.copyWith(protocol: 'webrtc');
          }
        });
      }
    });
  }

  void _openChat(DeviceInfo device) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(device: device)));
  }

  Widget _buildActiveNow(bool isDark, Color primaryColor) {
    if (_unifiedDevices.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('Active Now', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
        ),
        SizedBox(
          height: 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _unifiedDevices.length,
            itemBuilder: (context, index) {
              final device = _unifiedDevices[index];
              final isGlobal = device.protocol == 'webrtc';
              return GestureDetector(
                onTap: () => _openChat(device),
                child: Container(
                  width: 72,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    children: [
                      Stack(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: isGlobal ? primaryColor.withOpacity(0.2) : Colors.green.withOpacity(0.2),
                            child: Icon(Icons.person, color: isGlobal ? primaryColor : Colors.green, size: 28),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: CircleAvatar(
                              radius: 10,
                              backgroundColor: isDark ? Colors.black : Colors.white,
                              child: CircleAvatar(
                                radius: 8,
                                backgroundColor: isGlobal ? primaryColor : Colors.green,
                                child: Icon(isGlobal ? Icons.public : Icons.wifi, size: 10, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        device.name,
                        style: const TextStyle(fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRecentChats(bool isDark, Color primaryColor) {
    return Expanded(
      child: StreamBuilder<List<TransferMessage>>(
        stream: DatabaseService().recentChatsStream,
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No recent transfers', style: TextStyle(color: Colors.grey, fontSize: 16)),
                  SizedBox(height: 8),
                  Text('Tap an active device above to start sharing.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            );
          }

          final chats = snapshot.data!;
          return ListView.builder(
            itemCount: chats.length,
            itemBuilder: (context, index) {
              final msg = chats[index];
              final remoteId = msg.isSentByMe ? msg.targetId : msg.senderId;
              
              // We need the remote device name. It might be online or offline.
              // If offline, we just show the ID for now. (Ideally we save contacts in DB).
              final remoteDevice = _unifiedDevices.firstWhere((d) => d.id == remoteId, orElse: () => DeviceInfo(id: remoteId, name: 'Unknown ($remoteId)', os: 'Unknown', ip: '', port: 0);

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: primaryColor.withOpacity(0.1),
                  child: Icon(Icons.person, color: primaryColor),
                ),
                title: Text(msg.remoteName, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                  '${msg.isSentByMe ? "You sent" : "Received"}: ${msg.fileName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(
                  DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(msg.timestamp)),
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                onTap: () => _openChat(remoteDevice),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = const Color(0xFF3A76F0);

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF181818) : const Color(0xFFF5F5F5),
        elevation: 0,
        title: const Text('Chats', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _localDevices.clear(); _globalDevices.clear();
              setState(() {});
              _transport.refreshDiscovery();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildActiveNow(isDark, primaryColor),
          if (_unifiedDevices.isNotEmpty) const Divider(height: 1),
          _buildRecentChats(isDark, primaryColor),
        ],
      ),
    );
  }
}
