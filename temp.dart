import 'dart:async';
import 'dart:convert';
import "package:crypto/crypto.dart";
import "package:fast_share/core/services/settings_service.dart";
import "package:fast_share/core/models/transfer_message.dart";
import "package:fast_share/core/services/database_service.dart";
import "package:cryptography/cryptography.dart";
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_message.dart';
import 'package:fast_share/core/services/database_service.dart';


class SignalingService {
  static final SignalingService _instance = SignalingService._internal();
  factory SignalingService() => _instance;
  SignalingService._internal();

  final String _uid = SettingsService().deviceId;
  String _username = '';
  String _os = '';

  WebSocketChannel? _channel;

  final _onlineUsersController = StreamController<List<DeviceInfo>>.broadcast();
  final _incomingMessagesController = StreamController<Map<String, dynamic>>.broadcast();
  
  List<DeviceInfo> _currentOnlineUsers = [];

  // Expose Streams
  Stream<List<DeviceInfo>> get onlineUsers async* {
    yield _currentOnlineUsers;
    yield* _onlineUsersController.stream;
  }
  Stream<Map<String, dynamic>> get incomingMessages => _incomingMessagesController.stream;

  String get uid => _uid;
  String get username => _username;

  bool _isInitialized = false;

  /// Send a cryptographically signed text message via WebSocket
  Future<void> sendChatMessage(String targetUid, String text) async {
    if (_channel == null) return;
    
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final payloadId = const Uuid().v4();
    final payload = {'id': payloadId, 'text': text, 'ts': timestamp};
    final payloadStr = jsonEncode(payload);

    // Sign the payload to prove identity
    final keyPair = SettingsService().keyPair;
    final sig = await Ed25519().sign(utf8.encode(payloadStr), keyPair: keyPair);
    
    final signal = {
      'type': 'signal',
      'target_uid': targetUid,
      'signal_type': 'chat',
      'data': {
        'payload': payloadStr,
        'sig': base64Encode(sig.bytes),
      }
    };
    
    _channel!.sink.add(jsonEncode(signal));
  }

  Future<void> initialize(String username, String os) async {
    if (_isInitialized) return;
    _isInitialized = true;
    _username = username;
    _os = os;
    _connect();
  }

  Future<void> _connect() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final secret = 'FastShareSignaling2026!';
    final message = '$_uid:$timestamp';
    final hmac = Hmac(sha256, utf8.encode(secret));
    final signature = hmac.convert(utf8.encode(message)).toString();

    final keyPair = SettingsService().keyPair;
    final sig = await Ed25519().sign(utf8.encode(timestamp), keyPair: keyPair);
    final edSigBase64 = base64Encode(sig.bytes);

    final wsUrl = Uri.parse('wss://signaling.apcb.net/ws?uid=${Uri.encodeComponent(_uid)}&timestamp=$timestamp&signature=$signature&ed_sig=${Uri.encodeComponent(edSigBase64)}');
    
    try {
      _channel = WebSocketChannel.connect(wsUrl);
      
      // Send Join message
      _channel!.sink.add(jsonEncode({
        'type': 'join',
        'uid': _uid,
        'username': _username,
        'os': _os,
      }));

      // Listen for incoming messages
      _channel!.stream.listen(
        (message) {
          final data = jsonDecode(message as String) as Map<String, dynamic>;
          final type = data['type'] as String?;

          if (type == 'presence') {
            final usersList = data['users'] as List;
            final devices = usersList.map<DeviceInfo>((u) {
              final userMap = u as Map<String, dynamic>;
              return DeviceInfo(
                id: userMap['uid'].toString(),
                name: userMap['username'].toString(),
                os: userMap['os'].toString(),
                ip: 'Remote P2P', // Display text
                port: 0,
              );
            }).toList();
            
            // Remove self from the list
            devices.removeWhere((d) => d.id == _uid);
            
            _currentOnlineUsers = devices;
            _onlineUsersController.add(devices);
          } else if (type == 'signal') {
            // A direct signal message targeted to us
            // Construct payload compatible with WebRtcTransport parser
            final payload = {
              'sender_uid': data['sender_uid'],
              'type': data['signal_type'],
              'data': data['data'],
            };
            _incomingMessagesController.add(payload);
          }
        },
        onDone: () {
          print('Signaling WebSocket closed. Reconnecting in 5s...');
          Future.delayed(const Duration(seconds: 5), _connect);
        },
        onError: (e) {
          print('Signaling WebSocket error: $e');
        }
      );
    } catch (e) {
      print('Failed to connect to signaling server: $e');
      Future.delayed(const Duration(seconds: 5), _connect);
    }
  }

  Future<void> sendSignal({
    required String targetUid,
    required String type, // 'offer', 'answer', 'ice_candidate', 'end', 'reject'
    required Map<String, dynamic> data,
  }) async {
    if (_channel == null) return;
    
    final payload = {
      'type': 'signal',
      'target_uid': targetUid,
      'sender_uid': _uid,
      'signal_type': type,
      'data': data,
    };
    
    _channel!.sink.add(jsonEncode(payload));
  }

  Future<void> sendOffer(String callerUid, String targetUid, String roomId, Map<String, dynamic> offerData) async {
    await sendSignal(targetUid: targetUid, type: 'offer', data: {
      'roomId': roomId,
      'offer': offerData,
    });
  }

  Future<void> sendAnswer(String callerUid, String targetUid, String roomId, Map<String, dynamic> answerData) async {
    await sendSignal(targetUid: targetUid, type: 'answer', data: {
      'roomId': roomId,
      'answer': answerData,
    });
  }

  Future<void> sendIceCandidate(String callerUid, String targetUid, String roomId, Map<String, dynamic> candidateData) async {
    await sendSignal(targetUid: targetUid, type: 'ice_candidate', data: {
      'roomId': roomId,
      'candidate': candidateData,
    });
  }

  Future<void> endCall(String targetUid, String roomId) async {
    await sendSignal(targetUid: targetUid, type: 'end', data: {
      'roomId': roomId,
    });
  }

  Future<void> sendReject(String targetUid, String roomId) async {
    await sendSignal(targetUid: targetUid, type: 'reject', data: {
      'roomId': roomId,
    });
  }

  void dispose() {
    _channel?.sink.close();
    _onlineUsersController.close();
    _incomingMessagesController.close();
  }
}
