import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/transport/transport_manager.dart';
import 'package:fast_share/core/services/signaling_service.dart';

class GlobalShareScreen extends StatefulWidget {
  const GlobalShareScreen({super.key});

  @override
  State<GlobalShareScreen> createState() => _GlobalShareScreenState();
}

class _GlobalShareScreenState extends State<GlobalShareScreen> {
  bool _isInitializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initFirebase();
  }

  Future<void> _initFirebase() async {
    try {
      await SignalingService().initialize();
      setState(() => _isInitializing = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isInitializing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🌍 Global P2P Share'),
      ),
      body: _isInitializing
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Connecting to Global Server...'),
                ],
              ),
            )
          : _error != null
              ? Center(child: Text('Failed to connect:\n$_error', textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)))
              : Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: Colors.blue.withOpacity(0.1),
                      child: Row(
                        children: [
                          const Icon(Icons.person, color: Colors.blue, size: 40),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('You are visible globally as:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                Text(
                                  SignalingService().username ?? '@unknown',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                              ],
                            ),
                          ),
                          const Chip(
                            label: Text('Online'),
                            backgroundColor: Colors.green,
                            labelStyle: TextStyle(color: Colors.white, fontSize: 12),
                          )
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: StreamBuilder<List<GlobalUser>>(
                        stream: SignalingService().getOnlineUsers(),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Center(child: Text('Error: ${snapshot.error}'));
                          }
                          if (!snapshot.hasData) {
                            return const Center(child: CircularProgressIndicator());
                          }

                          final users = snapshot.data!;
                          if (users.isEmpty) {
                            return const Center(
                              child: Text('No other users online right now.\nOpen FastShare on another device!', textAlign: TextAlign.center),
                            );
                          }

                          return ListView.builder(
                            itemCount: users.length,
                            itemBuilder: (context, index) {
                              final user = users[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.blue,
                                  child: Text(user.username.substring(1, 2).toUpperCase(), style: const TextStyle(color: Colors.white)),
                                ),
                                title: Text(user.username, style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: const Text('Ready to receive files'),
                                trailing: ElevatedButton(
                                  onPressed: () async {
                                    final result = await file_picker.FilePicker.platform.pickFiles(allowMultiple: true);
                                    if (result != null && result.paths.isNotEmpty) {
                                      final target = DeviceInfo(
                                        id: user.uid,
                                        name: user.username,
                                        os: 'global',
                                        ip: '0.0.0.0', // Not used for WebRTC
                                        port: 0,
                                        protocol: 'webrtc',
                                      );
                                      
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Connecting to ${user.username}...')),
                                      );
                                      
                                      try {
                                        await TransportManager().sendFiles(
                                          target,
                                          result.paths.where((p) => p != null).cast<String>().toList(),
                                          onProgress: (p) => print('Progress: $p'),
                                        );
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Global transfer complete!')),
                                        );
                                      } catch (e) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('Failed: $e')),
                                        );
                                      }
                                    }
                                  },
                                  child: const Text('Send'),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
