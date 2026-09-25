import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:archive/archive_io.dart';
import 'package:fast_share/core/services/settings_service.dart';

class FilesScreen extends StatefulWidget {
  final String? initialPath;

  const FilesScreen({super.key, this.initialPath});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  late String _currentPath = '';
  List<FileSystemEntity> _items = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initializePath();
  }

  Future<void> _initializePath() async {
    if (widget.initialPath != null) {
      _currentPath = widget.initialPath!;
    } else {
      _currentPath = await SettingsService().getEffectiveSavePath();
    }
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    if (_currentPath.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final dir = Directory(_currentPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final items = await dir.list().toList();
      items.sort((a, b) {
        if (a is Directory && b is File) return -1;
        if (a is File && b is Directory) return 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _openFile(File file) {
    final path = file.path.toLowerCase();
    if (path.endsWith('.zip') || path.endsWith('.apk')) { // APKs are just ZIPs, but maybe just handle ZIPs
      if (path.endsWith('.zip')) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ArchiveViewerScreen(filePath: file.path)),
        );
        return;
      }
    }
    OpenFilex.open(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final canGoBack = widget.initialPath != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(canGoBack ? _currentPath.split(Platform.pathSeparator).last : 'Received Files'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadFiles),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : _items.isEmpty 
          ? const Center(child: Text('No files received yet.'))
          : ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                final isDir = item is Directory;
                final name = item.path.split(Platform.pathSeparator).last;
                final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';

                IconData icon = Icons.insert_drive_file;
                Color color = Colors.grey;

                if (isDir) {
                  icon = Icons.folder;
                  color = Colors.amber;
                } else if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) {
                  icon = Icons.image;
                  color = Colors.blue;
                } else if (['mp4', 'mkv', 'avi'].contains(ext)) {
                  icon = Icons.video_file;
                  color = Colors.purple;
                } else if (ext == 'zip') {
                  icon = Icons.folder_zip;
                  color = Colors.orange;
                }

                return ListTile(
                  leading: Icon(icon, color: color, size: 36),
                  title: Text(name),
                  subtitle: isDir ? null : FutureBuilder<FileStat>(
                    future: item.stat(),
                    builder: (context, snap) {
                      if (!snap.hasData) return const Text('');
                      final size = (snap.data!.size / (1024 * 1024)).toStringAsFixed(2);
                      return Text('$size MB');
                    }
                  ),
                  onTap: () {
                    if (isDir) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => FilesScreen(initialPath: item.path)),
                      );
                    } else {
                      _openFile(item as File);
                    }
                  },
                );
              },
            ),
    );
  }
}

class ArchiveViewerScreen extends StatefulWidget {
  final String filePath;
  const ArchiveViewerScreen({super.key, required this.filePath});

  @override
  State<ArchiveViewerScreen> createState() => _ArchiveViewerScreenState();
}

class _ArchiveViewerScreenState extends State<ArchiveViewerScreen> {
  List<ArchiveFile> _files = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadArchive();
  }

  Future<void> _loadArchive() async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      setState(() {
        _files = archive.files;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.filePath.split(Platform.pathSeparator).last)),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : ListView.builder(
            itemCount: _files.length,
            itemBuilder: (context, index) {
              final file = _files[index];
              return ListTile(
                leading: Icon(file.isFile ? Icons.insert_drive_file : Icons.folder),
                title: Text(file.name),
                subtitle: file.isFile ? Text('${(file.size / 1024).toStringAsFixed(1)} KB') : null,
              );
            },
          ),
    );
  }
}
