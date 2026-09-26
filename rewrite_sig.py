import re

with open('lib/core/services/signaling_service.dart', 'r') as f:
    content = f.read()

# Make _connect async and sign the payload
replacement = """  Future<void> _connect() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final secret = 'FastShareSignaling2026!';
    final message = '$_uid:$timestamp';
    final hmac = Hmac(sha256, utf8.encode(secret));
    final signature = hmac.convert(utf8.encode(message)).toString();

    final keyPair = SettingsService().keyPair;
    final sig = await Ed25519().sign(utf8.encode(timestamp), keyPair: keyPair);
    final edSigBase64 = base64Encode(sig.bytes);

    final wsUrl = Uri.parse('wss://signaling.apcb.net/ws?uid=${Uri.encodeComponent(_uid)}&timestamp=$timestamp&signature=$signature&ed_sig=${Uri.encodeComponent(edSigBase64)}');"""

content = re.sub(r"  void _connect\(\) \{[\s\S]*?final wsUrl = Uri\.parse\('wss://signaling\.apcb\.net/ws\?uid=\$_uid&timestamp=\$timestamp&signature=\$signature'\);", replacement, content)

with open('lib/core/services/signaling_service.dart', 'w') as f:
    f.write(content)
