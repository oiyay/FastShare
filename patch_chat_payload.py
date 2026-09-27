import re

# --- 1. Patch TransportManager ---
with open('lib/core/transport/transport_manager.dart', 'r') as f:
    content = f.read()

bad_payload = "final payload = {'id': payloadId, 'text': text, 'ts': timestamp};"
good_payload = "final payload = {'id': payloadId, 'text': text, 'ts': timestamp, 'senderName': _selfInfo!.name};"
content = content.replace(bad_payload, good_payload)

with open('lib/core/transport/transport_manager.dart', 'w') as f:
    f.write(content)


# --- 2. Patch HttpTransport ---
with open('lib/core/transport/http_transport.dart', 'r') as f:
    content = f.read()

bad_remote = "remoteName: 'Local Device', // UI will update this if known"
good_remote = "remoteName: payload['senderName'] ?? 'Unknown',"
content = content.replace(bad_remote, good_remote)

with open('lib/core/transport/http_transport.dart', 'w') as f:
    f.write(content)


# --- 3. Patch SignalingService ---
with open('lib/core/services/signaling_service.dart', 'r') as f:
    content = f.read()

bad_payload2 = "final payload = {'id': payloadId, 'text': text, 'ts': timestamp};"
good_payload2 = "final payload = {'id': payloadId, 'text': text, 'ts': timestamp, 'senderName': SettingsService().deviceName};"
content = content.replace(bad_payload2, good_payload2)

bad_remote2 = "remoteName: 'Unknown', // We can update this in UI"
good_remote2 = "remoteName: payload['senderName'] ?? 'Unknown',"
content = content.replace(bad_remote2, good_remote2)

with open('lib/core/services/signaling_service.dart', 'w') as f:
    f.write(content)
