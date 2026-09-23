import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/ui/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService().init();

  // Request storage permissions on Android before app starts
  if (Platform.isAndroid) {
    await _requestStoragePermissions();
  }

  runApp(const FastShareApp());
}

/// Request all necessary storage permissions for Android.
/// On Android 11+ (API 30+), we need MANAGE_EXTERNAL_STORAGE to write
/// to public folders like /storage/emulated/0/Download/FastShare.
/// On older versions, we only need READ/WRITE_EXTERNAL_STORAGE.
Future<void> _requestStoragePermissions() async {
  // Check if we already have manage external storage permission
  if (await Permission.manageExternalStorage.isGranted) {
    return; // Already granted
  }

  // Try requesting MANAGE_EXTERNAL_STORAGE (Android 11+)
  final manageStatus = await Permission.manageExternalStorage.request();
  if (manageStatus.isGranted) {
    return;
  }

  // Fallback: request basic storage permissions (Android 10 and below)
  await Permission.storage.request();
}

class FastShareApp extends StatefulWidget {
  const FastShareApp({super.key});

  @override
  State<FastShareApp> createState() => _FastShareAppState();
}

class _FastShareAppState extends State<FastShareApp> {
  final _settings = SettingsService();
  StreamSubscription? _settingsSub;

  @override
  void initState() {
    super.initState();
    _settingsSub = _settings.onSettingsChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _settingsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastShare',
      debugShowCheckedModeBanner: false,
      themeMode: _settings.themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        colorSchemeSeed: _settings.colorSeedColor,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: _settings.colorSeedColor,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
