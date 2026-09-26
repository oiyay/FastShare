import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:fast_share/core/models/device_info.dart';

class SignalingService {
  final String _uid = const Uuid().v4();
  String _username = '';
  String _os = '';

  WebSocketChannel? _channel;

  final _onlineUsersController = StreamController<List<DeviceInfo>>.broadcast();
  final _incomingMessagesController = StreamController<Map<String, dynamic>>.broadcast();
  
  // Expose Streams
  Stream<List<DeviceInfo>> get onlineUsers => _onlineUsersController.stream;
  Stream<Map<String, dynamic>> get incomingMessages => _incomingMessagesController.stream;

  String get uid => _uid;
  String get username => _username;

  Future<void> initialize(String username, String os) async {
    _username = username;
    _os = os;
    _connect();
  }

  void _connect() {
    final wsUrl = Uri.parse('wss://signaling.apcb.net/ws');
    
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
