// lib/offline_test.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'yolo.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: OfflineTestPage(),
  ));
}

class OfflineTestPage extends StatefulWidget {
  const OfflineTestPage({super.key});

  @override
  State<OfflineTestPage> createState() => _OfflineTestPageState();
}

class _OfflineTestPageState extends State<OfflineTestPage> {
  final YoloService _yolo = YoloService();

  // AssetManifest.json から自動収集
  List<String> _assets = [];

  bool _ready = false;
  String _log = 'モデル準備中...';
  Image? _preview;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // 1) モデル初期化
      await _yolo.loadModel();

      // 2) assets/study/配下の画像パスを全部拾う
      final manifestRaw = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifest = json.decode(manifestRaw);
      final allowedExt = [
        '.jpg',
        '.JPG',
        '.jpeg',
        '.png',
        '.webp',
        '.avif',
      ];

      final all = manifest.keys
          .where((p) =>
              p.startsWith('assets/study/') &&
              allowedExt.any((ext) => p.endsWith(ext)))
          .toList()
        ..sort();

      setState(() {
        _assets = all;
        _ready = true;
        _log = 'モデル準備完了 (${_assets.length}枚)\n${_yolo.modelInfo()}';
      });
    } catch (e) {
      setState(() {
        _ready = false;
        _log = '初期化に失敗: $e';
      });
    }
  }

  Future<void> _runOnAsset(String assetPath) async {
    setState(() {
      // プレビュー（Avif 等で表示できない場合は後でログに出す）
      _preview = Image.asset(assetPath, fit: BoxFit.contain);
      _log = '推論中...';
    });

    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();

      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        setState(() => _log = '画像デコードに失敗: $assetPath');
        return;
      }

      // RGBに詰め直し（← ここが型エラー箇所だったので厳密にintへ）
      final rgb = Uint8List(decoded.width * decoded.height * 3);
      int i = 0;
      for (var y = 0; y < decoded.height; y++) {
        for (var x = 0; x < decoded.width; x++) {
          final p = decoded.getPixel(x, y);
          // p.r/g/b は num の場合があるので 0–255 に clamp して int へ
          rgb[i++] = (p.r as num).clamp(0, 255).toInt();
          rgb[i++] = (p.g as num).clamp(0, 255).toInt();
          rgb[i++] = (p.b as num).clamp(0, 255).toInt();
        }
      }

      final results = _yolo.runFrame(
        rgb,
        decoded.width,
        decoded.height,
        threshold: 0.30, // テストなので少し緩め
      );

      final top = _yolo.lastTop
          .take(5)
          .map((e) => '${e.key}(${e.value.toStringAsFixed(2)})')
          .join(', ');

      setState(() {
        _log = '画像: ${assetPath.split("/").last}\n'
            '検出: ${results.join(", ")}\n'
            '${_yolo.modelInfo()}\n'
            '${_yolo.lastDebugLine}\n'
            'top5: $top';
      });
    } catch (e) {
      setState(() => _log = '推論失敗: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        appBar: AppBar(title: const Text('YOLO Offline Test (macOS)')),
        body: Center(child: Text(_log)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('YOLO Offline Test (macOS)'),
        actions: [
          if (_assets.isNotEmpty)
            IconButton(
              tooltip: 'すべて順番に試す',
              icon: const Icon(Icons.playlist_play),
              onPressed: () async {
                for (final a in _assets) {
                  await _runOnAsset(a);
                  await Future.delayed(const Duration(milliseconds: 400));
                }
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _preview ?? const Text('下の一覧から画像を選んでください'),
            ),
          ),
          const Divider(height: 1),
          // 横スクロールで全画像を出す
          SizedBox(
            height: 160,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _assets.length,
              itemBuilder: (context, idx) {
                final asset = _assets[idx];
                return InkWell(
                  onTap: () => _runOnAsset(asset),
                  child: Container(
                    width: 170,
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Image.asset(
                            asset,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.image_not_supported),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          asset.split('/').last,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _log,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
