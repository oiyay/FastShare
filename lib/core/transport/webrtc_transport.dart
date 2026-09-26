import 'dart:async';
import 'dart:convert';
import 'dart:io';
import "turn_credential.dart";
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/transport/transport_interface.dart';
import 'package:fast_share/core/services/signaling_service.dart';

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? digest;
  @override
  void add(crypto.Digest data) => digest = data;
  @override
  void close() {}
}

class WebRtcTransport implements TransportInterface {
  final SignalingService _signaling = SignalingService();
  final _requestController = StreamController<TransferRequest>.broadcast();
  StreamSubscription? _signalingSub;
  
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCDataChannel> _dataChannels = {};
  
  final Map<String, Map<String, IOSink>> _activeSinks = {};
  final Map<String, Map<String, int>> _expectedSizes = {};
  final Map<String, Map<String, int>> _bytesReceived = {};
  final Map<String, Map<String, String>> _fileNames = {};
  final Map<String, Map<String, String>> _filePaths = {};
  final Map<String, void Function(String, double)> _progressCallbacks = {};
  final Map<String, int> _lastUpdateTimes = {};

  final Map<String, Map<String, dynamic>> _pendingIncomingCalls = {};
  final Map<String, List<Map<String, dynamic>>> _iceCandidateQueue = {};
  final Map<String, Completer<TransferResponse>> _transferCompleters = {};

