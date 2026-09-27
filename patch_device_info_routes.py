import re

with open('lib/core/models/device_info.dart', 'r') as f:
    content = f.read()

# Add fields
content = content.replace("final String protocol; // 'fastshare', 'localsend'", "final String protocol; // 'fastshare', 'localsend'\n  final bool hasLocalRoute;\n  final bool hasGlobalRoute;")

# Add to constructor
content = content.replace("this.protocol = 'fastshare',", "this.protocol = 'fastshare',\n    this.hasLocalRoute = false,\n    this.hasGlobalRoute = false,")

# Add to copyWith signature
content = content.replace("String? protocol,", "String? protocol,\n    bool? hasLocalRoute,\n    bool? hasGlobalRoute,")

# Add to copyWith return
content = content.replace("protocol: protocol ?? this.protocol,", "protocol: protocol ?? this.protocol,\n      hasLocalRoute: hasLocalRoute ?? this.hasLocalRoute,\n      hasGlobalRoute: hasGlobalRoute ?? this.hasGlobalRoute,")

with open('lib/core/models/device_info.dart', 'w') as f:
    f.write(content)
