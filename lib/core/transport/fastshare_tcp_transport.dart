import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/transport/transport_interface.dart';

class FastShareTcpTransport implements TransportInterface {
  final _deviceController = StreamController<DeviceInfo>.broadcast();
  final _requestController = StreamController<TransferRequest>.broadcast();
  
  ServerSocket? _serverSocket;
  int get tcpPort => _serverSocket?.port ?? 0;
  
  // Connections where we are the RECEIVER
  final Map<String, Socket> _incomingSockets = {};
  // Track open file sinks for incoming transfers: senderId -> { fileId -> IOSink }
  final Map<String, Map<String, IOSink>> _activeSinks = {};
  // Track progress callbacks: senderId -> callback
  final Map<String, void Function(String fileName, double progress)> _progressCallbacks = {};
  // Track file sizes: senderId -> { fileId -> size }
  final Map<String, Map<String, int>> _expectedSizes = {};
  // Track bytes received: senderId -> { fileId -> bytes }
  final Map<String, Map<String, int>> _bytesReceived = {};
  // Track filenames: senderId -> { fileId -> name }
  final Map<String, Map<String, String>> _fileNames = {};
  // Track active file paths: senderId -> { fileId -> path }
  final Map<String, Map<String, String>> _filePaths = {};

  // Connections where we are the SENDER
  final Map<String, Socket> _outgoingSockets = {};
  final Map<String, Completer<TransferResponse>> _outgoingHandshakes = {};

  @override
  Future<void> initialize() async {
    _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    print('[TcpTransport] Listening on port $tcpPort');
    
    _serverSocket!.listen(_handleNewConnection);
  }

  @override
  Future<void> dispose() async {
    await _serverSocket?.close();
    for (final socket in _incomingSockets.values) {
      socket.destroy();
    }
    for (final socket in _outgoingSockets.values) {
      socket.destroy();
    }
    _incomingSockets.clear();
    _outgoingSockets.clear();
    await _deviceController.close();
    await _requestController.close();
  }

  @override
  Stream<DeviceInfo> discoverDevices() => const Stream.empty();

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {}

  @override
  Future<void> stopAdvertising() async {}

  void _sendFrame(Socket socket, Map<String, dynamic> header, [List<int>? payload]) {
    final headerJson = jsonEncode(header);
    final headerBytes = utf8.encode(headerJson);
    
    final lengthBytes = ByteData(4);
    lengthBytes.setUint32(0, headerBytes.length, Endian.big);
    
    socket.add(lengthBytes.buffer.asUint8List());
    socket.add(headerBytes);
    
    if (payload != null && payload.isNotEmpty) {
      socket.add(payload);
    }
  }

  Stream<Map<String, dynamic>> _readFrames(Socket socket) async* {
    var builder = BytesBuilder(copy: false);
    
    await for (final chunk in socket) {
      builder.add(chunk);
      
      while (builder.length >= 4) {
        final buffer = builder.toBytes();
        final lengthBytes = ByteData.sublistView(buffer, 0, 4);
        final headerLength = lengthBytes.getUint32(0, Endian.big);
        
        if (buffer.length >= 4 + headerLength) {
          final headerBytes = buffer.sublist(4, 4 + headerLength);
          final headerJson = utf8.decode(headerBytes);
          final header = jsonDecode(headerJson) as Map<String, dynamic>;
          
          final payloadLength = header['payloadLength'] as int? ?? 0;
          final totalFrameLength = 4 + headerLength + payloadLength;
          
          if (buffer.length >= totalFrameLength) {
            final payload = buffer.sublist(4 + headerLength, totalFrameLength);
            header['_payload'] = payload;
            
            yield header;
            
            // Keep only the remaining bytes
            final remaining = buffer.sublist(totalFrameLength);
            builder = BytesBuilder(copy: false)..add(remaining);
          } else {
            break;
          }
        } else {
          break;
        }
      }
    }
  }

