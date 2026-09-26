import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  SharedPreferences? _prefs;
  final _changeController = StreamController<void>.broadcast();

  Stream<void> get onSettingsChanged => _changeController.stream;

  // Cryptographic Keys
  late SimpleKeyPair _keyPair;
  late String _publicKeyBase64;
  late String _shortTag;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    
    // Load or Generate Ed25519 Keypair
    final algo = Ed25519();
    final privKeyB64 = _prefs?.getString('priv_key');
    final pubKeyB64 = _prefs?.getString('pub_key');

    if (privKeyB64 == null || pubKeyB64 == null) {
      // First boot: Generate keys
      _keyPair = await algo.newKeyPair();
      final privKey = await _keyPair.extractPrivateKeyBytes();
      final pubKey = await _keyPair.extractPublicKey();
      
      _prefs?.setString('priv_key', base64Encode(privKey));
      _prefs?.setString('pub_key', base64Encode(pubKey.bytes));
      
      _publicKeyBase64 = base64Encode(pubKey.bytes);
    } else {
      // Load existing keys
      _publicKeyBase64 = pubKeyB64;
      _keyPair = SimpleKeyPairData(
        base64Decode(privKeyB64),
        publicKey: SimplePublicKey(base64Decode(pubKeyB64), type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
    }

    // Generate short tag (first 4 chars of SHA256 of Public Key, uppercase)
    final hash = await Sha256().hash(base64Decode(_publicKeyBase64));
    final hashHex = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _shortTag = hashHex.substring(0, 4).toUpperCase();
  }

  void _notify() => _changeController.add(null);

  SimpleKeyPair get keyPair => _keyPair;
  String get publicKeyBase64 => _publicKeyBase64;
  String get shortTag => _shortTag;
  
  // The unique ID used by TransportManager (replaces UUID)
  String get deviceId => _publicKeyBase64;

  String get deviceName {
    return _prefs?.getString('device_name') ?? Platform.localHostname;
  }

  set deviceName(String value) {
    _prefs?.setString('device_name', value);
    _notify();
  }

  String get fullIdentity => "$deviceName #$_shortTag";

  String get savePath {
    return _prefs?.getString('save_path') ?? '';
  }

  set savePath(String value) {
    _prefs?.setString('save_path', value);
    _notify();
  }

  static Future<String> getDefaultSavePath() async {
    if (Platform.isAndroid) {
      final appDir = await getExternalStorageDirectory();
      return '${appDir?.path ?? "/storage/emulated/0/Download"}/FastShare';
    } else if (Platform.isWindows) {
      return 'C:\\Users\\Public\\Downloads\\FastShare';
    } else {
      final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      return '${dir.path}/FastShare';
    }
  }

  Future<String> getEffectiveSavePath() async {
    final custom = savePath;
    if (custom.isNotEmpty) {
      try {
        final dir = Directory(custom);
        await dir.create(recursive: true);
        return custom;
      } catch (_) {}
    }
    final defaultPath = await getDefaultSavePath();
    try {
      await Directory(defaultPath).create(recursive: true);
      return defaultPath;
    } catch (_) {
      if (Platform.isAndroid) {
        final appDir = await getExternalStorageDirectory();
        final fallback = '${appDir?.path ?? "/data/local/tmp"}/FastShare';
        await Directory(fallback).create(recursive: true);
        return fallback;
      }
      return defaultPath;
    }
  }

  bool get autoAccept => _prefs?.getBool('auto_accept') ?? false;
  set autoAccept(bool value) { _prefs?.setBool('auto_accept', value); _notify(); }

  bool get showNotifications => _prefs?.getBool('show_notifications') ?? true;
  set showNotifications(bool value) { _prefs?.setBool('show_notifications', value); _notify(); }

  String get theme => _prefs?.getString('theme') ?? 'dark';
  set theme(String value) { _prefs?.setString('theme', value); _notify(); }
  ThemeMode get themeMode {
    switch (theme) {
      case 'light': return ThemeMode.light;
      case 'dark': return ThemeMode.dark;
      default: return ThemeMode.system;
    }
  }

  int get colorSeed => _prefs?.getInt('color_seed') ?? Colors.deepPurple.value;
  set colorSeed(int value) { _prefs?.setInt('color_seed', value); _notify(); }
  Color get colorSeedColor => Color(colorSeed);

  int get maxConcurrentTransfers => _prefs?.getInt('max_concurrent_transfers') ?? 3;
  set maxConcurrentTransfers(int value) { _prefs?.setInt('max_concurrent_transfers', value); _notify(); }

  Future<void> resetAll() async {
    await _prefs?.clear();
    _notify();
  }

  void dispose() {
    _changeController.close();
  }
}
