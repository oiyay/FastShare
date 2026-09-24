import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fast_share/core/services/settings_service.dart';

class GlobalUser {
  final String uid;
  final String username;
  final String status;
  GlobalUser(this.uid, this.username, this.status);
}

class SignalingService {
  static final SignalingService _instance = SignalingService._internal();
  factory SignalingService() => _instance;
  SignalingService._internal();

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseDatabase.instance.ref();
  
  User? _currentUser;
  String? get uid => _currentUser?.uid;

  Future<void> initialize() async {
    // 1. Anonymous Login
    final userCred = await _auth.signInAnonymously();
    _currentUser = userCred.user;
    if (_currentUser == null) throw Exception("Failed to login anonymously");

    // 2. Register user in DB
    final username = '@${SettingsService().deviceName.replaceAll(' ', '_').toLowerCase()}';
    final userRef = _db.child('users/${_currentUser!.uid}');
    
    await userRef.set({
      'username': username,
      'status': 'online',
      'timestamp': ServerValue.timestamp,
    });

    // 3. Auto-delete (Ghost detection) on disconnect
    userRef.onDisconnect().remove();
  }

  Stream<List<GlobalUser>> getOnlineUsers() {
    return _db.child('users').onValue.map((event) {
      final List<GlobalUser> users = [];
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        data.forEach((key, value) {
          if (key != uid) { // Exclude self
            users.add(GlobalUser(
              key.toString(),
              value['username'].toString(),
              value['status'].toString(),
            ));
          }
        });
      }
      return users;
    });
  }
  
  // Gets a reference to a specific call room
  DatabaseReference getCallRoom(String targetUid, String roomId) {
    return _db.child('signaling/$targetUid/incoming_calls/$roomId');
  }
  
  // Listen to my own incoming calls
  Stream<DatabaseEvent> get incomingCalls {
    if (uid == null) return const Stream.empty();
    return _db.child('signaling/$uid/incoming_calls').onChildAdded;
  }
}
