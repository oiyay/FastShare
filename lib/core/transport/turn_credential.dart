import 'dart:convert';
import 'package:crypto/crypto.dart';

Map<String, String> generateTurnCredentials() {
  final secret = 'FastShareSup3rS3cr3t2026'; // Match static-auth-secret
  final unixNow = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
  final expiry = unixNow + 86400; // 24 hours
  final username = '$expiry:fastshare';
  
  final hmacSha1 = Hmac(sha1, utf8.encode(secret));
  final digest = hmacSha1.convert(utf8.encode(username));
  final password = base64Encode(digest.bytes);
  
  return {
    'username': username,
    'credential': password,
  };
}
