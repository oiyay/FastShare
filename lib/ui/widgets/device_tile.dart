import 'package:flutter/material.dart';

import 'package:fast_share/core/models/device_info.dart';

/// A ListTile widget for displaying a discovered device.
class DeviceTile extends StatelessWidget {
  final DeviceInfo device;
  final bool isSelected;
  final VoidCallback? onTap;

  const DeviceTile({
    super.key,
    required this.device,
    this.isSelected = false,
    this.onTap,
  });

  IconData _osIcon(String os) {
    switch (os) {
      case 'android':
        return Icons.phone_android;
      case 'windows':
        return Icons.desktop_windows;
      case 'linux':
        return Icons.computer;
      case 'macos':
        return Icons.laptop_mac;
      case 'ios':
        return Icons.phone_iphone;
      default:
        return Icons.devices;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: isSelected
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      child: ListTile(
        leading: Icon(
          _osIcon(device.os),
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : null,
          size: 32,
        ),
        title: Text(
          device.name,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text('${device.os.toUpperCase()} • ${device.ip}'),
        trailing: isSelected
            ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
            : null,
        onTap: onTap,
      ),
    );
  }
}
