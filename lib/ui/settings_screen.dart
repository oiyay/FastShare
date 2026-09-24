import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'package:fast_share/core/services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  String _effectiveSavePath = '';

  static const _colorOptions = <String, Color>{
    'Deep Purple': Colors.deepPurple,
    'Blue': Colors.blue,
    'Teal': Colors.teal,
    'Green': Colors.green,
    'Orange': Colors.orange,
    'Red': Colors.red,
    'Pink': Colors.pink,
  };

  @override
  void initState() {
    super.initState();
    _loadSavePath();
  }

  Future<void> _loadSavePath() async {
    final path = await _settings.getEffectiveSavePath();
    if (mounted) setState(() => _effectiveSavePath = path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Device ───────────────────────
          _sectionHeader(context, 'Device & Profile', Icons.smartphone),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Device Name'),
                  subtitle: Text(_settings.deviceName),
                  trailing: const Icon(Icons.edit, size: 20),
                  onTap: _editDeviceName,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('Username'),
                  subtitle: Text(_settings.username.isEmpty 
                      ? 'Not set (defaults to Device Name)' 
                      : _settings.username),
                  trailing: const Icon(Icons.edit, size: 20),
                  onTap: _editUsername,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Storage ──────────────────────
          _sectionHeader(context, 'Storage', Icons.folder_outlined),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: const Text('Save Location'),
                  subtitle: Text(
                    _effectiveSavePath,
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.folder_open, size: 20),
                  onTap: _pickSaveDirectory,
                ),
                if (_settings.savePath.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.restart_alt),
                    title: const Text('Reset to Default'),
                    onTap: () async {
                      _settings.savePath = '';
                      await _loadSavePath();
                    },
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Transfer ─────────────────────
          _sectionHeader(context, 'Transfer', Icons.swap_horiz),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.check_circle_outline),
                  title: const Text('Auto Accept'),
                  subtitle: const Text('Accept incoming transfers automatically'),
                  value: _settings.autoAccept,
                  onChanged: (v) => setState(() => _settings.autoAccept = v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Show Notifications'),
                  subtitle: const Text('Notify on incoming transfer requests'),
                  value: _settings.showNotifications,
                  onChanged: (v) => setState(() => _settings.showNotifications = v),
                ),
                ListTile(
                  leading: const Icon(Icons.multiple_stop),
                  title: const Text('Max Concurrent Transfers'),
                  trailing: DropdownButton<int>(
                    value: _settings.maxConcurrentTransfers,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1')),
                      DropdownMenuItem(value: 2, child: Text('2')),
                      DropdownMenuItem(value: 3, child: Text('3')),
                      DropdownMenuItem(value: 5, child: Text('5')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _settings.maxConcurrentTransfers = v);
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Appearance ───────────────────
          _sectionHeader(context, 'Appearance', Icons.palette_outlined),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.brightness_6),
                  title: const Text('Theme'),
                  trailing: DropdownButton<String>(
                    value: _settings.theme,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 'system', child: Text('System')),
                      DropdownMenuItem(value: 'dark', child: Text('Dark')),
                      DropdownMenuItem(value: 'light', child: Text('Light')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _settings.theme = v);
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.color_lens_outlined),
                  title: const Text('Accent Color'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 10,
                      children: _colorOptions.entries.map((e) {
                        final isSelected = _settings.colorSeed == e.value.value;
                        return GestureDetector(
                          onTap: () => setState(() => _settings.colorSeed = e.value.value),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: e.value,
                              shape: BoxShape.circle,
                              border: isSelected
                                  ? Border.all(color: Colors.white, width: 3)
                                  : null,
                              boxShadow: isSelected
                                  ? [BoxShadow(color: e.value.withOpacity(0.6), blurRadius: 8)]
                                  : null,
                            ),
                            child: isSelected
                                ? const Icon(Icons.check, size: 18, color: Colors.white)
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── About ────────────────────────
          _sectionHeader(context, 'About', Icons.info_outline),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.rocket_launch),
                  title: const Text('FastShare'),
                  subtitle: const Text('v2.1.0 — Hybrid Protocol'),
                ),
                ListTile(
                  leading: const Icon(Icons.favorite, color: Colors.red),
                  title: const Text('Made with ❤️ using Flutter'),
                  subtitle: Text(
                    'Cross-platform LAN file sharing',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _settings.deviceName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Enter device name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.trim().isNotEmpty) {
      setState(() => _settings.deviceName = result.trim());
    }
  }

  Future<void> _editUsername() async {
    final controller = TextEditingController(text: _settings.username);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Username'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Enter custom username (optional)',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null) {
      setState(() => _settings.username = result.trim());
    }
  }

  Future<void> _pickSaveDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose save location for received files',
    );

    if (path != null) {
      setState(() {
        _settings.savePath = path;
        _effectiveSavePath = path;
      });
    }
  }
}
