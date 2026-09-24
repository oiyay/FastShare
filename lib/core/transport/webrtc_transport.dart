import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:uuid/uuid.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/models/exceptions.dart';
import 'package:fast_share/core/transport/transport_interface.dart';
import 'package:fast_share/core/services/signaling_service.dart';

class _DigestSink implements EventSink<crypto.Digest> {
  crypto.Digest? digest;
  @override void add(crypto.Digest event) => digest = event;
  @override void addError(Object error, [StackTrace? stackTrace]) {}
  @override void close() {}
}

class WebRtcTransport implements TransportInterface {
  final _requestController = StreamController<TransferRequest>.broadcast();
  final SignalingService _signaling = SignalingService();

  // Active PeerConnections and DataChannels mapped by target UID
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCDataChannel> _dataChannels = {};

  // Receive tracking maps (same as TCP transport)
  final Map<String, Map<String, IOSink>> _activeSinks = {};
  final Map<String, Map<String, int>> _expectedSizes = {};
  final Map<String, Map<String, int>> _bytesReceived = {};
  final Map<String, Map<String, String>> _fileNames = {};
  final Map<String, Map<String, String>> _filePaths = {};
  final Map<String, int> _lastUpdateTimes = {};
  final Map<String, void Function(String, double)> _progressCallbacks = {};

  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ]
  };

  @override
  Future<void> initialize() async {
    _signaling.incomingCalls.listen(_handleIncomingCall);
  }

  @override
  Future<void> dispose() async {
    _requestController.close();
    for (final pc in _peerConnections.values) {
      await pc.close();
    }
    _peerConnections.clear();
    _dataChannels.clear();
  }

  @override
  Stream<DeviceInfo> discoverDevices() => const Stream.empty(); // Handled by GlobalShareScreen

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {}

  @override
  Future<void> stopAdvertising() async {}

  void _setupPeerConnectionListeners(RTCPeerConnection pc, String targetUid, bool isCaller, String roomId, String dbTargetUid) {
    pc.onIceCandidate = (candidate) {
      _signaling.addIceCandidate(dbTargetUid, roomId, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }, isCaller);
    };

    pc.onIceConnectionState = (state) {
      print('[WebRTC] ICE State: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _cleanupConnection(targetUid);
      }
    };
  }

  void _cleanupConnection(String targetUid) {
    _peerConnections[targetUid]?.close();
    _peerConnections.remove(targetUid);
    _dataChannels.remove(targetUid);
    _activeSinks[targetUid]?.values.forEach((sink) => sink.close());
    _activeSinks.remove(targetUid);
    _expectedSizes.remove(targetUid);
    _bytesReceived.remove(targetUid);
    _fileNames.remove(targetUid);
    _filePaths.remove(targetUid);
    _progressCallbacks.remove(targetUid);
    _lastUpdateTimes.remove(targetUid);
  }

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request, {
    String? pin,
  }) async {
    final targetUid = target.id;
    final roomId = const Uuid().v4();

    final pc = await createPeerConnection(_iceServers);
    _peerConnections[targetUid] = pc;

    // Create Data Channel FIRST before creating Offer
    final dcInit = RTCDataChannelInit()..maxRetransmits = 30; // SCTP reliability
    final dc = await pc.createDataChannel('fastshare_data', dcInit);
    _dataChannels[targetUid] = dc;
    _setupDataChannel(dc, targetUid);

    _setupPeerConnectionListeners(pc, targetUid, true, roomId, targetUid);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // Convert request to JSON
    final requestJson = {
      'senderId': request.senderId,
      'senderName': request.senderName,
      'files': request.files.map((f) => {
        'id': f.id,
        'name': f.name,
        'size': f.size,
      }).toList(),
    };

    // Send Offer via Firebase
    await _signaling.sendOffer(
      targetUid,
      roomId,
      {'type': offer.type, 'sdp': offer.sdp},
      requestJson,
    );

    // Listen for Answer
    final answerCompleter = Completer<bool>();
    StreamSubscription? answerSub;
    answerSub = _signaling.listenToAnswer(targetUid, roomId).listen((event) async {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null && data['type'] != null) {
        if (!answerCompleter.isCompleted) {
          await pc.setRemoteDescription(RTCSessionDescription(data['sdp'], data['type']));
          answerCompleter.complete(true);
        }
      }
    });

    // Listen for receiver's ICE candidates
    StreamSubscription? iceSub;
    iceSub = _signaling.listenToIceCandidates(targetUid, roomId, true).listen((event) async {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        await pc.addCandidate(RTCIceCandidate(
          data['candidate'],
          data['sdpMid'],
          data['sdpMLineIndex'],
        ));
      }
    });

    try {
      await answerCompleter.future.timeout(const Duration(seconds: 60));
    } catch (e) {
      _cleanupConnection(targetUid);
      answerSub.cancel();
      iceSub.cancel();
      await _signaling.endCall(targetUid, roomId);
      throw Exception('Target did not answer in time (Timeout).');
    }

    // Clean up signaling after a delay so ICE candidates finish trickling
    Future.delayed(const Duration(seconds: 10), () {
      answerSub?.cancel();
      iceSub?.cancel();
      _signaling.endCall(targetUid, roomId);
    });

    return TransferResponse(accepted: true, token: roomId);
  }

  void _handleIncomingCall(DatabaseEvent event) async {
    final data = event.snapshot.value as Map<dynamic, dynamic>?;
    final roomId = event.snapshot.key;
    if (data == null || roomId == null) return;

    final callerUid = data['caller_uid'].toString();
    final callerUsername = data['caller_username'].toString();
    final offerData = data['offer'];
    final reqData = data['transfer_request'];

    if (offerData == null || reqData == null) return;

    final files = (reqData['files'] as List).map((f) => FileMetadata(
      id: f['id'].toString(),
      name: f['name'].toString(),
      size: int.parse(f['size'].toString()),
    )).toList();

    final request = TransferRequest(
      senderName: reqData['senderName'].toString(),
      senderId: callerUid,
      files: files,
    );

    // Auto-accepting for simplicity in WebRTC for now, or we route it to UI
    // To match TCP flow, we must emit it to _requestController
    
    // BUT we need to store the SDP offer and roomId so acceptTransfer can use them!
    // We can inject roomId into token temporarily!
    final reqWithToken = TransferRequest(
      senderName: request.senderName,
      senderId: request.senderId,
      files: request.files,
    );
    
    // Store signaling context temporarily in a private map
    _pendingIncomingCalls[callerUid] = {
      'roomId': roomId,
      'offer': offerData,
    };

    _requestController.add(reqWithToken);
  }

  final Map<String, Map<String, dynamic>> _pendingIncomingCalls = {};

  @override
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    final callerUid = request.senderId;
    final callData = _pendingIncomingCalls[callerUid];
    if (callData == null) return;

    final roomId = callData['roomId'];
    final offerData = callData['offer'];

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

    _setupPeerConnectionListeners(pc, callerUid, false, roomId, _signaling.uid!);

    await pc.setRemoteDescription(RTCSessionDescription(offerData['sdp'], offerData['type']));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    await _signaling.sendAnswer(_signaling.uid!, roomId, {
      'type': answer.type,
      'sdp': answer.sdp,
    });

    _signaling.listenToIceCandidates(_signaling.uid!, roomId, false).listen((event) async {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        await pc.addCandidate(RTCIceCandidate(
          data['candidate'],
          data['sdpMid'],
          data['sdpMLineIndex'],
        ));
      }
    });

    _pendingIncomingCalls.remove(callerUid);
  }

  @override
  Future<void> rejectTransfer(TransferRequest request) async {
    final callerUid = request.senderId;
    final callData = _pendingIncomingCalls[callerUid];
    if (callData != null) {
      final roomId = callData['roomId'];
      await _signaling.endCall(_signaling.uid!, roomId);
      _pendingIncomingCalls.remove(callerUid);
    }
  }

  void _setupDataChannel(RTCDataChannel dc, String targetUid) {
    dc.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary) {
        // Binary Data Channel message decoding
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

    // Wait until data channel is open
    while (dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (dc.state == RTCDataChannelState.RTCDataChannelClosed) {
        throw Exception('Data Channel closed prematurely');
      }
    }

    final file = File(filePath);
    final size = await file.length();
    int bytesSent = 0;
    
    final raf = await file.open(mode: FileMode.read);
    const chunkSize = 64 * 1024; // 64KB for WebRTC stability (max msg size is often 256KB or 16MB depending on SCTP stack, but 64KB is universally safe)
    int lastUpdate = DateTime.now().millisecondsSinceEpoch;
    
    final digestSink = _DigestSink();
    final byteSink = crypto.sha256.startChunkedConversion(digestSink);
    
    while (bytesSent < size) {
      // PRODUCTION IMPROVEMENT: Handle SCTP Backpressure!
      // If the buffer gets too large, wait for it to drain to avoid Out Of Memory.
      while ((dc.bufferedAmount ?? 0) > 1024 * 1024 * 4) { // Pause if > 4MB buffered
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
