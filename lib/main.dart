import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/ui/home_screen.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  if (supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseKey,
    );
  } else {
    print('WARNING: Supabase credentials not found. Global P2P will be disabled.');
  }

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