  void _handleNewConnection(Socket socket) {
    String? currentSenderId;

    _readFrames(socket).listen((frame) {
      final type = frame['type'];

      if (type == 'handshake_request') {
        final request = TransferRequest.fromJson(frame);
        currentSenderId = request.senderId;
        _incomingSockets[request.senderId] = socket;
        
        // Initialize tracking maps
        _activeSinks[request.senderId] = {};
        _expectedSizes[request.senderId] = {};
        _bytesReceived[request.senderId] = {};
        _fileNames[request.senderId] = {};
        _filePaths[request.senderId] = {};
        for (final f in request.files) {
          _expectedSizes[request.senderId]![f.id] = f.size;
          _bytesReceived[request.senderId]![f.id] = 0;
          _fileNames[request.senderId]![f.id] = f.name;
        }

        _requestController.add(request);
      } else if (type == 'file_chunk') {
        if (currentSenderId == null) return;
        final fileId = frame['fileId'] as String;
        final payload = frame['_payload'] as List<int>;
        
        final sink = _activeSinks[currentSenderId]?[fileId];
        if (sink != null) {
          sink.add(payload);
          
          final received = (_bytesReceived[currentSenderId]![fileId] ?? 0) + payload.length;
          _bytesReceived[currentSenderId]![fileId] = received;
          
          final size = _expectedSizes[currentSenderId]![fileId] ?? 1;
          final name = _fileNames[currentSenderId]![fileId] ?? fileId;
          
          _progressCallbacks[currentSenderId]?.call(name, received / size);
        }
      } else if (type == 'file_complete') {
        if (currentSenderId == null) return;
        final fileId = frame['fileId'] as String;
        final expectedChecksum = frame['checksum'] as String?;
        
        _activeSinks[currentSenderId]?[fileId]?.close();
        _activeSinks[currentSenderId]?.remove(fileId);
        
        final name = _fileNames[currentSenderId]![fileId] ?? fileId;
        final path = _filePaths[currentSenderId]?[fileId];
        
        if (path != null && expectedChecksum != null) {
          // Verify checksum
          final file = File(path);
          if (file.existsSync()) {
            file.openRead().transform(crypto.sha256).single.then((digest) {
              if (digest.toString() == expectedChecksum) {
                print('[TcpTransport] File $name verified successfully!');
              } else {
                print('[TcpTransport] Checksum mismatch for $name!');
                // Wait, if it fails, we could delete it or alert.
                // For now, just print it.
              }
            });
          }
        }
      } else if (type == 'cancel') {
        if (currentSenderId != null) {
          _activeSinks[currentSenderId]?.values.forEach((sink) => sink.close());
          _activeSinks.remove(currentSenderId);
        }
      }

    }, onDone: () {
      if (currentSenderId != null) {
        _incomingSockets.remove(currentSenderId);
        _activeSinks[currentSenderId]?.values.forEach((sink) => sink.close());
        _activeSinks.remove(currentSenderId);
        _expectedSizes.remove(currentSenderId);
        _bytesReceived.remove(currentSenderId);
        _fileNames.remove(currentSenderId);
        _filePaths.remove(currentSenderId);
        _progressCallbacks.remove(currentSenderId);
      }
    });
  }

  @override
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request, {
    String? pin,
  }) async {
    if (target.tcpPort == null) {
      throw UnsupportedError('Target does not support FastShare TCP protocol');
    }

    final socket = await Socket.connect(target.ip, target.tcpPort!);
    _outgoingSockets[target.id] = socket;
    
    final completer = Completer<TransferResponse>();
    _outgoingHandshakes[target.id] = completer;

    _readFrames(socket).listen((frame) {
      if (frame['type'] == 'handshake_response') {
        if (!completer.isCompleted) {
          completer.complete(TransferResponse(
            accepted: frame['accepted'],
            token: frame['sessionId'],
          ));
        }
      } else if (frame['type'] == 'cancel') {
        if (!completer.isCompleted) {
          completer.complete(TransferResponse(accepted: false));
        }
      }
    }, onDone: () {
      if (!completer.isCompleted) {
        completer.complete(TransferResponse(accepted: false));
      }
      _outgoingSockets.remove(target.id);
    });

    final reqJson = request.toJson();
    reqJson['type'] = 'handshake_request';
    _sendFrame(socket, reqJson);

    return completer.future;
  }

  @override
  Future<void> sendFile(
    DeviceInfo target,
    String token,
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    final socket = _outgoingSockets[target.id];
    if (socket == null) throw StateError('No active TCP connection for ${target.name}');

    final file = File(filePath);
    final size = await file.length();
    int bytesSent = 0;
    
    // Lazy import of crypto since we added it to pubspec
    final digest = await file.openRead().transform(crypto.sha256).single;
    
    await for (final chunk in file.openRead()) {
      _sendFrame(socket, {
        'type': 'file_chunk',
        'fileId': fileId,
        'offset': bytesSent,
        'payloadLength': chunk.length,
      }, chunk);
      
      bytesSent += chunk.length;
      onProgress?.call(bytesSent / size);
    }
    
    _sendFrame(socket, {
      'type': 'file_complete',
      'fileId': fileId,
      'checksum': digest.toString(),
    });
  }

  @override
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    final socket = _incomingSockets[request.senderId];
    if (socket == null) throw StateError('No active TCP connection');

    if (onProgress != null) {
      _progressCallbacks[request.senderId] = onProgress;
    }

    // Prepare files
    for (final f in request.files) {
      final path = '$savePath/${f.name}';
      final file = File(path);
      await file.parent.create(recursive: true);
      _activeSinks[request.senderId]![f.id] = file.openWrite();
      _filePaths[request.senderId]![f.id] = path;
    }

    final sessionId = const Uuid().v4();
    _sendFrame(socket, {
      'type': 'handshake_response',
      'accepted': true,
      'sessionId': sessionId,
    });
  }

  @override
  Future<void> rejectTransfer(TransferRequest request) async {
    final socket = _incomingSockets[request.senderId];
    if (socket != null) {
      _sendFrame(socket, {
        'type': 'handshake_response',
        'accepted': false,
      });
      socket.destroy();
      _incomingSockets.remove(request.senderId);
    }
  }
}
