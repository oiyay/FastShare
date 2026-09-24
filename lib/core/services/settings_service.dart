import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent settings service using SharedPreferences.
/// Singleton — use `SettingsService()` to access.
class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  SharedPreferences? _prefs;
  final _changeController = StreamController<void>.broadcast();

  /// Stream that fires when any setting changes.
  Stream<void> get onSettingsChanged => _changeController.stream;

  /// Initialize the service. Must be called before accessing settings.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  void _notify() => _changeController.add(null);

  // ── Device Name & Username ───────────────

  String get deviceName {
    return _prefs?.getString('device_name') ?? Platform.localHostname;
  }

  set deviceName(String value) {
    _prefs?.setString('device_name', value);
    _notify();
  }

  String get username {
    return _prefs?.getString('username') ?? '';
  }

  set username(String value) {
    _prefs?.setString('username', value);
    _notify();
  }

  String get effectiveUsername {
    final u = username;
    return u.isNotEmpty ? u : deviceName;
  }

  // ── Save Path ────────────────────────────

  String get savePath {
    return _prefs?.getString('save_path') ?? '';
  }

  set savePath(String value) {
    _prefs?.setString('save_path', value);
    _notify();
  }

  /// Get the platform-appropriate default save path.
  static Future<String> getDefaultSavePath() async {
    if (Platform.isAndroid) {
      // Use app-specific storage which doesn't require scary permissions on Android 11+
      final appDir = await getExternalStorageDirectory();
      return '${appDir?.path ?? "/storage/emulated/0/Download"}/FastShare';
    } else if (Platform.isWindows) {
      final dir = await getDownloadsDirectory();
      return '${dir?.path ?? "C:\\Users\\Public\\Downloads"}\\FastShare';
    } else {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      return '${dir.path}/FastShare';
    }
  }

  /// Get the effective save path (custom or default).
  /// Falls back to app-private storage if public folder isn't writable.
  Future<String> getEffectiveSavePath() async {
    final custom = savePath;
    if (custom.isNotEmpty) {
      // Verify the custom path is writable
      try {
        final dir = Directory(custom);
        await dir.create(recursive: true);
        return custom;
      } catch (_) {
        // Custom path not writable, fall back to default
      }
    }

    final defaultPath = await getDefaultSavePath();

    // Verify the default path is writable
    try {
      final dir = Directory(defaultPath);
      await dir.create(recursive: true);
      return defaultPath;
    } catch (_) {
      // Default path not writable (no MANAGE_EXTERNAL_STORAGE permission)
      // Fall back to app-private storage
      if (Platform.isAndroid) {
        final appDir = await getExternalStorageDirectory();
        final fallback = '${appDir?.path ?? "/data/local/tmp"}/FastShare';
        await Directory(fallback).create(recursive: true);
        return fallback;
      }
      return defaultPath; // On other platforms, just return default
    }
  }

  // ── Auto Accept ──────────────────────────

  bool get autoAccept {
    return _prefs?.getBool('auto_accept') ?? false;
  }

  set autoAccept(bool value) {
    _prefs?.setBool('auto_accept', value);
    _notify();
  }

  // ── Notifications ────────────────────────

  bool get showNotifications {
    return _prefs?.getBool('show_notifications') ?? true;
  }

  set showNotifications(bool value) {
    _prefs?.setBool('show_notifications', value);
    _notify();
  }

  // ── Theme ────────────────────────────────

  String get theme {
    return _prefs?.getString('theme') ?? 'dark';
  }

  set theme(String value) {
    _prefs?.setString('theme', value);
    _notify();
  }

  ThemeMode get themeMode {
    switch (theme) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  // ── Color Seed ───────────────────────────

  int get colorSeed {
    return _prefs?.getInt('color_seed') ?? Colors.deepPurple.value;
  }

  set colorSeed(int value) {
    _prefs?.setInt('color_seed', value);
    _notify();
  }

  Color get colorSeedColor => Color(colorSeed);

  // ── Max Concurrent Transfers ─────────────

  int get maxConcurrentTransfers {
    return _prefs?.getInt('max_concurrent_transfers') ?? 3;
  }

  set maxConcurrentTransfers(int value) {
    _prefs?.setInt('max_concurrent_transfers', value);
    _notify();
  }

  /// Reset all settings to defaults.
  Future<void> resetAll() async {
    await _prefs?.clear();
    _notify();
  }

  void dispose() {
    _changeController.close();
  }
}
