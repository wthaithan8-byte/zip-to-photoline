import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'purchase_service.dart';

const _privacyPolicyUrl = 'https://wthaithan8-byte.github.io/zip-to-photoline/docs/privacy.html';
const _termsOfUseUrl = 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';

const _imageShareChannel = MethodChannel('zipphoto/share');

const _imageExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif'};
const _tempDirPrefix = 'extracted_';
const _retentionDuration = Duration(hours: 12);

const _freeMaxSelection = 10;
const _premiumMaxSelection = 50;
const _freeMaxZipSizeMB = 50;
const _premiumMaxZipSizeMB = 500;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PurchaseService.instance.init();
  runApp(const ZipToLineApp());
}

class ZipToLineApp extends StatelessWidget {
  const ZipToLineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZipPhoto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
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
  StreamSubscription<bool>? _purchaseSub;
  late final AppLifecycleListener _lifecycleListener;
  List<File> _images = [];
  bool _isExtracting = false;
  int _extractDone = 0;
  int _extractTotal = 0;
  String? _error;
  bool _isSharing = false;
  final List<int> _selectedOrder = [];
  final Set<int> _sharedIndices = {};
  final _shareButtonKey = GlobalKey();

  int _gridColumns = 3;
  final Map<int, Offset> _pinchPointers = {};
  double? _pinchBaseDistance;

  bool get _isPremium => PurchaseService.instance.isPremium;
  int get _maxSelection => _isPremium ? _premiumMaxSelection : _freeMaxSelection;
  int get _maxZipSizeMB => _isPremium ? _premiumMaxZipSizeMB : _freeMaxZipSizeMB;
  int get _maxZipSizeBytes => _maxZipSizeMB * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _cleanupOldTempDirs();

