import 'dart:async';
import 'package:flutter/foundation.dart';

class TransferProgress {
  final double progress;
  final String status;

  TransferProgress(this.progress, this.status);
}

class TransferStateManager {
  static final TransferStateManager _instance = TransferStateManager._internal();
  factory TransferStateManager() => _instance;
  TransferStateManager._internal();

  // Maps Message ID -> ValueNotifier of Progress
  final Map<String, ValueNotifier<TransferProgress>> _activeTransfers = {};

  ValueNotifier<TransferProgress> getProgressNotifier(String messageId) {
    if (!_activeTransfers.containsKey(messageId)) {
      _activeTransfers[messageId] = ValueNotifier(TransferProgress(0.0, 'pending'));
    }
    return _activeTransfers[messageId]!;
  }

  void updateProgress(String messageId, double progress, String status) {
    if (_activeTransfers.containsKey(messageId)) {
      _activeTransfers[messageId]!.value = TransferProgress(progress, status);
    }
  }

  void finishTransfer(String messageId) {
    _activeTransfers.remove(messageId);
  }
}
