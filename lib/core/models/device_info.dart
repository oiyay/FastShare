import 'dart:convert';

/// Represents a discovered device on the network.
class DeviceInfo {
  final String id;
  final String name;
  final String os; // 'android', 'windows', 'linux', 'macos', 'ios'
  final String ip;
  final int port; // HTTP port
  final int? tcpPort; // Raw TCP port for fastshare protocol
  final String protocol; // 'fastshare', 'localsend'
  final DateTime lastSeen;

  DeviceInfo({
    required this.id,
    required this.name,
    required this.os,
    required this.ip,
    required this.port,
    this.tcpPort,
    this.protocol = 'fastshare',
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  DeviceInfo copyWith({
    String? id,
    String? name,
    String? os,
    String? ip,
    int? port,
    int? tcpPort,
    String? protocol,
    DateTime? lastSeen,
  }) {
    return DeviceInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      os: os ?? this.os,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      tcpPort: tcpPort ?? this.tcpPort,
      protocol: protocol ?? this.protocol,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => {
        'app': 'FastShare',
        'version': '1.0',
        'id': id,
        'device_name': name,
        'os': os,
        'ip': ip,
        'port': port,
        if (tcpPort != null) 'tcp_port': tcpPort,
        'protocol': protocol,
      };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      id: json['id'] as String,
      name: json['device_name'] as String,
      os: json['os'] as String,
      ip: json['ip'] as String,
      port: json['port'] as int,
      tcpPort: json['tcp_port'] as int?,
      protocol: (json['protocol'] as String?) ?? 'fastshare',
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory DeviceInfo.fromJsonString(String source) =>
      DeviceInfo.fromJson(jsonDecode(source) as Map<String, dynamic>);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DeviceInfo && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DeviceInfo($name, $os, $ip:$port, $protocol)';
}
