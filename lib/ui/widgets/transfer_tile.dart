import 'package:flutter/material.dart';

/// Status of a file transfer.
enum TransferStatus {
  pending,
  sending,
  receiving,
  completed,
  failed,
}

/// Data class for tracking a transfer.
class TransferInfo {
  final String fileName;
  final int fileSize;
  final TransferStatus status;
  final double progress; // 0.0 to 1.0
  final bool isOutgoing;

  TransferInfo({
    required this.fileName,
    required this.fileSize,
    this.status = TransferStatus.pending,
    this.progress = 0.0,
    this.isOutgoing = true,
  });

  TransferInfo copyWith({
    TransferStatus? status,
    double? progress,
  }) {
    return TransferInfo(
      fileName: fileName,
      fileSize: fileSize,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      isOutgoing: isOutgoing,
    );
  }

  String get sizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// A ListTile widget for displaying a file transfer.
class TransferTile extends StatelessWidget {
  final TransferInfo transfer;

  const TransferTile({super.key, required this.transfer});

  IconData _statusIcon() {
    switch (transfer.status) {
      case TransferStatus.pending:
        return Icons.hourglass_empty;
      case TransferStatus.sending:
        return Icons.upload;
      case TransferStatus.receiving:
        return Icons.download;
      case TransferStatus.completed:
        return Icons.check_circle;
      case TransferStatus.failed:
        return Icons.error;
    }
  }

  Color _statusColor(BuildContext context) {
    switch (transfer.status) {
      case TransferStatus.pending:
        return Colors.grey;
      case TransferStatus.sending:
      case TransferStatus.receiving:
        return Theme.of(context).colorScheme.primary;
      case TransferStatus.completed:
        return Colors.green;
      case TransferStatus.failed:
        return Colors.red;
    }
  }

  String _statusText() {
    switch (transfer.status) {
      case TransferStatus.pending:
        return 'Waiting...';
      case TransferStatus.sending:
        return 'Sending ${(transfer.progress * 100).toStringAsFixed(0)}%';
      case TransferStatus.receiving:
        return 'Receiving ${(transfer.progress * 100).toStringAsFixed(0)}%';
      case TransferStatus.completed:
        return 'Completed';
      case TransferStatus.failed:
        return 'Failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_statusIcon(), color: _statusColor(context)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        transfer.fileName,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${transfer.sizeFormatted} • ${_statusText()}',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  transfer.isOutgoing ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 16,
                  color: Colors.grey[600],
                ),
              ],
            ),
            if (transfer.status == TransferStatus.sending ||
                transfer.status == TransferStatus.receiving) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: transfer.progress,
                backgroundColor: Colors.grey[800],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
