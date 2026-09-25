import 'dart:async';
import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:fast_share/core/services/settings_service.dart';

class GlobalUser {
  final String uid;
  final String username;
  final DateTime lastActive;

  GlobalUser({required this.uid, required this.username, required this.lastActive});
}

class SignalingService {
  static final SignalingService _instance = SignalingService._internal();
  factory SignalingService() => _instance;
  SignalingService._internal();

  SupabaseClient? _supabase;
  RealtimeChannel? _channel;

  String? _uid;
  String? get uid => _uid;

  String? _username;
  String? get username => _username;

  final _usersController = StreamController<List<GlobalUser>>.broadcast();
  List<GlobalUser> _currentUsers = [];
  
  Stream<List<GlobalUser>> get onlineUsers async* {
    yield _currentUsers;
    yield* _usersController.stream;
  }

  final _incomingMessagesController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingMessages => _incomingMessagesController.stream;

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      _supabase = Supabase.instance.client;
    } catch (e) {
      print('[SignalingService] Supabase not initialized. Global P2P disabled.');
      _usersController.addError('Supabase credentials not found. Please set SUPABASE_URL and SUPABASE_ANON_KEY secrets in GitHub and rebuild.');
      return;
    }

    _uid = const Uuid().v4();
    final settings = SettingsService();
    _username = settings.username.isNotEmpty ? settings.username : 'Guest';

    // Listen for username changes
    settings.onSettingsChanged.listen((_) {
      final newUsername = settings.username.isNotEmpty ? settings.username : 'Guest';
      if (newUsername != _username && _channel != null) {
        _username = newUsername;
        _channel!.track({
          'uid': _uid,
          'username': _username,
          'online_at': DateTime.now().toIso8601String(),
        });
      }
    });

    // Join the global channel for presence and signaling
    _channel = _supabase!.channel('global_p2p');

    // Handle Presence updates
    _channel!.onPresenceSync((_) async {
      final state = _channel!.presenceState();
      final Map<String, GlobalUser> uniqueUsers = {};
      bool collisionDetected = false;
      
      for (final clientState in state) {
        for (final presence in clientState.presences) {
          final payload = presence.payload;
          
          final pUid = payload['uid'] as String?;
          final pUsername = payload['username'] as String?;
          
          if (pUid != null && pUsername != null) {
            if (pUid != _uid) {
              uniqueUsers[pUid] = GlobalUser(
                uid: pUid,
                username: pUsername,
                lastActive: DateTime.now(),
              );
              if (pUsername == _username) {
                collisionDetected = true;
              }
            }
          }
        }
      }
      
      _currentUsers = uniqueUsers.values.toList();

      if (collisionDetected) {
        final suffix = (1000 + Random().nextInt(9000)).toString();
        _username = '$_username#$suffix';
        settings.username = _username!;
        
        // Retrack our presence with the new unique username
        if (_channel != null) {
          await _channel!.track({
            'uid': _uid,
            'username': _username,
            'online_at': DateTime.now().toIso8601String(),
          });
        }
      }

      _usersController.add(_currentUsers);
    });

    // Handle direct signaling messages
    _channel!.onBroadcast(
      event: 'signaling',
      callback: (payload) {
        if (payload['target_uid'] == _uid) {
          _incomingMessagesController.add(payload);
        }
      },
    );

    // Subscribe to channel
    _channel!.subscribe((status, [error]) async {
      if (status == RealtimeSubscribeStatus.subscribed) {
        // Announce our presence
        await _channel!.track({
          'uid': _uid,
          'username': _username,
          'online_at': DateTime.now().toIso8601String(),
        });
      }
    });

    _isInitialized = true;
  }

  /// Send a WebRTC signaling message to a target user
  Future<void> sendSignal({
    required String targetUid,
    required String type, // 'offer', 'answer', 'ice_candidate', 'end'
    required Map<String, dynamic> data,
  }) async {
    if (_channel == null) return;
    
    await _channel!.sendBroadcastMessage(
      event: 'signaling',
      payload: {
        'target_uid': targetUid,
        'sender_uid': _uid,
        'type': type,
        'data': data,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  /// We no longer need these explicit methods since it's all handled by sendSignal
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

  Future<void> endCall(String callerUid, String roomId) async {
    // Send end signal
    await sendSignal(targetUid: 'ALL', type: 'end', data: {
      'roomId': roomId,
    });
  }

  void dispose() {
    _channel?.unsubscribe();
  }
}
