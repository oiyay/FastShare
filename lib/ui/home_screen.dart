import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/models/exceptions.dart';
import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/core/transport/transport_manager.dart';
import 'package:fast_share/ui/settings_screen.dart';
import 'package:fast_share/ui/files_screen.dart';
import 'package:fast_share/ui/global_share_screen.dart';
import 'package:fast_share/ui/widgets/device_tile.dart';
import 'package:fast_share/ui/widgets/transfer_tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TransportManager _transport = TransportManager();
  final SettingsService _settings = SettingsService();

  // State
  final Map<String, DeviceInfo> _devices = {};
  
  List<DeviceInfo> get _uniqueDevices {
    final Map<String, DeviceInfo> byName = {};
    for (final d in _devices.values) {
      if (!byName.containsKey(d.name) || d.ip != null) {
        byName[d.name] = d;
      }
    }
    return byName.values.toList();
  }

  final List<TransferInfo> _transfers = [];
  DeviceInfo? _selectedDevice;
  bool _isInitialized = false;
  bool _isLoading = false;

  // Subscriptions
  StreamSubscription? _deviceSub;
  StreamSubscription? _requestSub;

  @override
  void initState() {
    super.initState();
    _initTransport();
  }

  Future<void> _initTransport() async {
    setState(() => _isLoading = true);

    try {
      await _transport.initialize();
      await _transport.startDiscovery();

      // Listen for discovered devices
      _deviceSub = _transport.devices.listen((device) {
        if (mounted) {
          setState(() {
            _devices[device.id] = device;
          });
        }
      });

      // Listen for incoming transfer requests
      _requestSub = _transport.incomingRequests.listen(_handleIncomingRequest);

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to initialize: $e')),
        );
      }
    }
  }

  void _handleIncomingRequest(TransferRequest request) {
    if (!mounted) return;

    // Auto-accept if enabled
    if (_settings.autoAccept) {
      _acceptTransfer(request);
      return;
    }

    // Show accept/reject dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Incoming Transfer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('From: ${request.senderName}'),
            const SizedBox(height: 8),
            Text('${request.files.length} file(s):'),
            ...request.files.map((f) => Padding(
              padding: const EdgeInsets.only(left: 16, top: 4),
              child: Text('• ${f.name} (${f.sizeFormatted})'),
            )),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _transport.rejectTransfer(request);
            },
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _acceptTransfer(request);
            },
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  Future<void> _acceptTransfer(TransferRequest request) async {
    try {
      // Get save directory from settings
      final savePath = await _settings.getEffectiveSavePath();
      await Directory(savePath).create(recursive: true);

      // Add to transfers list FIRST so progress can update them
      setState(() {
        for (final file in request.files) {
          _transfers.insert(0, TransferInfo(
            fileName: file.name,
            fileSize: file.size,
            status: TransferStatus.receiving,
            isOutgoing: false,
          ));
        }
      });

      await _transport.acceptTransfer(request, savePath, onProgress: (fileName, progress) {
        if (!mounted) return;
        setState(() {
          for (int i = 0; i < _transfers.length; i++) {
            if (_transfers[i].fileName == fileName && !_transfers[i].isOutgoing) {
              _transfers[i] = _transfers[i].copyWith(
                progress: progress,
                status: progress >= 1.0 ? TransferStatus.completed : TransferStatus.receiving,
              );
              break;
            }
          }
        });
      });

      if (mounted && _settings.showNotifications) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Received files from ${request.senderName} ✅'),
            action: SnackBarAction(
              label: 'Open Folder',
              onPressed: () {
                // TODO: Open save directory in file manager
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  /// Show send mode selection when FAB is pressed
  Future<void> _showSendOptions() async {
    // Pick files first
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );

    if (result == null || result.files.isEmpty) return;

    final filePaths = result.files
        .where((f) => f.path != null)
        .map((f) => f.path!)
        .toList();

    if (filePaths.isEmpty) return;
    
    _sendFilePaths(filePaths);
  }

  /// Send files directly via FastShare protocol
  Future<void> _sendFilePaths(List<String> filePaths, [String? pin]) async {
    if (_selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a device first!')),
      );
      return;
    }

    // Add to transfers list ONLY if we don't already have it (retries with PIN)
    if (pin == null) {
      setState(() {
        for (final path in filePaths) {
          final name = path.split('/').last.split('\\').last;
          final file = File(path);
          _transfers.insert(0, TransferInfo(
            fileName: name,
            fileSize: file.existsSync() ? file.lengthSync() : 0,
            status: TransferStatus.sending,
            isOutgoing: true,
          ));
        }
      });
    }

    // Send files
    try {
      await _transport.sendFiles(
        _selectedDevice!,
        filePaths,
        pin: pin,
        onProgress: (fileName, fileProgress, overallProgress) {
          if (mounted) {
            setState(() {
              for (int i = 0; i < _transfers.length; i++) {
                if (_transfers[i].fileName == fileName && _transfers[i].isOutgoing) {
                  _transfers[i] = _transfers[i].copyWith(progress: fileProgress);
                  break;
                }
              }
            });
          }
        },
      );

      // Mark as completed
      if (mounted) {
        setState(() {
          for (final path in filePaths) {
            final fileName = path.split('/').last.split('\\').last;
            for (int i = 0; i < _transfers.length; i++) {
              if (_transfers[i].fileName == fileName && _transfers[i].isOutgoing) {
                _transfers[i] = _transfers[i].copyWith(
                  status: TransferStatus.completed,
                  progress: 1.0,
                );
                break;
              }
            }
          }
        });
        if (_settings.showNotifications) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Files sent successfully! ✅')),
          );
        }
      }
    } on PinRequiredException catch (_) {
      // Show PIN dialog and retry
      if (mounted) {
        final pinController = TextEditingController();
        final enteredPin = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('PIN Required'),
            content: TextField(
              controller: pinController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Enter PIN for LocalSend device',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, pinController.text),
                child: const Text('Submit'),
              ),
            ],
          ),
        );
        
        if (enteredPin != null && enteredPin.isNotEmpty) {
          await _sendFilePaths(filePaths, enteredPin); // Retry with PIN
        } else {
          // User canceled PIN input
          if (mounted) {
            setState(() {
              for (final path in filePaths) {
                final fileName = path.split('/').last.split('\\').last;
                for (int i = 0; i < _transfers.length; i++) {
                  if (_transfers[i].fileName == fileName && _transfers[i].isOutgoing) {
                    _transfers[i] = _transfers[i].copyWith(status: TransferStatus.failed);
                    break;
                  }
                }
              }
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          for (final path in filePaths) {
            final fileName = path.split('/').last.split('\\').last;
            for (int i = 0; i < _transfers.length; i++) {
              if (_transfers[i].fileName == fileName && _transfers[i].isOutgoing) {
                _transfers[i] = _transfers[i].copyWith(status: TransferStatus.failed);
                break;
              }
            }
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _requestSub?.cancel();
    _transport.dispose();
    super.dispose();
  }

  String _getCurrentOS() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    return 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('FastShare', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              '${_transport.selfInfo?.name ?? _settings.deviceName} • ${_getCurrentOS()}',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
        actions: [
          // Global P2P button
          IconButton(
            icon: const Icon(Icons.public),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GlobalShareScreen()),
              );
            },
            tooltip: 'Global P2P Share',
          ),
          // Files button
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FilesScreen()),
              );
            },
            tooltip: 'Received Files',
          ),
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isInitialized ? () async {
              setState(() {
                _devices.clear();
                _isLoading = true; // Show loading spinner
              });
              
              // Trigger a fresh HTTP sweep and UDP search
              _transport.refreshDiscovery();
              
              if (mounted) {
                setState(() => _isLoading = false);
              }
            } : null,
            tooltip: 'Refresh devices',
          ),
          // Settings button
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              // Refresh UI after settings change
              if (mounted) setState(() {});
            },
            tooltip: 'Settings',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isInitialized ? _showSendOptions : null,
        icon: const Icon(Icons.send),
        label: const Text('Send File'),
      ),
    );
  }

  Widget _buildBody() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nearby Devices section
          Row(
            children: [
              const Icon(Icons.devices, size: 20),
              const SizedBox(width: 8),
              Text(
                'Nearby Devices (${_uniqueDevices.length})',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_uniqueDevices.isEmpty && _isInitialized)
                Text(
                  'Searching...',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Device list
          Expanded(
            flex: 2,
            child: _uniqueDevices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.wifi_find, size: 48, color: Colors.grey[700]),
                        const SizedBox(height: 8),
                        Text(
                          'Looking for devices on your network...',
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Also detects LocalSend devices!',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _uniqueDevices.length,
                    itemBuilder: (context, index) {
                      final device = _uniqueDevices[index];
                      return DeviceTile(
                        device: device,
                        isSelected: _selectedDevice?.id == device.id,
                        onTap: () {
                          setState(() {
                            _selectedDevice = device;
                          });
                        },
                      );
                    },
                  ),
          ),

          const Divider(),

          // Transfers section
          Row(
            children: [
              const Icon(Icons.swap_vert, size: 20),
              const SizedBox(width: 8),
              Text(
                'Transfers (${_transfers.length})',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_transfers.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setState(() => _transfers.clear());
                  },
                  child: const Text('Clear', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Transfer list
          Expanded(
            flex: 3,
            child: _transfers.isEmpty
                ? Center(
                    child: Text(
                      'No transfers yet',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                : ListView.builder(
                    itemCount: _transfers.length,
                    itemBuilder: (context, index) {
                      return TransferTile(transfer: _transfers[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
