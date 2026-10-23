import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'purchase_service.dart';

const _privacyPolicyUrl = 'https://wthaithan8-byte.github.io/zip-to-photoline/docs/privacy.html';
const _termsOfUseUrl = 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';

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
      _sharedIndices.clear();
    });

    try {
      final zipFile = File(zipPath);
      final zipSize = await zipFile.length();
      if (zipSize > _maxZipSizeBytes) {
        if (!mounted) return;
        setState(() {
          _isExtracting = false;
          _error = 'ไฟล์ ZIP ใหญ่เกินไป (${(zipSize / (1024 * 1024)).toStringAsFixed(0)}MB)\n'
              'เวอร์ชันฟรีรองรับสูงสุด ${_maxZipSizeMB}MB';
        });
        if (!_isPremium && mounted) _showUpgradeDialog();
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
        if (extractedImages.isEmpty) _error = 'ไม่พบไฟล์รูปภาพใน ZIP นี้';
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
          if (!_isPremium) {
            _showUpgradeDialog();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('เลือกได้สูงสุด $_maxSelection รูปต่อครั้ง')),
            );
          }
          return;
        }
        _selectedOrder.add(index);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedOrder.clear());

  void _selectAllUpToLimit() {
    setState(() {
      for (var i = 0; i < _images.length; i++) {
        if (_selectedOrder.length >= _maxSelection) break;
        if (!_selectedOrder.contains(i)) _selectedOrder.add(i);
      }
      if (_selectedOrder.length >= _maxSelection && _images.length > _maxSelection) {
        if (!_isPremium) {
          _showUpgradeDialog();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('เลือกได้สูงสุด $_maxSelection รูปต่อครั้ง')),
          );
        }
      }
    });
  }

  Future<void> _shareSelected() async {
    if (_selectedOrder.isEmpty || _isSharing) return;
    setState(() => _isSharing = true);
    try {
      final files = _selectedOrder.map((i) => XFile(_images[i].path)).toList();
      await SharePlus.instance.share(ShareParams(
        files: files,
        sharePositionOrigin: _sharePositionOrigin(),
      ));
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

  void _openViewer(int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ImageViewerPage(images: _images, initialIndex: initialIndex),
      ),
    );
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
                    const Text('• เลือกรูปได้ $_freeMaxSelection รูป/ครั้ง'),
                    const SizedBox(height: 12),
                    const Text('Premium:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('• ZIP สูงสุด $_premiumMaxZipSizeMB MB'),
                    const Text('• เลือกรูปได้ $_premiumMaxSelection รูป/ครั้ง'),
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
    return Scaffold(
      appBar: AppBar(
        leading: hasSelection
            ? IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection)
            : null,
        title: Text(
          hasSelection
              ? 'เลือก ${_selectedOrder.length}/$_maxSelection รูป'
              : 'ZipPhoto',
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
        ],
      ),
      body: _buildBody(),
      floatingActionButton: hasSelection
          ? FloatingActionButton.extended(
              key: _shareButtonKey,
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
                'ยังไม่มีรูปภาพ\n\nแชร์ไฟล์ ZIP มาที่แอปนี้จากแอปอื่น แล้วรูปภาพในไฟล์จะถูกแตกออกมาให้ที่นี่\n\nแตะรูปเพื่อเลือก กดค้างเพื่อดูรูปขยาย',
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
        final wasShared = _sharedIndices.contains(index);
        return GestureDetector(
          onTap: () => _toggleSelect(index),
          onLongPress: () => _openViewer(index),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(image, fit: BoxFit.cover),
              if (isSelected) Container(color: Colors.black.withValues(alpha: 0.35)),
              Positioned(
                right: 6,
                top: 6,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: isSelected ? Colors.deepPurple : Colors.white70,
                  child: isSelected
                      ? Text(
                          '${selectedPos + 1}',
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        )
                      : const Icon(Icons.circle_outlined, size: 16, color: Colors.black54),
                ),
              ),
              if (wasShared && !isSelected)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check, size: 12, color: Colors.white),
                        SizedBox(width: 2),
                        Text('แชร์แล้ว', style: TextStyle(color: Colors.white, fontSize: 10)),
                      ],
                    ),
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
