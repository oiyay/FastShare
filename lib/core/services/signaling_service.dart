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
  String? _username;

  Future<void> initialize() async {
    final userCred = await _auth.signInAnonymously();
    _currentUser = userCred.user;
    if (_currentUser == null) throw Exception("Failed to login anonymously");

    _username = '@${SettingsService().deviceName.replaceAll(' ', '_').toLowerCase()}';
    final userRef = _db.child('users/${_currentUser!.uid}');
    
    await userRef.set({
      'username': _username,
      'status': 'online',
      'timestamp': ServerValue.timestamp,
    });

    userRef.onDisconnect().remove();
  }

  Stream<List<GlobalUser>> getOnlineUsers() {
    return _db.child('users').onValue.map((event) {
      final List<GlobalUser> users = [];
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        data.forEach((key, value) {
          if (key != uid) {
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

  // WEBRTC SIGNALING METHODS
  
  Stream<DatabaseEvent> get incomingCalls {
    if (uid == null) return const Stream.empty();
    return _db.child('signaling/$uid/incoming_calls').onChildAdded;
  }

  DatabaseReference getCallRoom(String targetUid, String roomId) {
    return _db.child('signaling/$targetUid/incoming_calls/$roomId');
  }

  Future<void> sendOffer(String targetUid, String roomId, Map<String, dynamic> offer, Map<String, dynamic> transferRequestJson) async {
    await getCallRoom(targetUid, roomId).set({
      'caller_uid': uid,
      'caller_username': _username,
      'offer': offer,
      'transfer_request': transferRequestJson,
      'status': 'ringing',
      'timestamp': ServerValue.timestamp,
    });
  }

  Future<void> sendAnswer(String callerUid, String roomId, Map<String, dynamic> answer) async {
    // Write answer to my own room so caller can read it
    await _db.child('signaling/$uid/incoming_calls/$roomId').update({
      'answer': answer,
      'status': 'accepted',
    });
  }

  Future<void> addIceCandidate(String targetUid, String roomId, Map<String, dynamic> candidate, bool isCaller) async {
    final node = isCaller ? 'candidates_from_caller' : 'candidates_from_receiver';
    await _db.child('signaling/$targetUid/incoming_calls/$roomId/$node').push().set(candidate);
  }

  Stream<DatabaseEvent> listenToAnswer(String targetUid, String roomId) {
    return _db.child('signaling/$targetUid/incoming_calls/$roomId/answer').onValue;
  }

  Stream<DatabaseEvent> listenToIceCandidates(String targetUid, String roomId, bool isCaller) {
    final node = isCaller ? 'candidates_from_receiver' : 'candidates_from_caller';
    return _db.child('signaling/$targetUid/incoming_calls/$roomId/$node').onChildAdded;
  }

  Future<void> endCall(String targetUid, String roomId) async {
    await _db.child('signaling/$targetUid/incoming_calls/$roomId').remove();
  }
}
