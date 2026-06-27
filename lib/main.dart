import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';

const _imageExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif'};
const _maxSelection = 50;
const _tempDirPrefix = 'extracted_';
const _maxZipSizeBytes = 500 * 1024 * 1024; // 500MB
const _retentionDuration = Duration(hours: 12);

void main() {
  runApp(const ZipToLineApp());
}

class ZipToLineApp extends StatelessWidget {
  const ZipToLineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZIP TO PHOTOLINE',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.green)),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late StreamSubscription _intentSub;
  List<File> _images = [];
  bool _isExtracting = false;
  int _extractDone = 0;
  int _extractTotal = 0;
  String? _error;
  bool _isSharing = false;

  // ลำดับรูปที่ถูกเลือก (เก็บ index ตามลำดับที่แตะ เพื่อโชว์เลขลำดับเหมือนแอปไลน์)
  final List<int> _selectedOrder = [];

  @override
  void initState() {
    super.initState();
    _cleanupOldTempDirs();

    // ไฟล์ที่ถูกแชร์มาตอนแอปกำลังรันอยู่
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) => _handleSharedFiles(files),
      onError: (err) => setState(() => _error = 'รับไฟล์ผิดพลาด: $err'),
    );

    // ไฟล์ที่ถูกแชร์มาตอนเปิดแอปครั้งแรก (cold start)
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _handleSharedFiles(files);
    });
  }

  @override
  void dispose() {
    _intentSub.cancel();
    super.dispose();
  }

  // ลบโฟลเดอร์รูปที่แตกไว้เกิน 12 ชั่วโมง ส่วนที่ยังไม่ครบเวลาจะเก็บไว้ต่อ
  Future<void> _cleanupOldTempDirs() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final entries = tempDir.listSync();
      final now = DateTime.now();
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final dirName = entry.path.split(Platform.pathSeparator).last;
        if (!dirName.startsWith(_tempDirPrefix)) continue;

        final timestampStr = dirName.substring(_tempDirPrefix.length);
        final createdAtMs = int.tryParse(timestampStr);
        final isExpired = createdAtMs == null ||
            now.difference(DateTime.fromMillisecondsSinceEpoch(createdAtMs)) > _retentionDuration;
        if (isExpired) {
          await entry.delete(recursive: true);
        }
      }
    } catch (_) {
      // ไม่ใช่ปัญหาร้ายแรงถ้าลบไม่สำเร็จ ปล่อยให้ระบบเคลียร์ temp เองในที่สุด
    }
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    final zipFile = files.firstWhere(
      (f) => f.path.toLowerCase().endsWith('.zip'),
      orElse: () => files.isNotEmpty ? files.first : SharedMediaFile(path: '', type: SharedMediaType.file),
    );
    if (zipFile.path.isEmpty) return;

    await _extractZip(zipFile.path);
    ReceiveSharingIntent.instance.reset();
  }

  Future<void> _extractZip(String zipPath) async {
    await _cleanupOldTempDirs();

    setState(() {
      _isExtracting = true;
      _error = null;
      _extractDone = 0;
      _extractTotal = 0;
      _selectedOrder.clear();
    });

    try {
      final zipFile = File(zipPath);
      final zipSize = await zipFile.length();
      if (zipSize > _maxZipSizeBytes) {
        if (!mounted) return;
        setState(() {
          _isExtracting = false;
          _error = 'ไฟล์ ZIP ใหญ่เกินไป (${(zipSize / (1024 * 1024)).toStringAsFixed(0)}MB) '
              'รองรับสูงสุด ${_maxZipSizeBytes ~/ (1024 * 1024)}MB';
        });
        return;
      }

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final imageEntries = archive.files
          .where((e) => e.isFile && _imageExtensions.contains(_extensionOf(e.name)))
          .toList();

      final tempDir = await getTemporaryDirectory();
      final outDir = Directory('${tempDir.path}/$_tempDirPrefix${DateTime.now().millisecondsSinceEpoch}');
      await outDir.create(recursive: true);

      if (!mounted) return;
      setState(() => _extractTotal = imageEntries.length);

      final extractedImages = <File>[];
      for (final entry in imageEntries) {
        final outFile = File('${outDir.path}/${_safeFileName(entry.name)}');
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(entry.content as List<int>);
        extractedImages.add(outFile);
        if (!mounted) return;
        setState(() => _extractDone = extractedImages.length);
      }

      if (!mounted) return;
      setState(() {
        _images = extractedImages;
        _isExtracting = false;
        if (extractedImages.isEmpty) {
          _error = 'ไม่พบไฟล์รูปภาพใน ZIP นี้';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isExtracting = false;
        _error = 'แตกไฟล์ ZIP ไม่สำเร็จ: $e';
      });
    }
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot == -1) return '';
    return name.substring(dot).toLowerCase();
  }

  String _safeFileName(String name) {
    final base = name.split('/').last;
    return '${DateTime.now().microsecondsSinceEpoch}_$base';
  }

  void _toggleSelect(int index) {
    setState(() {
      if (_selectedOrder.contains(index)) {
        _selectedOrder.remove(index);
      } else {
        if (_selectedOrder.length >= _maxSelection) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('เลือกได้สูงสุด $_maxSelection รูปต่อครั้ง')),
          );
          return;
        }
        _selectedOrder.add(index);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedOrder.clear());
  }

  void _selectAllUpToLimit() {
    setState(() {
      for (var i = 0; i < _images.length; i++) {
        if (_selectedOrder.length >= _maxSelection) break;
        if (!_selectedOrder.contains(i)) _selectedOrder.add(i);
      }
      if (_selectedOrder.length >= _maxSelection && _images.length > _maxSelection) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('เลือกได้สูงสุด $_maxSelection รูปต่อครั้ง')),
        );
      }
    });
  }

  Future<void> _shareSelected() async {
    if (_selectedOrder.isEmpty || _isSharing) return;
    setState(() => _isSharing = true);
    try {
      final files = _selectedOrder.map((i) => XFile(_images[i].path)).toList();
      await SharePlus.instance.share(ShareParams(files: files));
      _clearSelection();
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  void _openViewer(int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ImageViewerPage(images: _images, initialIndex: initialIndex),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selectedOrder.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: hasSelection
            ? IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection)
            : null,
        title: Text(
          hasSelection ? 'เลือก ${_selectedOrder.length}/$_maxSelection รูป' : 'ZIP TO PHOTOLINE',
        ),
        actions: [
          if (_images.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: 'เลือกทั้งหมด (สูงสุด $_maxSelection)',
              onPressed: _selectAllUpToLimit,
            ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: hasSelection
          ? FloatingActionButton.extended(
              onPressed: _isSharing ? null : _shareSelected,
              icon: _isSharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.share),
              label: Text(_isSharing ? 'กำลังเตรียมไฟล์...' : 'แชร์ ${_selectedOrder.length} รูป'),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_isExtracting) {
      final progress = _extractTotal == 0 ? null : _extractDone / _extractTotal;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 200,
                child: LinearProgressIndicator(value: progress),
              ),
              const SizedBox(height: 12),
              Text(
                _extractTotal == 0 ? 'กำลังอ่านไฟล์ ZIP...' : 'กำลังแตกไฟล์... $_extractDone/$_extractTotal',
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_images.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'ยังไม่มีรูปภาพ\n\nแชร์ไฟล์ ZIP มาที่แอปนี้จากแอปอื่น (เช่น ไฟล์ใน LINE หรือไดรฟ์) แล้วรูปภาพในไฟล์จะถูกแตกออกมาให้ที่นี่\n\nแตะรูปเพื่อเลือก กดค้างเพื่อดูรูปขยาย',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) {
        final image = _images[index];
        final selectedPos = _selectedOrder.indexOf(index);
        final isSelected = selectedPos != -1;
        return GestureDetector(
          onTap: () => _toggleSelect(index),
          onLongPress: () => _openViewer(index),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(image, fit: BoxFit.cover),
              if (isSelected)
                Container(color: Colors.black.withValues(alpha: 0.35)),
              Positioned(
                right: 6,
                top: 6,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: isSelected ? Colors.green : Colors.white70,
                  child: isSelected
                      ? Text(
                          '${selectedPos + 1}',
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        )
                      : const Icon(Icons.circle_outlined, size: 16, color: Colors.black54),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({required this.images, required this.initialIndex});

  final List<File> images;
  final int initialIndex;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  late final PageController _controller;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_currentIndex + 1} / ${widget.images.length}'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.images.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            child: Center(child: Image.file(widget.images[index])),
          );
        },
      ),
    );
  }
}
