import 'package:hive/hive.dart';

class TransferMessage {
  final String id;
  final String senderId;
  final String targetId;
  final String remoteName;
  final String fileName;
  final int fileSize;
  final int timestamp;
  final bool isSentByMe;
  final String status; // 'pending', 'transferring', 'completed', 'failed', 'rejected'

  TransferMessage({
    required this.id,
    required this.senderId,
    required this.targetId,
    required this.remoteName,
    required this.fileName,
    required this.fileSize,
    required this.timestamp,
    required this.isSentByMe,
    required this.status,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'targetId': targetId,
      'fileName': fileName,
      'fileSize': fileSize,
      'timestamp': timestamp,
      'isSentByMe': isSentByMe,
      'status': status,
    };
  }

  factory TransferMessage.fromJson(Map<dynamic, dynamic> json) {
    return TransferMessage(
      id: json['id'],
      senderId: json['senderId'],
      targetId: json['targetId'],
      remoteName: json['remoteName'] ?? 'Unknown',
      fileName: json['fileName'],
      fileSize: json['fileSize'],
      timestamp: json['timestamp'],
      isSentByMe: json['isSentByMe'],
      status: json['status'],
    );
  }

  TransferMessage copyWith({
    String? status,
  }) {
    return TransferMessage(
      id: this.id,
      senderId: this.senderId,
      targetId: this.targetId,
      remoteName: this.remoteName,
      fileName: this.fileName,
      fileSize: this.fileSize,
      timestamp: this.timestamp,
      isSentByMe: this.isSentByMe,
      status: status ?? this.status,
    );
  }
}

class TransferMessageAdapter extends TypeAdapter<TransferMessage> {
  @override
  final typeId = 0;

  @override
  TransferMessage read(BinaryReader reader) {
    final map = reader.readMap();
    return TransferMessage.fromJson(map);
  }

  @override
  void write(BinaryWriter writer, TransferMessage obj) {
    writer.writeMap(obj.toJson());
  }
}
