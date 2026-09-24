import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/ui/home_screen.dart';

import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await SettingsService().init();

  // Request storage permissions on Android before app starts
  if (Platform.isAndroid) {
    await _requestStoragePermissions();
  }

  runApp(const FastShareApp());
}

/// Request all necessary storage permissions for Android.
Future<void> _requestStoragePermissions() async {
  // Only request standard storage permissions. This shows the normal
  // "Allow app to access photos and media" popup, avoiding the scary
  // "All files access" (MANAGE_EXTERNAL_STORAGE) settings screen.
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