  Map<String, dynamic> get _iceServers {
    final creds = generateTurnCredentials();
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {
          'urls': 'turn:101.32.142.137:3478',
          'username': creds['username'],
          'credential': creds['credential']
        },
        {
          // Fallback to openrelay just in case the VPS goes down
          'urls': 'turn:openrelay.metered.ca:80',
          'username': 'openrelayproject',
          'credential': 'openrelayproject'
        }
      ]
    };
  }

  @override
  Future<void> initialize() async {
    await _signaling.initialize();
    _signalingSub = _signaling.incomingMessages.listen(_handleIncomingMessage);
  }

  void _handleIncomingMessage(Map<String, dynamic> payload) async {
    final senderUid = payload['sender_uid'] as String;
    final type = payload['type'] as String;
    final data = payload['data'] as Map<String, dynamic>;

    if (type == 'offer') {
      _handleOffer(senderUid, data);
    } else if (type == 'answer') {
      _handleAnswer(senderUid, data);
    } else if (type == 'ice_candidate') {
      _handleIceCandidate(senderUid, data);
    } else if (type == 'reject') {
      _handleReject(senderUid);
    } else if (type == 'end') {
      _cleanupConnection(senderUid);
    }
  }

  void _handleReject(String senderUid) {
    final completer = _transferCompleters.remove(senderUid);
    if (completer != null && !completer.isCompleted) {
      completer.complete(TransferResponse(accepted: false));
    }
    _cleanupConnection(senderUid);
  }

  void _handleOffer(String senderUid, Map<String, dynamic> data) async {
    final roomId = data['roomId'] as String;
    final offerData = data['offer'] as Map<String, dynamic>;
    
    // Convert to TransferRequest
    final reqDataStr = offerData['requestJson'];
    if (reqDataStr == null) return;
    
    final reqData = jsonDecode(reqDataStr) as Map<String, dynamic>;
    
    // We MUST use senderUid (the signaling ID) instead of the one in JSON (which is TransportManager's ID).
    // Otherwise, the receiver won't be able to send the Answer back to the correct signaling target.
    final request = TransferRequest(
      senderName: reqData['sender_name'].toString(),
      senderId: senderUid, 
      files: (reqData['files'] as List).map((f) => FileMetadata.fromJson(f)).toList(),
    );

    _pendingIncomingCalls[senderUid] = {
      'roomId': roomId,
      'offer': offerData,
    };

    _requestController.add(request);
  }

  void _handleAnswer(String senderUid, Map<String, dynamic> data) async {
    final pc = _peerConnections[senderUid];
    if (pc != null) {
      final answerData = data['answer'] as Map<String, dynamic>;
      await pc.setRemoteDescription(RTCSessionDescription(answerData['sdp'], answerData['type']));
      
      // Process queued candidates
      final queue = _iceCandidateQueue[senderUid];
      if (queue != null) {
        for (final c in queue) {
          await pc.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
        }
        _iceCandidateQueue.remove(senderUid);
      }
      
      final completer = _transferCompleters.remove(senderUid);
      if (completer != null && !completer.isCompleted) {
        final roomId = data['roomId'] as String?;
        completer.complete(TransferResponse(accepted: true, token: roomId));
      }
    }
  }

  void _handleIceCandidate(String senderUid, Map<String, dynamic> data) async {
    final pc = _peerConnections[senderUid];
    final candidateData = data['candidate'] as Map<String, dynamic>;
    
    if (pc != null && await pc.getRemoteDescription() != null) {
      await pc.addCandidate(RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      ));
    } else {
      // Queue until remote description is set
      _iceCandidateQueue.putIfAbsent(senderUid, () => []).add(candidateData);
    }
  }

  @override
  Future<void> dispose() async {
    _signalingSub?.cancel();
    _requestController.close();
    for (final pc in _peerConnections.values) {
      pc.close();
    }
    _peerConnections.clear();
  }

  @override
  Stream<DeviceInfo> discoverDevices() {
    return const Stream.empty();
  }

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request, {
    String? pin,
  }) async {
    final roomId = const Uuid().v4();
    final targetUid = target.id;
    
    final pc = await createPeerConnection(_iceServers);
    _peerConnections[targetUid] = pc;
    
    final dcInit = RTCDataChannelInit()
      ..ordered = true; // Fully reliable and ordered for file transfers
      
    final dc = await pc.createDataChannel('fastshare_data', dcInit);
    _dataChannels[targetUid] = dc;
    _setupDataChannel(dc, targetUid);

    pc.onIceCandidate = (candidate) async {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      await _signaling.sendIceCandidate(_signaling.uid!, targetUid, roomId, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onIceConnectionState = (state) {
      print('Sender ICE Connection State: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _cleanupConnection(targetUid);
      }
    };

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    final completer = Completer<TransferResponse>();
    _transferCompleters[targetUid] = completer;

    await _signaling.sendOffer(_signaling.uid!, targetUid, roomId, {
      'type': offer.type,
      'sdp': offer.sdp,
      'requestJson': jsonEncode(request.toJson()),
    });

    // Wait for the receiver to accept (send an answer) or reject
    return completer.future.timeout(
      const Duration(minutes: 2), // Generous timeout to let the user read the dialog
      onTimeout: () {
        _transferCompleters.remove(targetUid);
        return TransferResponse(accepted: false);
      },
    );
  }

  @override
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    final callerUid = request.senderId;
    final callData = _pendingIncomingCalls[callerUid];
    if (callData == null) return;

    final roomId = callData['roomId'] as String;
    final offerData = callData['offer'] as Map<String, dynamic>;

    _activeSinks[callerUid] = {};
    _expectedSizes[callerUid] = {};
    _bytesReceived[callerUid] = {};
    _fileNames[callerUid] = {};
    _filePaths[callerUid] = {};
    if (onProgress != null) _progressCallbacks[callerUid] = onProgress;

    for (final f in request.files) {
      final safeName = f.name.replaceAll(RegExp(r'[\\/]'), '_');
      final path = '$savePath${Platform.pathSeparator}$safeName';
      final file = File(path);
      
      _activeSinks[callerUid]![f.id] = file.openWrite();
      _expectedSizes[callerUid]![f.id] = f.size;
      _bytesReceived[callerUid]![f.id] = 0;
      _fileNames[callerUid]![f.id] = f.name;
      _filePaths[callerUid]![f.id] = path;
    }

    final pc = await createPeerConnection(_iceServers);
    _peerConnections[callerUid] = pc;

    pc.onDataChannel = (dc) {
      _dataChannels[callerUid] = dc;
      _setupDataChannel(dc, callerUid);
    };

    pc.onIceCandidate = (candidate) async {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      await _signaling.sendIceCandidate(_signaling.uid!, callerUid, roomId, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onIceConnectionState = (state) {
      print('Receiver ICE Connection State: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _cleanupConnection(callerUid);
      }
    };

    await pc.setRemoteDescription(RTCSessionDescription(offerData['sdp'], offerData['type']));
    
    // Process queued candidates
    final queue = _iceCandidateQueue[callerUid];
    if (queue != null) {
      for (final c in queue) {
        await pc.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
      }
      _iceCandidateQueue.remove(callerUid);
    }

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    await _signaling.sendAnswer(_signaling.uid!, callerUid, roomId, {
      'type': answer.type,
      'sdp': answer.sdp,
    });

    _pendingIncomingCalls.remove(callerUid);
  }

  @override
  Future<void> rejectTransfer(TransferRequest request) async {
    final callerUid = request.senderId;
    final callData = _pendingIncomingCalls[callerUid];
    if (callData != null) {
      final roomId = callData['roomId'] as String;
      await _signaling.sendReject(callerUid, roomId);
      _pendingIncomingCalls.remove(callerUid);
    }
  }

  void _setupDataChannel(RTCDataChannel dc, String targetUid) {
    dc.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary) {
        final data = message.binary;
        if (data.length < 4) return;
        
        final lengthData = ByteData.view(data.buffer, data.offsetInBytes, 4);
        final jsonLength = lengthData.getUint32(0, Endian.big);
        
        if (data.length < 4 + jsonLength) return;
        
        final jsonStr = utf8.decode(data.sublist(4, 4 + jsonLength));
        final frame = jsonDecode(jsonStr) as Map<String, dynamic>;
        
        final payload = data.sublist(4 + jsonLength);
        _handleDecodedFrame(targetUid, frame, payload);
      }
    };
  }

  void _handleDecodedFrame(String senderId, Map<String, dynamic> frame, Uint8List payload) {
    final type = frame['type'];
    if (type == 'file_chunk') {
      final fileId = frame['fileId'] as String;
      final sink = _activeSinks[senderId]?[fileId];
      if (sink != null) {
        sink.add(payload);
        
        final received = (_bytesReceived[senderId]![fileId] ?? 0) + payload.length;
        _bytesReceived[senderId]![fileId] = received;
        
        final size = _expectedSizes[senderId]![fileId] ?? 1;
        final name = _fileNames[senderId]![fileId] ?? fileId;
        
        final now = DateTime.now().millisecondsSinceEpoch;
        final lastUpdate = _lastUpdateTimes[senderId] ?? 0;
        if (now - lastUpdate > 32 || received == size) {
          _progressCallbacks[senderId]?.call(name, received / size);
          _lastUpdateTimes[senderId] = now;
        }
      }
    } else if (type == 'file_complete') {
      final fileId = frame['fileId'] as String;
      _activeSinks[senderId]?[fileId]?.close();
      _activeSinks[senderId]?.remove(fileId);
      
      final name = _fileNames[senderId]![fileId] ?? fileId;
      _progressCallbacks[senderId]?.call(name, 1.0);

      if (_activeSinks[senderId]?.isEmpty ?? true) {
        _cleanupConnection(senderId);
      }
    }
  }

  void _cleanupConnection(String uid) {
    _peerConnections[uid]?.close();
    _peerConnections.remove(uid);
    _dataChannels[uid]?.close();
    _dataChannels.remove(uid);
    _activeSinks.remove(uid);
  }

  void _sendFrame(RTCDataChannel dc, Map<String, dynamic> jsonHeader, [List<int>? payload]) {
    final jsonStr = jsonEncode(jsonHeader);
    final jsonBytes = utf8.encode(jsonStr);
    
    final lengthBytes = ByteData(4);
    lengthBytes.setUint32(0, jsonBytes.length, Endian.big);
    
    final builder = BytesBuilder(copy: false);
    builder.add(lengthBytes.buffer.asUint8List());
    builder.add(jsonBytes);
    if (payload != null) {
      builder.add(payload);
    }
    
    dc.send(RTCDataChannelMessage.fromBinary(builder.toBytes()));
  }

  @override
  Future<void> sendFile(
    DeviceInfo target,
    String token,
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    final targetUid = target.id;
    final dc = _dataChannels[targetUid];
    if (dc == null) throw StateError('No active WebRTC DataChannel for ${target.name}');

    int waitTime = 0;
    while (dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      await Future.delayed(const Duration(milliseconds: 100));
      waitTime += 100;
      
      if (dc.state == RTCDataChannelState.RTCDataChannelClosed) {
        throw Exception('Data Channel closed prematurely. The receiver may have rejected the transfer or disconnected.');
      }
      
      if (waitTime >= 30000) {
        throw Exception('Connection timeout. The WebRTC P2P connection could not be established (likely due to strict NAT/firewalls blocking STUN).');
      }
    }

    final file = File(filePath);
    final size = await file.length();
    int bytesSent = 0;
    
    final raf = await file.open(mode: FileMode.read);
    const chunkSize = 64 * 1024;
    int lastUpdate = DateTime.now().millisecondsSinceEpoch;
    
    final digestSink = _DigestSink();
    final byteSink = crypto.sha256.startChunkedConversion(digestSink);
    
    while (bytesSent < size) {
      while ((dc.bufferedAmount ?? 0) > 1024 * 1024 * 4) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      final chunk = await raf.read(chunkSize);
      if (chunk.isEmpty) break;
      
      byteSink.add(chunk);
      
      _sendFrame(dc, {
        'type': 'file_chunk',
        'fileId': fileId,
        'offset': bytesSent,
        'payloadLength': chunk.length,
      }, chunk);
      
      bytesSent += chunk.length;
      
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastUpdate > 32 || bytesSent == size) {
        onProgress?.call(bytesSent / size);
        lastUpdate = now;
      }
    }
    
    await raf.close();
    byteSink.close();
    final digest = digestSink.digest;
    
    _sendFrame(dc, {
      'type': 'file_complete',
      'fileId': fileId,
      'checksum': digest?.toString() ?? '',
    });
  }
  
  @override
  Stream<TransferRequest> get incomingRequests => _requestController.stream;
}
