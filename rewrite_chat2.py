import re

with open('lib/core/services/signaling_service.dart', 'r') as f:
    content = f.read()

handler = """          } else if (type == 'signal') {
            final senderUid = data['sender_uid'] as String;
            final signalType = data['signal_type'] as String;
            final signalData = data['data'] as Map<String, dynamic>;

            if (signalType == 'chat') {
              final payloadStr = signalData['payload'] as String;
              final sigBase64 = signalData['sig'] as String;
              
              () async {
                try {
                  // Verify Ed25519 Signature
                  final pubKeyBytes = base64Decode(senderUid);
                  final sigBytes = base64Decode(sigBase64);
                  final pubKey = SimplePublicKey(pubKeyBytes, type: KeyPairType.ed25519);
                  final signature = Signature(sigBytes, publicKey: pubKey);
                  
                  final isValid = await Ed25519().verify(utf8.encode(payloadStr), signature: signature);
                  if (isValid) {
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
                    await DatabaseService().saveMessage(dbMsg);
                  } else {
                    print('WARNING: Dropped chat message with invalid signature from $senderUid');
                  }
                } catch (e) {
                  print('Error verifying chat signature: $e');
                }
              }();
              return;
            }

            final payload = {
              'sender_uid': senderUid,
              'type': signalType,
              'data': signalData,
            };
            _incomingMessagesController.add(payload);
          }"""

pattern = r"          \} else if \(type == 'signal'\) \{.*?\n            _incomingMessagesController\.add\(payload\);\n          \}"
content = re.sub(pattern, handler, content, flags=re.DOTALL)

with open('lib/core/services/signaling_service.dart', 'w') as f:
    f.write(content)
