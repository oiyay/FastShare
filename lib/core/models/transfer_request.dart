import 'dart:convert';

/// Metadata for a single file in a transfer request.
class FileMetadata {
  final String id;
  final String name;
  final int size;
  final String? mimeType;

  FileMetadata({
    required this.id,
    required this.name,
    required this.size,
    this.mimeType,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        if (mimeType != null) 'mime_type': mimeType,
      };

  factory FileMetadata.fromJson(Map<String, dynamic> json) {
    return FileMetadata(
      id: json['id'] as String,
      name: json['name'] as String,
      size: json['size'] as int,
      mimeType: json['mime_type'] as String?,
    );
  }

  /// Human-readable file size string.
  String get sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// A request to transfer one or more files.
class TransferRequest {
  final String senderName;
  final String senderId;
  final List<FileMetadata> files;

  TransferRequest({
    required this.senderName,
    required this.senderId,
    required this.files,
  });

  /// Total size of all files in this request.
  int get totalSize => files.fold(0, (sum, f) => sum + f.size);

  Map<String, dynamic> toJson() => {
        'sender_name': senderName,
        'sender_id': senderId,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory TransferRequest.fromJson(Map<String, dynamic> json) {
    return TransferRequest(
      senderName: json['sender_name'] as String,
      senderId: json['sender_id'] as String,
      files: (json['files'] as List)
          .map((f) => FileMetadata.fromJson(f as Map<String, dynamic>))
          .toList(),
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory TransferRequest.fromJsonString(String source) =>
      TransferRequest.fromJson(jsonDecode(source) as Map<String, dynamic>);
}

/// Response to a transfer request.
class TransferResponse {
  final bool accepted;
  final String? token;

  TransferResponse({
    required this.accepted,
    this.token,
  });

  Map<String, dynamic> toJson() => {
        'status': accepted ? 'accepted' : 'rejected',
        if (token != null) 'token': token,
      };

  factory TransferResponse.fromJson(Map<String, dynamic> json) {
    return TransferResponse(
      accepted: json['status'] == 'accepted',
      token: json['token'] as String?,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory TransferResponse.fromJsonString(String source) =>
      TransferResponse.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
