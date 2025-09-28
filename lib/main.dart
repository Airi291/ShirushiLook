// lib/main.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:camera_macos/camera_macos_controller.dart';
import 'package:camera_macos/camera_macos_view.dart';
import 'package:camera_macos/camera_macos.dart' show CameraMacOSMode;

import 'yolo.dart';

const Map<String, String> kJaName = {
  'stop': '一時停止',
  'yield': '一時停止',
  'no_entry': '進入禁止',
  'speed_limit': '速度制限',
  'pedestrian_crossing': '横断歩道',
  'school_zone': 'スクールゾーン',
  'railroad_crossing': '踏切あり',
  'merge': '合流注意',
  'animal_crossing': '動物注意',
  'keep_side': '指定方向外進行禁止',
  'no_stopping_parking': '停車・駐車禁止',
  'one_way': '一方通行',
  'no_turn': '右左折禁止',
  'roundabout': '環状交差点',
  'curve': 'カーブ注意',
  'bump': '路面隆起',
  'height_limit': '高さ制限',
  'hgv_restriction': '大型車通行規制',
  'priority_road': '優先道路',
  'no_overtaking': '追越し禁止',
  'parking': '駐車可',
};

const Map<String, String> kMeaning = {
  'stop': 'ここで必ず一時停止してください。',
  'yield': 'ここで必ず一時停止してください。',
  'no_entry': 'この先は進入できません。',
  'speed_limit': '標識の制限速度を守ってください。',
  'pedestrian_crossing': '横断歩道。歩行者に十分注意。',
  'school_zone': 'スクールゾーン。徐行し子どもに注意。',
  'railroad_crossing': '踏切あり。減速して安全確認。',
  'merge': '合流注意。ミラーと周囲を確認。',
  'animal_crossing': '動物注意。速度を落として警戒。',
  'keep_side': '指定方向外への進行は禁止です。',
  'no_stopping_parking': 'ここでは停車・駐車できません。',
  'one_way': '一方通行。逆走に注意。',
  'no_turn': '右左折禁止です。',
  'roundabout': '環状交差点。進入前に確認。',
  'curve': '急カーブ注意。減速してください。',
  'bump': '路面隆起。徐行してください。',
  'height_limit': '高さ制限あり。通行前に確認。',
  'hgv_restriction': '大型車の通行が規制されています。',
  'priority_road': '優先道路です。交差側に注意を促してください。',
  'no_overtaking': '追越し禁止。前車に続行。',
  'parking': '駐車できます。周囲安全を確認。',
};

const int kWarmupFrames = 8; // ウォームアップを少し短縮
const int kStreakNeed = 2;
const int kClearAfterNoHit = 3;
const double kScoreThreshold = 0.65;

// ★ 推論を間引く（ms）
const int kInferEveryMs = 120; // 約8fps程度で推論（プレビューは常時）

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _Entry(),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({super.key});
  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS) return const _MacCameraPage();
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child:
            Text('このビルドは macOS 専用です', style: TextStyle(color: Colors.white70)),
      ),
    );
  }
}

class _MacCameraPage extends StatefulWidget {
  const _MacCameraPage({super.key});
  @override
  State<_MacCameraPage> createState() => _MacCameraPageState();
}

class _MacCameraPageState extends State<_MacCameraPage> {
  final YoloService _yolo = YoloService();
  final FlutterTts _tts = FlutterTts();

  CameraMacOSController? _ctrl;

  // 推論のスロットリング
  bool _inferBusy = false;
  DateTime _lastInferAt = DateTime.fromMillisecondsSinceEpoch(0);

  // 安定化・UI
  int _warmupLeft = kWarmupFrames;
  int _noHitFrames = 0;
  final Map<String, int> _streak = {};
  bool _hasDetection = false;
  List<String> _topLabels = [];
  String? _bottomLabel;

  // TTS
  bool _speaking = false;
  final List<String> _queue = [];
  String? _lastSpoken;
  DateTime _lastSpeakTime = DateTime.fromMillisecondsSinceEpoch(0);

