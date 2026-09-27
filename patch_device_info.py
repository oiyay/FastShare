import re

with open('lib/core/models/device_info.dart', 'r') as f:
    content = f.read()

# Add crypto import
if "package:crypto/crypto.dart" not in content:
    content = content.replace("import 'dart:convert';", "import 'dart:convert';\nimport 'package:crypto/crypto.dart';")

# Add shortTag getter
getter = """
  /// Automatically computes the Discord-style 4-character tag from the Base64 ID
  String get shortTag {
    try {
      final bytes = base64Decode(id);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 4).toUpperCase();
    } catch (_) {
      // Fallback if ID is an old UUID instead of Base64 Ed25519 key
      return id.length > 4 ? id.substring(0, 4).toUpperCase() : id;
    }
  }

  /// Returns the beautifully formatted display name with the tag (e.g. Athar #9A2B)
  String get displayName => '$name #$shortTag';
"""

if "String get shortTag" not in content:
    content = content.replace("  DeviceInfo({", getter + "\n  DeviceInfo({")

with open('lib/core/models/device_info.dart', 'w') as f:
    f.write(content)
