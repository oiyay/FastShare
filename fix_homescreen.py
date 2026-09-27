with open('lib/ui/home_screen.dart', 'r') as f:
    content = f.read()

bad = "name: 'Unknown ($remoteId)'"
good = "name: msg.remoteName"
content = content.replace(bad, good)

# Also change ListTile title from msg.remoteName to remoteDevice.displayName
bad_title = "title: Text(msg.remoteName, style: const TextStyle(fontWeight: FontWeight.bold)),"
good_title = "title: Text(remoteDevice.displayName, style: const TextStyle(fontWeight: FontWeight.bold)),"
content = content.replace(bad_title, good_title)

# Same for Text(device.name, ...) which we already changed to Text(device.displayName, ...)

with open('lib/ui/home_screen.dart', 'w') as f:
    f.write(content)