  // fps/HUD
  double _fps = 0;
  int _framesSeen = 0, _framesSeenLast = 0;
  DateTime _lastFpsAt = DateTime.now();
  String _debugInfo = 'YOLO init…';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _tts.setLanguage("ja-JP");
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _yolo.loadModel();
    setState(() => _debugInfo = _yolo.modelInfo());
  }

  // ARGB8888 -> RGB（bytesPerRow対応）: 低コスト・コピーのみ
  Uint8List _bytesToRgb(Uint8List src, int w, int h, {int? bytesPerRow}) {
    final out = Uint8List(w * h * 3);
    final stride = bytesPerRow ?? (w * 4);

    // 並び推定（軽く）
    int redBGRA = 0, redARGB = 0;
    final sample = math.min(64, (h * w));
    for (int s = 0; s < sample; s++) {
      final i = (s ~/ w) * stride + (s % w) * 4;
      redBGRA += src[i + 2];
      redARGB += src[i + 1];
    }
    final isBGRA = redBGRA >= redARGB;

    int j = 0;
    for (int y = 0; y < h; y++) {
      final row = y * stride;
      for (int x = 0; x < w; x++) {
        final i = row + x * 4;
        if (isBGRA) {
          final b = src[i + 0], g = src[i + 1], r = src[i + 2];
          out[j++] = r;
          out[j++] = g;
          out[j++] = b;
        } else {
          final r = src[i + 1], g = src[i + 2], b = src[i + 3];
          out[j++] = r;
          out[j++] = g;
          out[j++] = b;
        }
      }
    }
    return out;
  }

  Future<void> _processFrame(Uint8List rgbBytes, int width, int height) async {
    if (_warmupLeft > 0) {
      _warmupLeft--;
      if (_warmupLeft == 0) {
        setState(() {
          _topLabels = [];
          _bottomLabel = null;
          _hasDetection = false;
        });
      }
      return;
    }

    final results =
        _yolo.runFrame(rgbBytes, width, height, threshold: kScoreThreshold);

    final top3 = _yolo.lastTop
        .where((e) => e.value >= kScoreThreshold)
        .take(3)
        .map((e) => e.key)
        .toList();

    String? stable;
    if (results.isEmpty) {
      _noHitFrames++;
      _streak.updateAll((_, v) => v > 0 ? v - 1 : 0);
      if (_noHitFrames >= kClearAfterNoHit) {
        _hasDetection = false;
        _topLabels = [];
        _bottomLabel = null;
      }
    } else {
      _noHitFrames = 0;
      for (final k in results) {
        _streak[k] = (_streak[k] ?? 0) + 1;
        if (_streak[k]! >= kStreakNeed) stable = k;
      }
      for (final k in _streak.keys.toList()) {
        if (!results.contains(k)) {
          final v = _streak[k]! - 1;
          if (v <= 0)
            _streak.remove(k);
          else
            _streak[k] = v;
        }
      }
      _hasDetection = true;
    }

    if (!mounted) return;
    setState(() {
      _topLabels = top3;
      if (stable != null) _bottomLabel = stable;
      _debugInfo = 'fps=${_fps.toStringAsFixed(1)} | ${_yolo.modelInfo()}\n'
          '${_yolo.lastDebugLine}';
    });

    if (stable != null) {
      final text = kMeaning[stable];
      if (text != null) {
        final now = DateTime.now();
        final same = stable == _lastSpoken;
        final cool = now.difference(_lastSpeakTime).inSeconds >= 2;
        if (!same || cool) {
          _lastSpoken = stable;
          _lastSpeakTime = now;
          _enqueue(text);
        }
      }
    }
  }

  void _enqueue(String text) {
    _queue.add(text);
    if (!_speaking) _dequeue();
  }

  Future<void> _dequeue() async {
    if (_queue.isEmpty) return;
    _speaking = true;
    final text = _queue.removeAt(0);
    try {
      await _tts.stop();
      await _tts.speak(text);
      _tts.setCompletionHandler(() {
        if (mounted) setState(() => _bottomLabel = null);
        _speaking = false;
        _dequeue();
      });
    } catch (_) {
      _speaking = false;
    }
  }

  void _updateFps(DateTime now) {
    _framesSeen++;
    final ms = now.difference(_lastFpsAt).inMilliseconds;
    if (ms >= 1000) {
      setState(() {
        _fps = (_framesSeen - _framesSeenLast) / (ms / 1000.0);
        _framesSeenLast = _framesSeen;
        _lastFpsAt = now;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const bool kShowDebugHud = false; // 右上のラベルを出すか
    const bool kShowChips = true; // 上部の検出チップを出すか
    final chips = _hasDetection && _topLabels.isNotEmpty
        ? Positioned(
            top: 12,
            left: 24,
            right: 24,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: _topLabels
                  .map((k) => Chip(label: Text(kJaName[k] ?? k)))
                  .toList(),
            ),
          )
        : const SizedBox.shrink();

    final bottom = _bottomLabel != null
        ? Positioned(
            left: 24,
            right: 24,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                      blurRadius: 6,
                      color: Colors.black26,
                      offset: Offset(0, 2))
                ],
              ),
              child: Text(
                kMeaning[_bottomLabel!] ?? _bottomLabel!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.red),
              ),
            ),
          )
        : const SizedBox.shrink();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraMacOSView(
            key: const ValueKey('macCamera'),
            cameraMode: CameraMacOSMode.video,
            fit: BoxFit.cover,
            onCameraInizialized: (controller) async {
              _ctrl = controller;

              await _ctrl!.startImageStream((imageData) async {
                // プレビューは常時描画 → fpsだけ更新
                final now = DateTime.now();
                _updateFps(now);

                // 推論のスロットリング：最新フレームのみ処理
                if (_inferBusy ||
                    now.difference(_lastInferAt).inMilliseconds <
                        kInferEveryMs ||
                    !_yolo.isReady ||
                    imageData == null) {
                  return;
                }
                _inferBusy = true;
                _lastInferAt = now;

                try {
                  final Uint8List? bytes = imageData.bytes;
                  final int? w = imageData.width;
                  final int? h = imageData.height;
                  final int? bpr = (imageData.bytesPerRow is int)
                      ? imageData.bytesPerRow as int
                      : null;
                  if (bytes == null || w == null || h == null) return;

                  final rgb = _bytesToRgb(bytes, w, h, bytesPerRow: bpr);
                  await _processFrame(rgb, w, h);
                } finally {
                  _inferBusy = false;
                }
              });
            },
          ), // 上部の検出チップを出すか
          SafeArea(
            child: Stack(
              children: [
                // 検出チップ
                if (kShowChips) chips,

                // 下のガイダンス
                bottom,

                // 右上のデバッグHUD
                if (kShowDebugHud)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      color: Colors.black54,
                      child: Text(
                        _debugInfo,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ctrl?.stopImageStream();
    _tts.stop();
    super.dispose();
  }
}
