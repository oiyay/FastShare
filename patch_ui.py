with open('lib/ui/home_screen.dart', 'r') as f:
    content = f.read()

bad = """                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: CircleAvatar(
                              radius: 10,
                              backgroundColor: isDark ? Colors.black : Colors.white,
                              child: CircleAvatar(
                                radius: 8,
                                backgroundColor: isGlobal ? primaryColor : Colors.green,
                                child: Icon(isGlobal ? Icons.public : Icons.wifi, size: 10, color: Colors.white),
                              ),
                            ),
                          ),"""
                          
good = """                          if (device.hasLocalRoute || device.hasGlobalRoute)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: CircleAvatar(
                                radius: 10,
                                backgroundColor: isDark ? Colors.black : Colors.white,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (device.hasLocalRoute)
                                      const CircleAvatar(radius: 5, backgroundColor: Colors.green, child: Icon(Icons.wifi, size: 6, color: Colors.white)),
                                    if (device.hasGlobalRoute)
                                      CircleAvatar(radius: 5, backgroundColor: primaryColor, child: const Icon(Icons.public, size: 6, color: Colors.white)),
                                  ],
                                ),
                              ),
                            ),"""
content = content.replace(bad, good)

# Also fix `final isGlobal = device.protocol == 'webrtc';` which is unused now
content = content.replace("final isGlobal = device.protocol == 'webrtc';", "")

with open('lib/ui/home_screen.dart', 'w') as f:
    f.write(content)
