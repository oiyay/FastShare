import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fast_share/core/models/transfer_message.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  late Box<TransferMessage> _messagesBox;
  final _messagesController = StreamController<List<TransferMessage>>.broadcast();

  Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(TransferMessageAdapter());
    _messagesBox = await Hive.openBox<TransferMessage>('transfer_messages');
    _notify();
  }

  Stream<List<TransferMessage>> getMessagesStream(String remoteDeviceId) {
    // Return initial list then listen for changes
    late StreamController<List<TransferMessage>> controller;
    
    void emit() {
      final messages = _messagesBox.values
          .where((m) => m.senderId == remoteDeviceId || m.targetId == remoteDeviceId)
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      controller.add(messages);
    }

    controller = StreamController<List<TransferMessage>>(
      onListen: () {
        emit();
      },
    );

    final sub = _messagesController.stream.listen((_) {
      emit();
    });

    controller.onCancel = () {
      sub.cancel();
      controller.close();
    };

    return controller.stream;
  }
  
  List<TransferMessage> getRecentChats() {
    // Get latest message per remote device
    final map = <String, TransferMessage>{};
    for (final msg in _messagesBox.values) {
      final remoteId = msg.isSentByMe ? msg.targetId : msg.senderId;
      if (!map.containsKey(remoteId) || map[remoteId]!.timestamp < msg.timestamp) {
        map[remoteId] = msg;
      }
    }
    final list = map.values.toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  Stream<List<TransferMessage>> get recentChatsStream {
    late StreamController<List<TransferMessage>> controller;
    
    void emit() {
      controller.add(getRecentChats());
    }

    controller = StreamController<List<TransferMessage>>(
      onListen: () {
        emit();
      },
    );

    final sub = _messagesController.stream.listen((_) {
      emit();
    });

    controller.onCancel = () {
      sub.cancel();
      controller.close();
    };

    return controller.stream;
  }

  Future<void> saveMessage(TransferMessage msg) async {
    await _messagesBox.put(msg.id, msg);
    _notify();
  }

  Future<void> updateMessageStatus(String messageId, String status) async {
    final msg = _messagesBox.get(messageId);
    if (msg != null) {
      await _messagesBox.put(messageId, msg.copyWith(status: status));
      _notify();
    }
  }

  void _notify() {
    if (!_messagesController.isClosed) {
      _messagesController.add(_messagesBox.values.toList());
    }
  }
}
