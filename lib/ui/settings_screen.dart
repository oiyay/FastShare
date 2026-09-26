import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fast_share/core/services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService();
  String _effectiveSavePath = '';
  late TextEditingController _nameController;

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
    _nameController = TextEditingController(text: _settings.deviceName);
    _loadEffectivePath();
    _settings.onSettingsChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadEffectivePath() async {
    final path = await _settings.getEffectiveSavePath();
    if (mounted) setState(() => _effectiveSavePath = path);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF181818) : const Color(0xFFF5F5F5),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Visual Identity Card (Discord Style)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF3A76F0), Color(0xFF1E5BB3)]),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 36,
                  backgroundColor: Colors.white24,
                  child: Icon(Icons.person, size: 40, color: Colors.white),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _settings.deviceName,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      ' #${_settings.shortTag}',
                      style: TextStyle(fontSize: 18, color: Colors.white.withOpacity(0.7)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'This is your secure cryptographic identity.\nNo one can hijack this tag.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Display Name', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: 'Enter your name...',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) => _settings.deviceName = val,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder),
                  title: const Text('Save Location'),
                  subtitle: Text(_effectiveSavePath.isEmpty ? 'Loading...' : _effectiveSavePath),
                  trailing: TextButton(
                    onPressed: () async {
                      final result = await FilePicker.platform.getDirectoryPath();
                      if (result != null) {
                        _settings.savePath = result;
                        _loadEffectivePath();
                      }
                    },
                    child: const Text('Change'),
                  ),
                ),
                if (_settings.savePath.isNotEmpty)
                  ListTile(
                    title: const Text('Reset to Default Location', style: TextStyle(color: Colors.red)),
                    onTap: () {
                      _settings.savePath = '';
                      _loadEffectivePath();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Auto-accept Transfers'),
                  subtitle: const Text('Automatically receive files from any device'),
                  value: _settings.autoAccept,
                  onChanged: (val) => _settings.autoAccept = val,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Show Notifications'),
                  subtitle: const Text('Alert when a transfer completes'),
                  value: _settings.showNotifications,
                  onChanged: (val) => _settings.showNotifications = val,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dark_mode),
                  title: const Text('Theme'),
                  trailing: DropdownButton<String>(
                    value: _settings.theme,
                    items: const [
                      DropdownMenuItem(value: 'system', child: Text('System')),
                      DropdownMenuItem(value: 'light', child: Text('Light')),
                      DropdownMenuItem(value: 'dark', child: Text('Dark')),
                    ],
                    onChanged: (val) => _settings.theme = val!,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.color_lens),
                  title: const Text('Accent Color'),
                  trailing: DropdownButton<int>(
                    value: _settings.colorSeed,
                    items: _colorOptions.entries.map((e) {
                      return DropdownMenuItem(
                        value: e.value.value,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(width: 16, height: 16, color: e.value),
                            const SizedBox(width: 8),
                            Text(e.key),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) => _settings.colorSeed = val!,
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 24),
          TextButton(
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Reset All Settings?'),
                  content: const Text('This will reset your theme, paths, and clear your cryptographic identity. You will lose your #tag.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset', style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (confirm == true) {
                await _settings.resetAll();
                if (mounted) Navigator.pop(context);
              }
            },
            child: const Text('Reset Application Data', style: TextStyle(color: Colors.red)),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
