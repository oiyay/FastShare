import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:uuid/uuid.dart';

import 'package:fast_share/core/models/device_info.dart';
import 'package:fast_share/core/models/transfer_request.dart';
import 'package:fast_share/core/models/exceptions.dart';
import 'package:fast_share/core/transport/transport_interface.dart';

class LocalSendTransport implements TransportInterface {
  final _requestController = StreamController<TransferRequest>.broadcast();
  
  // Create an HTTP client that ignores bad certificates since LocalSend uses self-signed HTTPS
  final http.Client _client = _createTrustAllClient();
  
  // Store session mapping: targetId -> sessionId
  final Map<String, String> _sessionIds = {};
  // Store file tokens: targetId -> { fileId: token }
  final Map<String, Map<String, String>> _fileTokens = {};

  static http.Client _createTrustAllClient() {
    final ioClient = HttpClient()
      ..badCertificateCallback = ((X509Certificate cert, String host, int port) => true);
    return IOClient(ioClient);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {
    await _requestController.close();
    _client.close();
  }

  @override
  Stream<DeviceInfo> discoverDevices() {
    // Discovery is already handled by HttpTransport
    return const Stream.empty();
  }

  @override
  Future<void> startAdvertising(DeviceInfo selfInfo) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<TransferResponse> sendTransferRequest(
    DeviceInfo target,
    TransferRequest request, {String? pin,}
  ) async {
    final uri = Uri.parse('https://${target.ip}:${target.port}/api/localsend/v2/prepare-upload${pin != null ? "?pin=$pin" : ""}');
    
    final filesMap = <String, dynamic>{};
    for (final file in request.files) {
      filesMap[file.id] = {
        'id': file.id,
        'fileName': file.name,
        'size': file.size,
        'fileType': '*/*',
        'sha256': '',
        'preview': '',
      };
    }

    final payload = {
      'info': {
        'alias': request.senderName,
        'version': '2.0',
        'deviceModel': Platform.operatingSystem,
        'deviceType': Platform.isAndroid || Platform.isIOS ? 'mobile' : 'desktop',
        'fingerprint': request.senderId,
        'port': 53317,
        'protocol': 'https',
        'download': false,
      },
      'files': filesMap,
    };

    try {
      final response = await _client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 60)); // Long timeout for user to accept

      if (response.statusCode == 200 || response.statusCode == 204) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final sessionId = data['sessionId'] as String;
        final files = data['files'] as Map<String, dynamic>;

        _sessionIds[target.id] = sessionId;
        _fileTokens[target.id] = files.map((k, v) => MapEntry(k, v.toString()));

        return TransferResponse(accepted: true, token: sessionId);
      } else if (response.statusCode == 403) {
        return TransferResponse(accepted: false);
      } else if (response.statusCode == 401) {
        throw PinRequiredException();
      }
      
      throw Exception('LocalSend device returned ${response.statusCode}');
    } catch (e) {
      throw Exception('Failed to connect to LocalSend device: $e');
    }
  }

  @override
  Future<void> sendFile(
    DeviceInfo target,
    String token, // Actually the sessionId
    String fileId,
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    final sessionId = token;
    final fileToken = _fileTokens[target.id]?[fileId];
    
    if (fileToken == null) {
      // LocalSend user might have skipped this specific file
      print('File $fileId was skipped by LocalSend receiver');
      onProgress?.call(1.0);
      return;
    }

    final uri = Uri.parse(
      'https://${target.ip}:${target.port}/api/localsend/v2/upload'
      '?sessionId=$sessionId&fileId=$fileId&token=$fileToken'
    );

    final file = File(filePath);
    final fileSize = await file.length();
    
    final request = http.StreamedRequest('POST', uri);
    request.contentLength = fileSize;
    
    int bytesSent = 0;
    int lastProgressReport = 0;
    
    final progressStream = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          bytesSent += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (onProgress != null && (now - lastProgressReport) >= 100) {
            lastProgressReport = now;
            onProgress(bytesSent / fileSize);
          }
          sink.add(chunk);
        },
      ),
    );

    try {
      final responseFuture = _client.send(request);
      await request.sink.addStream(progressStream);
      request.sink.close();
      onProgress?.call(1.0);

      final response = await responseFuture;
      if (response.statusCode != 200) {
        throw Exception('File upload failed: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error uploading file to LocalSend: $e');
    }
  }

  @override
  Stream<TransferRequest> get incomingRequests => _requestController.stream;

  @override
  Future<void> acceptTransfer(
    TransferRequest request, {String? pin,}
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {}

  @override
  Future<void> rejectTransfer(TransferRequest request) async {}
}