    _purchaseSub = PurchaseService.instance.stream.listen((_) => setState(() {}));
    _lifecycleListener = AppLifecycleListener(
      onResume: () => PurchaseService.instance.refreshEntitlement(),
    );

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) => _handleSharedFiles(files),
      onError: (err) => setState(() => _error = 'รับไฟล์ผิดพลาด: $err'),
    );

    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _handleSharedFiles(files);
    });
  }

  @override
  void dispose() {
    _intentSub.cancel();
    _purchaseSub?.cancel();
    _lifecycleListener.dispose();
    super.dispose();
  }

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
        if (isExpired) await entry.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    // The initial-media call and the stream can both deliver the same cold-start share.
    if (files.isEmpty || _isExtracting) return;
    ReceiveSharingIntent.instance.reset();
    final zipFile = files.where((f) => _extensionOf(f.path) == '.zip').firstOrNull;
    if (zipFile != null) {
      await _extractZip(zipFile.path);
      return;
    }
    final imagePaths =
        files.map((f) => f.path).where((p) => _imageExtensions.contains(_extensionOf(p))).toList();
    await _importImages(imagePaths);
  }

  // Like extraction, a new share replaces whatever is currently in the grid.
  void _startLoading() {
    setState(() {
      _isExtracting = true;
      _images = [];
      _error = null;
      _extractDone = 0;
      _extractTotal = 0;
      _selectedOrder.clear();
      _sharedIndices.clear();
    });
  }

  Future<Directory> _createOutDir() async {
    final tempDir = await getTemporaryDirectory();
    final outDir = Directory('${tempDir.path}/$_tempDirPrefix${DateTime.now().millisecondsSinceEpoch}');
    return outDir.create(recursive: true);
  }

  // Loose photos (already unzipped elsewhere) are copied out of the share inbox so
  // they expire with the same temp-dir cleanup as extracted ones.
  Future<void> _importImages(List<String> paths) async {
    _startLoading();
    if (paths.isEmpty) {
      setState(() {
        _isExtracting = false;
        _error = 'ไม่พบไฟล์ที่ใช้ได้\nแชร์ไฟล์ ZIP หรือรูปภาพ (JPG, PNG, HEIC ฯลฯ) มาที่แอปนี้';
      });
      return;
    }
    setState(() => _extractTotal = paths.length);

    try {
      await _cleanupOldTempDirs();
      final outDir = await _createOutDir();
      final importedImages = <File>[];
      for (final path in paths) {
        importedImages.add(await File(path).copy('${outDir.path}/${_safeFileName(path)}'));
        if (!mounted) return;
        setState(() => _extractDone = importedImages.length);
      }

      if (!mounted) return;
      setState(() {
        _images = importedImages;
        _isExtracting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isExtracting = false;
        _error = 'นำเข้ารูปภาพไม่สำเร็จ: $e';
      });
    }
  }

  Future<void> _extractZip(String zipPath) async {
    _startLoading();

    InputFileStream? input;
    try {
      await _cleanupOldTempDirs();
      final zipFile = File(zipPath);
      final zipSize = await zipFile.length();
      if (zipSize > _maxZipSizeBytes) {
        if (!mounted) return;
        setState(() {
          _isExtracting = false;
          _error = 'ไฟล์ ZIP ใหญ่เกินไป (${(zipSize / (1024 * 1024)).toStringAsFixed(0)}MB)\n'
              '${_isPremium ? 'Premium' : 'เวอร์ชันฟรี'}รองรับสูงสุด ${_maxZipSizeMB}MB';
        });
        if (!_isPremium && mounted) _showUpgradeDialog();
        return;
      }

      // Stream from disk: reading a 500MB ZIP into memory gets the app killed on iPhone.
      input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(input);
      final imageEntries = archive.files
          .where((e) => e.isFile && _imageExtensions.contains(_extensionOf(e.name)))
          .toList();

      final outDir = await _createOutDir();

      if (!mounted) return;
      setState(() => _extractTotal = imageEntries.length);

      final extractedImages = <File>[];
      for (final entry in imageEntries) {
        final outPath = '${outDir.path}/${_safeFileName(entry.name)}';
        final output = OutputFileStream(outPath);
        entry.writeContent(output);
        await output.close();
        extractedImages.add(File(outPath));
        if (!mounted) return;
        setState(() => _extractDone = extractedImages.length);
        await Future<void>.delayed(Duration.zero);
      }

      if (!mounted) return;
      setState(() {
        _images = extractedImages;
        _isExtracting = false;
        if (extractedImages.isEmpty) _error = 'ไม่พบไฟล์รูปภาพใน ZIP นี้';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isExtracting = false;
        _error = 'แตกไฟล์ ZIP ไม่สำเร็จ: $e';
      });
    } finally {
      await input?.close();
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

  // Selection is unlimited so photos can be deleted in bulk; only sharing is capped.
  void _toggleSelect(int index) {
    setState(() {
      if (!_selectedOrder.remove(index)) _selectedOrder.add(index);
    });
  }

  void _clearSelection() => setState(() => _selectedOrder.clear());

  void _showShareLimitNotice() {
    if (!_isPremium) {
      _showUpgradeDialog();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('แชร์ได้สูงสุด $_maxSelection รูปต่อครั้ง')),
      );
    }
  }

  void _selectAllUpToLimit() {
    setState(() {
      for (var i = 0; i < _images.length; i++) {
        if (_selectedOrder.length >= _maxSelection) break;
        if (!_selectedOrder.contains(i)) _selectedOrder.add(i);
      }
    });
    if (_selectedOrder.length >= _maxSelection && _images.length > _maxSelection) _showShareLimitNotice();
  }

  Future<void> _shareSelected() async {
    if (_selectedOrder.isEmpty || _isSharing) return;
    if (_selectedOrder.length > _maxSelection) {
      _showShareLimitNotice();
      return;
    }
    setState(() => _isSharing = true);
    try {
      final paths = _selectedOrder.map((i) => _images[i].path).toList();
      final origin = _sharePositionOrigin();
      final bool completed;
      if (Platform.isIOS) {
        completed = await _imageShareChannel.invokeMethod<bool>('shareImages', {
              'paths': paths,
              'x': origin.left,
              'y': origin.top,
              'w': origin.width,
              'h': origin.height,
            }) ??
            false;
      } else {
        final result = await SharePlus.instance.share(ShareParams(
          files: paths.map(XFile.new).toList(),
          sharePositionOrigin: origin,
        ));
        completed = result.status != ShareResultStatus.dismissed;
      }
      // Keep the selection if the user backed out of the share sheet.
      if (!completed || !mounted) return;
      setState(() => _sharedIndices.addAll(_selectedOrder));
      _clearSelection();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('แชร์ไม่สำเร็จ: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  // iPad presents the share sheet as a popover and requires a non-empty anchor rect.
  Rect _sharePositionOrigin() {
    final box = _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.of(context).size;
    return Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1);
  }

  // Pinch is tracked with a raw Listener so it never competes with the grid's
  // scroll or the tiles' tap/long-press in the gesture arena.
  void _onGridPointerDown(PointerDownEvent e) {
    _pinchPointers[e.pointer] = e.position;
    if (_pinchPointers.length == 2) {
      setState(() => _pinchBaseDistance = _pinchDistance());
    }
  }

  void _onGridPointerMove(PointerMoveEvent e) {
    if (!_pinchPointers.containsKey(e.pointer)) return;
    _pinchPointers[e.pointer] = e.position;
    final base = _pinchBaseDistance;
    if (_pinchPointers.length != 2 || base == null || base == 0) return;
    final ratio = _pinchDistance() / base;
    if (ratio < 1.25 && ratio > 0.8) return;
    _pinchBaseDistance = _pinchDistance();
    final next = (_gridColumns + (ratio > 1 ? -1 : 1)).clamp(1, _maxGridColumns());
    if (next != _gridColumns) {
      HapticFeedback.selectionClick();
      setState(() => _gridColumns = next);
    }
  }

  void _onGridPointerEnd(PointerEvent e) {
    _pinchPointers.remove(e.pointer);
    if (_pinchPointers.length < 2 && _pinchBaseDistance != null) {
      setState(() => _pinchBaseDistance = null);
    }
  }

  double _pinchDistance() {
    final p = _pinchPointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  int _maxGridColumns() => (MediaQuery.of(context).size.width / 70).floor().clamp(3, 10);

  void _openViewer(int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ImageViewerPage(
          images: _images,
          initialIndex: initialIndex,
          onDelete: (file) => _removeImages({file.path}),
        ),
      ),
    );
  }

  void _removeImages(Set<String> paths) {
    final oldToNew = <int, int>{};
    final kept = <File>[];
    for (var i = 0; i < _images.length; i++) {
      if (paths.contains(_images[i].path)) continue;
      oldToNew[i] = kept.length;
      kept.add(_images[i]);
    }
    setState(() {
      _images = kept;
      final remappedSelection = _selectedOrder.where(oldToNew.containsKey).map((i) => oldToNew[i]!).toList();
      _selectedOrder
        ..clear()
        ..addAll(remappedSelection);
      final remappedShared = _sharedIndices.where(oldToNew.containsKey).map((i) => oldToNew[i]!).toSet();
      _sharedIndices
        ..clear()
        ..addAll(remappedShared);
    });
    for (final p in paths) {
      File(p).delete().catchError((_) => File(p));
    }
  }

  Future<void> _deleteSelected() async {
    final count = _selectedOrder.length;
    if (count == 0 || !await _confirmDelete(context, 'ลบ $count รูปที่เลือก?')) return;
    _removeImages(_selectedOrder.map((i) => _images[i].path).toSet());
  }

  Future<void> _deleteAll() async {
    if (_images.isEmpty || !await _confirmDelete(context, 'ลบรูปทั้งหมด ${_images.length} รูป?')) return;
    _removeImages(_images.map((f) => f.path).toSet());
  }

  void _showUpgradeDialog() {
    final sub = PurchaseService.instance.stream.listen((isPremium) {
      if (isPremium && context.mounted) Navigator.of(context).pop();
    });
    showDialog(
      context: context,
      builder: (ctx) {
        String? buyingType;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final monthlyPrice = PurchaseService.instance.monthlyPrice;
            final yearlyPrice = PurchaseService.instance.yearlyPrice;
            return AlertDialog(
              title: const Text('ปลดล็อก Premium'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('เวอร์ชันฟรี:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('• ZIP สูงสุด $_freeMaxZipSizeMB MB'),
                    const Text('• แชร์รูปได้ $_freeMaxSelection รูป/ครั้ง'),
                    const SizedBox(height: 12),
                    const Text('Premium:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('• ZIP สูงสุด $_premiumMaxZipSizeMB MB'),
                    const Text('• แชร์รูปได้ $_premiumMaxSelection รูป/ครั้ง'),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: buyingType != null ? null : () async {
                          setDialogState(() => buyingType = 'yearly');
                          try {
                            await PurchaseService.instance.buyYearly();
                          } catch (e) {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('ไม่สามารถซื้อได้: $e')),
                              );
                            }
                          } finally {
                            if (ctx.mounted) setDialogState(() => buyingType = null);
                          }
                        },
                        child: buyingType == 'yearly'
                            ? const SizedBox(width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Text('Premium รายปี - ${yearlyPrice ?? '฿699'}/ปี'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: buyingType != null ? null : () async {
                          setDialogState(() => buyingType = 'monthly');
                          try {
                            await PurchaseService.instance.buyMonthly();
                          } catch (e) {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(content: Text('ไม่สามารถซื้อได้: $e')),
                              );
                            }
                          } finally {
                            if (ctx.mounted) setDialogState(() => buyingType = null);
                          }
                        },
                        child: buyingType == 'monthly'
                            ? const SizedBox(width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : Text('Premium รายเดือน - ${monthlyPrice ?? '฿149'}/เดือน'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'การสมัครสมาชิกจะต่ออายุอัตโนมัติและเรียกเก็บเงินจากบัญชี Apple ID '
                      'เว้นแต่ยกเลิกอย่างน้อย 24 ชั่วโมงก่อนสิ้นสุดรอบปัจจุบัน '
                      'จัดการหรือยกเลิกได้ที่ Settings > Apple ID > Subscriptions',
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                    if (Platform.isIOS)
                      Center(
                        child: TextButton.icon(
                          onPressed: buyingType != null ? null : () async {
                            try {
                              await PurchaseService.instance.redeemCode();
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(content: Text('เปิดหน้าใส่โค้ดไม่ได้: $e')),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.local_offer_outlined, size: 18),
                          label: const Text('ใช้โค้ดส่วนลด'),
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => launchUrl(Uri.parse(_privacyPolicyUrl),
                              mode: LaunchMode.externalApplication),
                          child: const Text('นโยบายความเป็นส่วนตัว',
                              style: TextStyle(fontSize: 11)),
                        ),
                        const Text('|', style: TextStyle(fontSize: 11)),
                        TextButton(
                          onPressed: () => launchUrl(Uri.parse(_termsOfUseUrl),
                              mode: LaunchMode.externalApplication),
                          child: const Text('เงื่อนไขการใช้งาน',
                              style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: buyingType != null ? null : () => Navigator.pop(ctx),
                  child: const Text('ยกเลิก'),
                ),
                TextButton(
                  onPressed: buyingType != null ? null : () async {
                    Navigator.pop(ctx);
                    await PurchaseService.instance.restore();
                  },
                  child: const Text('กู้คืนการซื้อ'),
                ),
              ],
            );
          },
        );
      },
    ).then((_) => sub.cancel());
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selectedOrder.isNotEmpty;
    final overShareLimit = _selectedOrder.length > _maxSelection;
    return Scaffold(
      appBar: AppBar(
        leading: hasSelection
            ? IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection)
            : null,
        title: Text(
          !hasSelection
              ? 'ZipPhoto'
              : overShareLimit
                  ? 'เลือก ${_selectedOrder.length} รูป'
                  : 'เลือก ${_selectedOrder.length}/$_maxSelection รูป',
        ),
        actions: [
          if (_isPremium)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.workspace_premium, color: Colors.amber),
            )
          else
            IconButton(
              icon: const Icon(Icons.workspace_premium),
              tooltip: 'อัปเกรด Premium',
              onPressed: _showUpgradeDialog,
            ),
          if (_images.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: 'เลือกทั้งหมด (สูงสุด $_maxSelection)',
              onPressed: _selectAllUpToLimit,
            ),
          if (hasSelection)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'ลบรูปที่เลือก',
              onPressed: _deleteSelected,
            )
          else if (_images.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'ลบรูปทั้งหมด',
              onPressed: _deleteAll,
            ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: hasSelection
          ? FloatingActionButton.extended(
              key: _shareButtonKey,
              onPressed: _isSharing ? null : _shareSelected,
              backgroundColor: overShareLimit ? Colors.grey : null,
              icon: _isSharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.share),
              label: Text(_isSharing
                  ? 'กำลังเตรียมไฟล์...'
                  : overShareLimit
                      ? 'แชร์ได้สูงสุด $_maxSelection รูป'
                      : 'แชร์ ${_selectedOrder.length} รูป'),
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
              SizedBox(width: 200, child: LinearProgressIndicator(value: progress)),
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'ยังไม่มีรูปภาพ\n\nแชร์ไฟล์ ZIP มาที่แอปนี้จากแอปอื่น แล้วรูปภาพในไฟล์จะถูกแตกออกมาให้ที่นี่ (แชร์รูปภาพมาตรงๆ ก็ได้)\n\nแตะรูปเพื่อเลือก กดค้างเพื่อดูรูปขยาย',
                textAlign: TextAlign.center,
              ),
              if (!_isPremium) ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _showUpgradeDialog,
                  icon: const Icon(Icons.workspace_premium),
                  label: const Text('อัปเกรด Premium'),
                ),
                const SizedBox(height: 4),
                Text(
                  'ฟรี: ZIP ${_freeMaxZipSizeMB}MB / ${_freeMaxSelection}รูป',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      );
    }
    final columns = _gridColumns.clamp(1, _maxGridColumns());
    final spacing = columns > 4 ? 3.0 : 8.0;
    final compact = columns > 4;
    // Decode thumbnails at tile size; full-resolution decodes of dozens of photos exhaust memory.
    final mq = MediaQuery.of(context);
    final thumbPx = (mq.size.width / columns * mq.devicePixelRatio).ceil();
    return Listener(
      onPointerDown: _onGridPointerDown,
      onPointerMove: _onGridPointerMove,
      onPointerUp: _onGridPointerEnd,
      onPointerCancel: _onGridPointerEnd,
      child: GridView.builder(
      physics: _pinchBaseDistance != null ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(spacing, spacing, spacing, 88),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) {
        final image = _images[index];
        final selectedPos = _selectedOrder.indexOf(index);
        final isSelected = selectedPos != -1;
        final wasShared = _sharedIndices.contains(index);
        return GestureDetector(
          onTap: () => _toggleSelect(index),
          onLongPress: () => _openViewer(index),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(image, fit: BoxFit.cover, cacheWidth: thumbPx),
              if (isSelected) Container(color: Colors.black.withValues(alpha: 0.35)),
              Positioned(
                right: compact ? 3 : 6,
                top: compact ? 3 : 6,
                child: CircleAvatar(
                  radius: compact ? 9 : 12,
                  backgroundColor: isSelected ? Colors.deepPurple : Colors.white70,
                  child: isSelected
                      ? Text(
                          '${selectedPos + 1}',
                          style: TextStyle(
                              color: Colors.white, fontSize: compact ? 10 : 12, fontWeight: FontWeight.bold),
                        )
                      : Icon(Icons.circle_outlined, size: compact ? 12 : 16, color: Colors.black54),
                ),
              ),
              if (wasShared && !isSelected)
                Positioned(
                  left: compact ? 3 : 6,
                  bottom: compact ? 3 : 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check, size: 12, color: Colors.white),
                        if (!compact) ...const [
                          SizedBox(width: 2),
                          Text('แชร์แล้ว', style: TextStyle(color: Colors.white, fontSize: 10)),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      ),
    );
  }
}

Future<bool> _confirmDelete(BuildContext context, String title) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: const Text('ลบออกจากแอปเท่านั้น ไฟล์ต้นฉบับไม่หาย'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ยกเลิก')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('ลบ'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({required this.images, required this.initialIndex, required this.onDelete});

  final List<File> images;
  final int initialIndex;
  final void Function(File file) onDelete;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  late final PageController _controller;
  late int _currentIndex;
  late final List<File> _images = List.of(widget.images);

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  Future<void> _deleteCurrent() async {
    if (!await _confirmDelete(context, 'ลบรูปนี้?')) return;
    final file = _images[_currentIndex];
    widget.onDelete(file);
    if (!mounted) return;
    if (_images.length == 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _images.removeAt(_currentIndex);
      if (_currentIndex >= _images.length) _currentIndex = _images.length - 1;
    });
    _controller.jumpToPage(_currentIndex);
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
        title: Text('${_currentIndex + 1} / ${_images.length}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'ลบรูปนี้',
            onPressed: _deleteCurrent,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _images.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            child: Center(child: Image.file(_images[index], key: ValueKey(_images[index].path))),
          );
        },
      ),
    );
  }
}
