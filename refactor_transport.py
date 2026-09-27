import re

with open('lib/core/transport/transport_manager.dart', 'r') as f:
    content = f.read()

# 1. We replace `_selectTransport` logic to become `_getTransportRouteOptions`
bad_select = """  TransportInterface _selectTransport(DeviceInfo target) {
    if (target.protocol == 'webrtc') {
      print('[TransportManager] Using WebRTC transport for Global P2P');
      return _webrtcTransport;
    }

    if (target.protocol == 'localsend') {
      print('[TransportManager] Using LocalSend transport');
      return _localSendTransport;
    }

    if (target.protocol == 'fastshare' && target.tcpPort != null) {
      print('[TransportManager] Using FastShare Raw TCP protocol');
      return _tcpTransport;
    }

    // Use Nearby Connections if both devices are Android and Nearby is available
    if (NearbyTransport.isSupported && target.os == 'android') {
      print('[TransportManager] Using Nearby Connections (Android-to-Android)');
      return _nearbyTransport;
    }

    // Default: HTTP transport (fallback)
    print('[TransportManager] Using HTTP transport (fallback)');
    return _httpTransport;
  }"""

good_select = """  List<TransportInterface> _getTransportRouteOptions(DeviceInfo target) {
    final routes = <TransportInterface>[];
    
    // 1. Raw TCP / HTTP (Local Priority)
    if (target.hasLocalRoute) {
      if (target.protocol == 'localsend') {
        routes.add(_localSendTransport);
      } else if (target.tcpPort != null) {
        routes.add(_tcpTransport);
        routes.add(_httpTransport); // fallback for tcp
      } else {
        routes.add(_httpTransport);
      }
    }
    
    // 2. WebRTC (Global Fallback)
    if (target.hasGlobalRoute || target.protocol == 'webrtc') {
      routes.add(_webrtcTransport);
    }
    
    // 3. Fallback to protocol flag if no modern flags are set
    if (routes.isEmpty) {
      if (target.protocol == 'webrtc') routes.add(_webrtcTransport);
      else if (target.protocol == 'localsend') routes.add(_localSendTransport);
      else routes.add(_httpTransport);
    }
    
    return routes;
  }"""
content = content.replace(bad_select, good_select)

# 2. Refactor sendFiles to try routes
bad_send_files = """    // Choose transport
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
        remoteName: target.name,
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

    print('[TransportManager] All files sent successfully!');"""

good_send_files = """    // Choose transports (AirDrop Hybrid Mode)
    final transports = _getTransportRouteOptions(target);
    if (transports.isEmpty) throw Exception('No viable network routes available for ${target.name}');

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

    // Persist to DB before starting
    for (int i = 0; i < filePaths.length; i++) {
      final dbMsg = TransferMessage(
        id: files[i].id,
        senderId: _selfInfo!.id,
        targetId: target.id,
        remoteName: target.name,
        fileName: files[i].name,
        fileSize: files[i].size,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isSentByMe: true,
        status: 'transferring',
      );
      await DatabaseService().saveMessage(dbMsg);
    }

    Exception? lastError;
    
    // Try routes sequentially (LAN -> Global)
    for (final transport in transports) {
      try {
        print('[TransportManager] Attempting handshake via ${transport.runtimeType}...');
        final response = await transport.sendTransferRequest(target, request, pin: pin);

        if (!response.accepted) {
          throw Exception('Transfer rejected by ${target.name}');
        }

        // Handshake success! Send files.
        for (int i = 0; i < filePaths.length; i++) {
          final fileId = files[i].id;
          final fileName = files[i].name;
          
          final fileProgress = (double p) {
            final overallProgress = (i + p) / filePaths.length;
            onProgress?.call(fileName, p, overallProgress);
            TransferStateManager().updateProgress(fileId, p, 'transferring');
          };

          await transport.sendFile(
            target,
            response.token!,
            fileId,
            filePaths[i],
            onProgress: fileProgress,
          );
          
          TransferStateManager().updateProgress(fileId, 1.0, 'completed');
          await DatabaseService().updateMessageStatus(fileId, 'completed');
        }
        
        print('[TransportManager] All files sent successfully via ${transport.runtimeType}!');
        return; // Success, exit the loop!
        
      } catch (e) {
        print('[TransportManager] Route ${transport.runtimeType} failed: $e. Falling back to next route...');
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }

    // If we reach here, ALL routes failed.
    print('[TransportManager] All network routes exhausted. Transfer failed.');
    for (final f in files) {
      TransferStateManager().updateProgress(f.id, 0.0, 'failed');
      await DatabaseService().updateMessageStatus(f.id, 'failed');
    }
    
    throw lastError ?? Exception('Transfer completely failed');"""

content = content.replace(bad_send_files, good_send_files)

# 3. Refactor sendChatText (use hasLocalRoute and hasGlobalRoute)
# First we find the block inside sendChatText
# But actually sendChatText currently looks for target.protocol == 'webrtc'.
# I'll modify the `if (target.protocol == 'webrtc')` block manually in python.
content = content.replace("if (target.protocol == 'webrtc') {", "if (target.hasGlobalRoute && !target.hasLocalRoute) {")
content = content.replace("} else if (target.protocol == 'localsend') {", "} else if (target.protocol == 'localsend' && !target.hasGlobalRoute) {")

with open('lib/core/transport/transport_manager.dart', 'w') as f:
    f.write(content)
