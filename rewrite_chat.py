import re

with open('lib/core/services/signaling_service.dart', 'r') as f:
    content = f.read()

# Add sendChatMessage method
chat_method = """  /// Send a cryptographically signed text message via WebSocket
  Future<void> sendChatMessage(String targetUid, String text) async {
    if (_channel == null) return;
    
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final payloadId = const Uuid().v4();
    final payload = {'id': payloadId, 'text': text, 'ts': timestamp};
    final payloadStr = jsonEncode(payload);

    // Sign the payload to prove identity
    final keyPair = SettingsService().keyPair;
    final sig = await Ed25519().sign(utf8.encode(payloadStr), keyPair: keyPair);
    
    final signal = {
      'type': 'signal',
      'target_uid': targetUid,
      'signal_type': 'chat',
      'data': {
        'payload': payloadStr,
        'sig': base64Encode(sig.bytes),
      }
    };
    
    _channel!.sink.add(jsonEncode(signal));
  }
"""

if "sendChatMessage" not in content:
    content = content.replace("  Future<void> initialize(String username, String os) async {", chat_method + "\n  Future<void> initialize(String username, String os) async {")

# Update signal handler to process 'chat'
handler_code = """
        if (signalType == 'chat') {
          final payloadStr = data['payload'] as String;
          final sigBase64 = data['sig'] as String;
          
          try {
            // Verify Ed25519 Signature
            final pubKeyBytes = base64Decode(senderUid);
            final sigBytes = base64Decode(sigBase64);
            final pubKey = SimplePublicKey(pubKeyBytes, type: KeyPairType.ed25519);
            final signature = Signature(sigBytes, publicKey: pubKey);
            
            final isValid = await Ed25519().verify(utf8.encode(payloadStr), signature: signature);
            if (isValid) {
              final payload = jsonDecode(payloadStr);
              // Save to Database directly!
              // Wait, we need to import DatabaseService and TransferMessage.
              // Assuming they are imported.
            } else {
              print('WARNING: Dropped chat message with invalid signature from $senderUid');
            }
          } catch (e) {
            print('Error verifying chat signature: $e');
          }
          return; // Don't forward to WebRTC controller
        }

        _signalController.add({
"""

content = content.replace("        _signalController.add({", handler_code)

# Add missing imports if needed
imports = """
import 'package:fast_share/core/models/transfer_message.dart';
import 'package:fast_share/core/services/database_service.dart';
"""
if "transfer_message.dart" not in content:
    content = content.replace("import 'package:fast_share/core/models/device_info.dart';", "import 'package:fast_share/core/models/device_info.dart';" + imports)


# Inject DB save logic inside the isValid block
db_save = """
              final payload = jsonDecode(payloadStr);
              final dbMsg = TransferMessage(
                id: payload['id'],
                senderId: senderUid,
                targetId: _uid,
                remoteName: 'Unknown', // We can update this in UI
                messageType: 'text',
                textContent: payload['text'],
                timestamp: payload['ts'],
                isSentByMe: false,
                status: 'completed',
              );
              DatabaseService().saveMessage(dbMsg);
"""
content = content.replace("""              final payload = jsonDecode(payloadStr);
              // Save to Database directly!
              // Wait, we need to import DatabaseService and TransferMessage.
              // Assuming they are imported.""", db_save)


with open('lib/core/services/signaling_service.dart', 'w') as f:
    f.write(content)
