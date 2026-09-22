import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

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
  StreamSubscription? _intentSub;

  // Files received from other apps (Quick Share, etc.)
  List<SharedMediaFile>? _sharedFiles;

  @override
  void initState() {
    super.initState();
    _initTransport();
    _initReceiveIntent();
  }

  /// Listen for files shared INTO our app from Quick Share / other apps
  void _initReceiveIntent() {
    // Handle files shared while app is already running
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> files) {
        if (files.isNotEmpty && mounted) {
          setState(() => _sharedFiles = files);
          _showSharedFilesDialog(files);
        }
      },
    );

    // Handle files shared that LAUNCHED the app (cold start)
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> files) {
      if (files.isNotEmpty && mounted) {
        setState(() => _sharedFiles = files);
        // Small delay to let the UI build first
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _showSharedFilesDialog(files);
        });
      }
    });
  }

  /// Show dialog when files are received from Quick Share / other apps
  void _showSharedFilesDialog(List<SharedMediaFile> files) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.file_present, size: 40),
        title: const Text('Files Received'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Received ${files.length} file(s) from another app:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            ...files.take(5).map((f) {
              final name = f.path.split('/').last.split('\\').last;
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(Icons.insert_drive_file, size: 16),
                    const SizedBox(width: 8),
                    Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              );
            }),
            if (files.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('...and ${files.length - 5} more'),
              ),
            const SizedBox(height: 16),
            const Text(
              'What would you like to do?',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _sharedFiles = null;
            },
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _forwardSharedFilesToDevice();
            },
            icon: const Icon(Icons.send),
            label: const Text('Send via FastShare'),
          ),
        ],
      ),
    );
  }

  /// Forward files received from Quick Share to another device via FastShare
  void _forwardSharedFilesToDevice() {
    if (_sharedFiles == null || _sharedFiles!.isEmpty) return;

    final filePaths = _sharedFiles!.map((f) => f.path).toList();
    _sharedFiles = null;

    if (_selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a device first, then try again!')),
      );
      return;
    }

    _sendFilePaths(filePaths);
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

    if (!mounted) return;

    // Show send method picker
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.send, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Send ${result.files.length} file(s) via...',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),

              // Option 1: FastShare (direct LAN)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: const Icon(Icons.wifi),
                ),
                title: const Text('FastShare (Direct LAN)'),
                subtitle: Text(
                  _selectedDevice != null
                    ? 'Send to ${_selectedDevice!.name}'
                    : 'Select a device first',
                ),
                enabled: _selectedDevice != null && _selectedDevice!.protocol == 'fastshare',
                onTap: () {
                  Navigator.pop(ctx);
                  _sendFilePaths(filePaths);
                },
              ),

              // Option 2: Quick Share / System Share
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.blue.withOpacity(0.2),
                  child: const Icon(Icons.share, color: Colors.blue),
                ),
                title: Text(Platform.isAndroid
                    ? 'Quick Share / Nearby Share'
                    : 'Windows Share (Quick Share)'),
                subtitle: const Text('Send via system share sheet'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sendViaSystemShare(filePaths);
                },
              ),

              // Option 3: LocalSend target (if selected)
              if (_selectedDevice != null && _selectedDevice!.protocol == 'localsend')
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.teal.withOpacity(0.2),
                    child: const Icon(Icons.devices, color: Colors.teal),
                  ),
                  title: Text('LocalSend to ${_selectedDevice!.name}'),
                  subtitle: const Text('Coming soon!'),
                  enabled: false,
                  onTap: null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Send files via the OS share sheet (Quick Share, Nearby Share, Bluetooth, etc.)
  Future<void> _sendViaSystemShare(List<String> filePaths) async {
    try {
      final xFiles = filePaths.map((p) => XFile(p)).toList();
      await Share.shareXFiles(
        xFiles,
        text: 'Shared via FastShare',
      );

      if (mounted) {
        // Add to transfer list as completed (system handled the transfer)
        setState(() {
          for (final path in filePaths) {
            final name = path.split('/').last.split('\\').last;
            _transfers.insert(0, TransferInfo(
              fileName: name,
              fileSize: 0,
              status: TransferStatus.completed,
              isOutgoing: true,
              progress: 1.0,
            ));
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('System share failed: $e')),
        );
      }
    }
  }

  /// Send files directly via FastShare protocol
  Future<void> _sendFilePaths(List<String> filePaths) async {
    if (_selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a device first!')),
      );
      return;
    }

    // Add to transfers list
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
          for (int i = 0; i < filePaths.length && i < _transfers.length; i++) {
            _transfers[i] = _transfers[i].copyWith(
              status: TransferStatus.completed,
              progress: 1.0,
            );
          }
        });
        if (_settings.showNotifications) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Files sent successfully! ✅')),
          );
        }
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
    _intentSub?.cancel();
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
          // Shared files banner (from Quick Share / other apps)
          if (_sharedFiles != null && _sharedFiles!.isNotEmpty)
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.file_present),
                title: Text('${_sharedFiles!.length} file(s) ready to forward'),
                subtitle: const Text('Tap to send to a FastShare device'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _sharedFiles = null),
                ),
                onTap: _forwardSharedFilesToDevice,
              ),
            ),
          if (_sharedFiles != null && _sharedFiles!.isNotEmpty)
            const SizedBox(height: 8),

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
                          'Also detects LocalSend devices!',
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
