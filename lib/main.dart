import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/ui/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService().init();
  runApp(const FastShareApp());
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
