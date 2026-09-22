import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/core/transport/transport_manager.dart';
import 'package:fast_share/ui/settings_screen.dart';
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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Receiving files from ${request.senderName}...'),
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

  Future<void> _pickAndSendFiles() async {
    if (_selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a device first!')),
      );
      return;
    }

    // Pick files
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

    // Add to transfers list
    setState(() {
      for (final file in result.files) {
        _transfers.insert(0, TransferInfo(
          fileName: file.name,
          fileSize: file.size ?? 0,
          status: TransferStatus.sending,
          isOutgoing: true,
        ));
      }
    });

    // Send files
    try {
      await _transport.sendFiles(
        _selectedDevice!,
        filePaths,
        onProgress: (progress) {
          if (mounted && _transfers.isNotEmpty) {
            setState(() {
              _transfers[0] = _transfers[0].copyWith(progress: progress);
            });
          }
        },
      );

      // Mark as completed
      if (mounted) {
        setState(() {
          for (int i = 0; i < result.files.length && i < _transfers.length; i++) {
            _transfers[i] = _transfers[i].copyWith(
              status: TransferStatus.completed,
              progress: 1.0,
            );
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Files sent successfully! ✅')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_transfers.isNotEmpty) {
            _transfers[0] = _transfers[0].copyWith(status: TransferStatus.failed);
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
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isInitialized ? () {
              setState(() => _devices.clear());
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
        onPressed: _isInitialized ? _pickAndSendFiles : null,
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
                'Nearby Devices (${_devices.length})',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_devices.isEmpty && _isInitialized)
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
            child: _devices.isEmpty
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
                          'Make sure both devices are on the same Wi-Fi',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices.values.elementAt(index);
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
