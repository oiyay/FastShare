with open('lib/ui/chat_screen.dart', 'r') as f:
    content = f.read()

# Add a text controller
if "TextEditingController _textController =" not in content:
    content = content.replace("class _ChatScreenState extends State<ChatScreen> {", "class _ChatScreenState extends State<ChatScreen> {\n  final TextEditingController _textController = TextEditingController();")

# Add _sendText method
send_text = """
  void _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    
    // We send via SignalingService for global P2P secure chat
    try {
      final msg = TransferMessage(
        id: const Uuid().v4(),
        senderId: SettingsService().deviceId,
        targetId: widget.device.id,
        remoteName: widget.device.name,
        messageType: 'text',
        textContent: text,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isSentByMe: true,
        status: 'completed',
      );
      await DatabaseService().saveMessage(msg);
      await SignalingService().sendChatMessage(widget.device.id, text);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }
"""
if "void _sendText" not in content:
    content = content.replace("  void _sendFile() async {", send_text + "  void _sendFile() async {")

# Add UUID import and SignalingService
imports = """import 'package:uuid/uuid.dart';
import 'package:fast_share/core/services/settings_service.dart';
import 'package:fast_share/core/services/signaling_service.dart';
"""
content = content.replace("import 'package:intl/intl.dart';", "import 'package:intl/intl.dart';\n" + imports)

# Update the Bubble Builder for text messages
bubble_code = """
                            if (msg.messageType == 'text') ...[
                              Text(
                                msg.textContent ?? '',
                                style: TextStyle(color: isMe ? Colors.white : (isDark ? Colors.white : Colors.black), fontSize: 16),
                              ),
                            ] else ...[
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
                            ],
"""
import re
content = re.sub(r"                            Row\([\s\S]*?const Text\('Failed', style: TextStyle\(color: Colors\.redAccent, fontSize: 12\)\),\n                            \],", bubble_code, content)

# Update Bottom Input Field
input_field = """
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: isDark ? const Color(0xFF181818) : const Color(0xFFF5F5F5),
            child: Row(
              children: [
                IconButton(
                  onPressed: _sendFile,
                  icon: const Icon(Icons.add_circle, color: Colors.grey),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF282828) : Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.grey.withOpacity(0.3)),
                    ),
                    child: TextField(
                      controller: _textController,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  onPressed: _sendText,
                  mini: true,
                  backgroundColor: primaryColor,
                  elevation: 0,
                  child: const Icon(Icons.send, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
"""
content = re.sub(r"          Container\(\n            padding: const EdgeInsets\.symmetric\(horizontal: 16, vertical: 12\),[\s\S]*?\n          \),", input_field, content)

with open('lib/ui/chat_screen.dart', 'w') as f:
    f.write(content)
