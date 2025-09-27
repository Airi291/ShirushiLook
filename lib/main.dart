// lib/main.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

// macOS カメラ（camera_macos ^0.0.9 想定）
import 'package:camera_macos/camera_macos_controller.dart';
import 'package:camera_macos/camera_macos_view.dart';
import 'package:camera_macos/camera_macos.dart' show CameraMacOSMode;

import 'yolo.dart';
import 'dart:math' as math;

/// ====== 表示名・読み上げ文言 ======
const Map<String, String> kJaName = {
  'stop': '一時停止',
  'yield': 'ゆずれ',
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
  'yield': '対向・優先車に道を譲ってください。',
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

/// ====== チューニング用定数 ======
const int kWarmupFrames = 12;
const int kStreakNeed = 2;
const int kClearAfterNoHit = 3;
const double kScoreThreshold = 0.65;

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
    if (Platform.isMacOS) {
      return const _MacCameraPage();
    }
    // macOS以外では簡易メッセージのみ（iOS/Android 実装は今回は省略）
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text(
          'このビルドは macOS 専用です（iOS/Android ページは未同梱）',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}

/// =====================
/// macOS カメラ + YOLO
/// =====================
class _MacCameraPage extends StatefulWidget {
  const _MacCameraPage({super.key});
  @override
  State<_MacCameraPage> createState() => _MacCameraPageState();
}

class _MacCameraPageState extends State<_MacCameraPage> {
  final YoloService _yolo = YoloService();
  final FlutterTts _tts = FlutterTts();

  CameraMacOSController? _ctrl;
  bool _busy = false;

  // 安定化・UI 状態
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

// ARGB→RGBの後に使う：RGBを時計回り90°回転
  Uint8List rotateRgbCW90(Uint8List src, int w, int h) {
    // 出力は (幅=h, 高さ=w) だが画素数は同じなのでサイズは w*h*3 のままでOK
    final out = Uint8List(w * h * 3);
    int di = 0;

    // 目的座標 (x', y') に対し、元座標は (sx, sy) = (y', h - 1 - x')
    for (int yOut = 0; yOut < w; yOut++) {
      // 出力の高さ = w
      for (int xOut = 0; xOut < h; xOut++) {
        // 出力の幅   = h
        final int sx = yOut;
        final int sy = h - 1 - xOut;
        final int si = (sy * w + sx) * 3;
        out[di++] = src[si];
        out[di++] = src[si + 1];
        out[di++] = src[si + 2];
      }
    }
    return out;
  }

  // ARGB8888 -> RGB
  Uint8List _bytesToRgb(Uint8List src, int w, int h, {int? bytesPerRow}) {
    final out = Uint8List(w * h * 3);
    final stride = bytesPerRow ?? (w * 4);

    // 並び推定（数十pixelだけ見て赤チャンネル位置を推測）
    int redBGRA = 0, redARGB = 0;
    final sample = math.min(64, (h * w));
    for (int s = 0; s < sample; s++) {
      final i = (s ~/ w) * stride + (s % w) * 4;
      redBGRA += src[i + 2]; // BGRA の R
      redARGB += src[i + 1]; // ARGB の R
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
        setState(() {
          _hasDetection = false;
          _topLabels = [];
          _bottomLabel = null;
        });
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
          if (v <= 0) {
            _streak.remove(k);
          } else {
            _streak[k] = v;
          }
        }
      }
      _hasDetection = results.isNotEmpty;
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

  @override
  Widget build(BuildContext context) {
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
          // CameraMacOSView：初期化時に controller を受け取り、画像ストリーム開始
          CameraMacOSView(
              key: const ValueKey('macCamera'),
              cameraMode: CameraMacOSMode.video,
              fit: BoxFit.cover,
              onCameraInizialized: (controller) async {
                _ctrl = controller;

                await _ctrl!.startImageStream((imageData) async {
                  // まず imageData 自体の null を弾く
                  final data = imageData;
                  if (_busy || !_yolo.isReady || data == null) return;

                  // ここで全部取り出して null チェック
                  final Uint8List? bytes = data.bytes;
                  final int? w = data.width;
                  final int? h = data.height;
                  // プラグインに bytesPerRow があれば使う（無ければ null でOK）
                  final int? bpr = (data.bytesPerRow is int)
                      ? data.bytesPerRow as int
                      : null;

                  if (bytes == null || w == null || h == null) return;

                  _busy = true;
                  try {
                    final rgb = _bytesToRgb(bytes, w, h, bytesPerRow: bpr);
                    var results =
                        _yolo.runFrame(rgb, w, h, threshold: kScoreThreshold);
                    if (results.isEmpty) {
                      final rgb90 = rotateRgbCW90(rgb, w, h);
                      results = _yolo.runFrame(rgb90, h, w,
                          threshold: kScoreThreshold);
                    }
                    await _processFrame(rgb, w, h);
                    // …FPS計測はそのまま…
                  } finally {
                    _busy = false;
                  }
                });
              }),
          SafeArea(
            child: Stack(
              children: [
                chips,
                bottom,
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    color: Colors.black54,
                    child: Text(
                      _debugInfo,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
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
    // 一部バージョンには dispose() が無いので呼ばない
    _tts.stop();
    super.dispose();
  }
}
