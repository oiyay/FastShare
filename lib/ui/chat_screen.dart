import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_message.dart';
import 'package:fast_share/core/services/database_service.dart';
import 'package:fast_share/core/services/transfer_state_manager.dart';
import 'package:fast_share/core/transport/transport_manager.dart';
import 'package:intl/intl.dart';

class ChatScreen extends StatefulWidget {
  final DeviceInfo device;

  const ChatScreen({Key? key, required this.device}) : super(key: key);

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _transport = TransportManager();

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  void _sendFile() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null && result.paths.isNotEmpty) {
      final paths = result.paths.where((p) => p != null).cast<String>().toList();
      try {
        await _transport.sendFiles(widget.device, paths);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = const Color(0xFF3A76F0); // Signal Blue

    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF181818) : const Color(0xFFF5F5F5),
        elevation: 1,
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: primaryColor.withOpacity(0.2),
              child: Icon(Icons.person, color: primaryColor),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.device.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Text('${widget.device.os} • ${widget.device.protocol == "webrtc" ? "Global" : "Local"}', 
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<TransferMessage>>(
              stream: DatabaseService().getMessagesStream(widget.device.id),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return const Center(child: Text('No messages yet', style: TextStyle(color: Colors.grey)));
                }

                final messages = snapshot.data!;
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    final isMe = msg.isSentByMe;

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: isMe ? primaryColor : (isDark ? const Color(0xFF282828) : const Color(0xFFE8E8E8)),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMe ? 16 : 4),
                            bottomRight: Radius.circular(isMe ? 4 : 16),
                          ),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.insert_drive_file, color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black), size: 20),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    msg.fileName,
                                    style: TextStyle(color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black), fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _formatSize(msg.fileSize),
                              style: TextStyle(color: isMe ? Colors.white70 : Colors.grey, fontSize: 12),
                            ),
                            if (msg.status == 'transferring' || msg.status == 'pending') ...[
                              const SizedBox(height: 8),
                              ValueListenableBuilder<TransferProgress>(
                                valueListenable: TransferStateManager().getProgressNotifier(msg.id),
                                builder: (context, val, child) {
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      LinearProgressIndicator(
                                        value: val.progress,
                                        backgroundColor: isMe ? Colors.white24 : Colors.grey.shade300,
                                        valueColor: AlwaysStoppedAnimation(isMe ? Colors.white : primaryColor),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${(val.progress * 100).toStringAsFixed(0)}%',
                                        style: TextStyle(color: isMe ? Colors.white70 : Colors.grey, fontSize: 10),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ] else if (msg.status == 'failed') ...[
                              const SizedBox(height: 4),
                              const Text('Failed', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                            ],
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.bottomRight,
                              child: Text(
                                DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(msg.timestamp)),
                                style: TextStyle(color: isMe ? Colors.white60 : Colors.grey, fontSize: 10),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: isDark ? const Color(0xFF181818) : const Color(0xFFF5F5F5),
            child: Row(
              children: [
                FloatingActionButton(
                  onPressed: _sendFile,
                  mini: true,
                  backgroundColor: primaryColor,
                  elevation: 0,
                  child: const Icon(Icons.add, color: Colors.white),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    'Select a file to share securely...',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
