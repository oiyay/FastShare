import re

with open('lib/core/transport/transport_manager.dart', 'r') as f:
    content = f.read()

send_files_replacement = """  Future<void> sendFiles(
    DeviceInfo target,
    List<String> filePaths, {
    void Function(String fileName, double fileProgress, double overallProgress)? onProgress,
    String? pin,
  }) async {
    if (_selfInfo == null) throw StateError('TransportManager not initialized');
    
    // Choose transport
    final transport = _selectTransport(target);

    // Build transfer request
    final files = <FileMetadata>[];
    for (final path in filePaths) {
      final file = File(path);
      final stat = await file.stat();
      files.add(FileMetadata(
        id: Uuid().v4(),
        name: file.uri.pathSegments.last,
        size: stat.size,
      ));
    }

    final request = TransferRequest(
      senderName: _selfInfo!.name,
      senderId: _selfInfo!.id,
      files: files,
    );

    // Send request (handshake)
    print('[TransportManager] Sending transfer request to ${target.name}...');
    final response = await transport.sendTransferRequest(target, request, pin: pin);

    if (!response.accepted) {
      throw Exception('Transfer rejected by ${target.name}');
    }

    // Send each file
    for (int i = 0; i < filePaths.length; i++) {
      final fileName = files[i].name;
      final fileId = files[i].id;
      final fileSize = files[i].size;
      
      final dbMsg = TransferMessage(
        id: fileId,
        senderId: _selfInfo!.id,
        targetId: target.id,
        fileName: fileName,
        fileSize: fileSize,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isSentByMe: true,
        status: 'transferring',
      );
      await DatabaseService().saveMessage(dbMsg);

      final fileProgress = (double p) {
        final overallProgress = (i + p) / filePaths.length;
        onProgress?.call(fileName, p, overallProgress);
        TransferStateManager().updateProgress(fileId, p, 'transferring');
      };

      try {
        await transport.sendFile(
          target,
          response.token!,
          fileId,
          filePaths[i],
          onProgress: fileProgress,
        );
        TransferStateManager().updateProgress(fileId, 1.0, 'completed');
        await DatabaseService().updateMessageStatus(fileId, 'completed');
      } catch (e) {
        TransferStateManager().updateProgress(fileId, 0.0, 'failed');
        await DatabaseService().updateMessageStatus(fileId, 'failed');
        rethrow;
      }
    }

    print('[TransportManager] All files sent successfully!');
  }

  /// Accept an incoming transfer request.
  Future<void> acceptTransfer(
    TransferRequest request,
    String savePath, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    for (final file in request.files) {
      final dbMsg = TransferMessage(
        id: file.id,
        senderId: request.senderId,
        targetId: _selfInfo!.id,
        fileName: file.name,
        fileSize: file.size,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isSentByMe: false,
        status: 'transferring',
      );
      await DatabaseService().saveMessage(dbMsg);
    }

    final wrappedProgress = (String fileName, double progress) {
      onProgress?.call(fileName, progress);
      final fileId = request.files.firstWhere((f) => f.name == fileName, orElse: () => FileMetadata(id: '', name: '', size: 0)).id;
      if (fileId.isNotEmpty) {
        TransferStateManager().updateProgress(fileId, progress, progress >= 1.0 ? 'completed' : 'transferring');
        if (progress >= 1.0) {
          DatabaseService().updateMessageStatus(fileId, 'completed');
        }
      }
    };

    // Try all transports safely
    try { await _tcpTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    try { await _httpTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    try { await _webrtcTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    if (NearbyTransport.isSupported) {
      try { await _nearbyTransport.acceptTransfer(request, savePath, onProgress: wrappedProgress); } catch (_) {}
    }
  }

  /// Reject an incoming transfer request."""

pattern = r"  Future<void> sendFiles\(.*?\n  /// Reject an incoming transfer request\."
content = re.sub(pattern, send_files_replacement, content, flags=re.DOTALL)

with open('lib/core/transport/transport_manager.dart', 'w') as f:
    f.write(content)
