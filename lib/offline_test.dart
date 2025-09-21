// lib/offline_test.dart
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
  final List<String> _assets = [
    'assets/study/stop.jpg',
    'assets/study/speed_limit.jpg',
    'assets/study/yield.webp',
    'assets/study/no_entry.jpeg',
    'assets/study/pedestrian_crossing.jpeg',
    // 必要に応じて追加
  ];

  bool _ready = false;
  String _log = 'モデル準備中...';
  Image? _preview;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _yolo.loadModel();
    setState(() {
      _ready = true;
      _log = 'モデル準備完了';
    });
  }

  Future<void> _runOnAsset(String assetPath) async {
    setState(() {
      _preview = Image.asset(assetPath);
      _log = '推論中...';
    });

    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      setState(() => _log = 'デコード失敗');
      return;
    }

    final rgb = Uint8List(decoded.width * decoded.height * 3);
    int i = 0;
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        final p = decoded.getPixel(x, y);
        final r = (p.r as num).clamp(0, 255).toInt();
        final g = (p.g as num).clamp(0, 255).toInt();
        final b = (p.b as num).clamp(0, 255).toInt();
        rgb[i++] = r;
        rgb[i++] = g;
        rgb[i++] = b;
      }
    }

    final results =
        _yolo.runFrame(rgb, decoded.width, decoded.height, threshold: 0.30);

    setState(() {
      _log = '検出: ${results.join(", ")}\n${_yolo.modelInfo()}';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('YOLO Offline Test')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _preview ?? const Text('画像を選んでください'),
            ),
          ),
          const Divider(),
          SizedBox(
            height: 140,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _assets.length,
              itemBuilder: (context, idx) {
                final asset = _assets[idx];
                return InkWell(
                  onTap: () => _runOnAsset(asset),
                  child: Container(
                    width: 120,
                    margin: const EdgeInsets.all(8),
                    color: Colors.black12,
                    child: Center(
                      child: Text(
                        asset.split('/').last,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_log),
          ),
        ],
      ),
    );
  }
}
