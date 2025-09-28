import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:camera_macos/camera_macos.dart' show CameraMacOSMode;
import 'package:camera_macos/camera_macos_controller.dart';
import 'package:camera_macos/camera_macos_view.dart';

import 'background_video.dart';
import 'demo_yolo.dart';

/// ====== 表示名・読み上げ文言 ======
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

/// ====== チューニング用定数 ======
const int kWarmupFrames = 8;
const int kClearAfterNoHit = 3;
const double kScoreThreshold = 0.65;

/// 初期推論間隔（以後は実測で自動調整）
const int kInferEveryMsInit = 120; // ~8fps 推論

/// UI トグル
const bool kShowDebugHud = false; // 右上の詳細HUD
const bool kShowChips = true; // 上部の検出チップ

/// ★ デモモード：true で assets/move.mp4 を背景再生し、そのフレームで推論
const bool kUseDemoVideo = true;

/// ★ 動画フレーム toImage の倍率（解像度↑ほど重い。0.8〜1.25 あたり推奨）
const double kVideoGrabPixelRatio = 1.0;

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
    // デモ動画は全プラットフォームで可
    if (kUseDemoVideo) return const _MacCameraPage();
    // それ以外はこのサンプルでは macOS 用
    return const _MacCameraPage();
  }
}

/// ====== 赤枠オーバーレイ ======
class _BoxPainter extends CustomPainter {
  final List<YoloDetection> dets;
  final Size srcSize; // 元フレームサイズ
  _BoxPainter(this.dets, this.srcSize);

  @override
  void paint(Canvas canvas, Size size) {
    final scale =
        math.max(size.width / srcSize.width, size.height / srcSize.height);
    final dx = (size.width - srcSize.width * scale) / 2.0;
    final dy = (size.height - srcSize.height * scale) / 2.0;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFFF3B30);
    final fill = Paint()..color = const Color(0xAA000000);

    for (final d in dets) {
      final r = Rect.fromLTWH(
        dx + d.rect.left * scale,
        dy + d.rect.top * scale,
        d.rect.width * scale,
        d.rect.height * scale,
      );
      canvas.drawRect(r, stroke);

      final tp = TextPainter(
        text: TextSpan(
          text:
              '${kJaName[d.label] ?? d.label} ${(d.score * 100).toStringAsFixed(0)}%',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final topY =
          (r.top - tp.height - 2).clamp(0, size.height - tp.height).toDouble();
      final bg = Rect.fromLTWH(r.left, topY, tp.width + 6, tp.height + 2);
      canvas.drawRect(bg, fill);
      tp.paint(canvas, Offset(bg.left + 3, bg.top + 1));
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) =>
      old.dets != dets || old.srcSize != srcSize;
}

/// =====================
/// カメラ or デモ動画 + YOLO
/// =====================
class _MacCameraPage extends StatefulWidget {
  const _MacCameraPage({super.key});
  @override
  State<_MacCameraPage> createState() => _MacCameraPageState();
}

class _MacCameraPageState extends State<_MacCameraPage> {
  final YoloService _yolo = YoloService();
  final FlutterTts _tts = FlutterTts();

  // カメラ
  CameraMacOSController? _ctrl;

  // デモ動画
  final GlobalKey _videoKey = GlobalKey();
  bool _videoReady = false;
  bool _grabbing = false; // 動画フレーム取得中
  Timer? _grabTimer;

  // 推論スロットリング（動的）
  bool _inferBusy = false;
  DateTime _lastInferAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _inferIntervalMs = kInferEveryMsInit;
  int _avgInferMs = kInferEveryMsInit;

  // UI
  int _warmupLeft = kWarmupFrames;
  int _noHitFrames = 0;
  bool _hasDetection = false;
  List<String> _topLabels = const [];

  // ボックス描画
  List<YoloDetection> _boxes = const [];
  int _srcW = 0, _srcH = 0;

  // 読み上げ：常に1件固定（読み終わるまでキープ）
  bool _speaking = false;
  String? _speakingLabel;

  // fps/HUD
  double _fps = 0;
  int _framesSeen = 0, _framesSeenLast = 0;
  DateTime _lastFpsAt = DateTime.now();
  String _debugInfo = 'YOLO init…';
  DateTime _lastHudAt = DateTime.fromMillisecondsSinceEpoch(0);

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

    _tts.setCompletionHandler(() {
      _speaking = false;
      if (!mounted) return;
      setState(() => _speakingLabel = null);
      _maybeStartSpeaking();
    });
    _tts.setErrorHandler((_) {
      _speaking = false;
      if (mounted) setState(() => _speakingLabel = null);
    });
    _tts.setCancelHandler(() {
      _speaking = false;
      if (mounted) setState(() => _speakingLabel = null);
    });

    await _yolo.loadModel();
    if (!mounted) return;
    setState(() => _debugInfo = _yolo.modelInfo());
  }

  // 動画 RGBA → RGB
  Uint8List _rgbaToRgb(Uint8List rgba, int w, int h) {
    final out = Uint8List(w * h * 3);
    int j = 0;
    for (int i = 0; i < rgba.length; i += 4) {
      out[j++] = rgba[i + 0];
      out[j++] = rgba[i + 1];
      out[j++] = rgba[i + 2];
    }
    return out;
  }

  // カメラ ARGB8888 -> RGB（bytesPerRow 対応）
  Uint8List _bytesToRgb(Uint8List src, int w, int h, {int? bytesPerRow}) {
    final out = Uint8List(w * h * 3);
    final stride = bytesPerRow ?? (w * 4);

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

  String? _pickCurrentLabel() {
    if (_yolo.lastTop.isEmpty) return null;
    final best = _yolo.lastTop.firstWhere(
      (e) => e.value >= kScoreThreshold,
      orElse: () => const MapEntry<String, double>('', -1),
    );
    return best.value >= 0 ? best.key : null;
  }

  Future<void> _maybeStartSpeaking() async {
    if (_speaking) return; // 読み終わるまでは新規開始しない
    final cand = _pickCurrentLabel();
    if (cand == null) return;

    _speaking = true;
    if (mounted) setState(() => _speakingLabel = cand);

    try {
      await _tts.stop();
      await _tts.speak(kMeaning[cand] ?? cand);
    } catch (_) {
      _speaking = false;
      if (mounted) setState(() => _speakingLabel = null);
    }
  }

  void _updateInferInterval(int lastInferMs) {
    if (lastInferMs <= 0) return;
    _avgInferMs = (_avgInferMs * 3 + lastInferMs) ~/ 4; // 平滑化
    _inferIntervalMs = (_avgInferMs * 3) ~/ 2; // 余裕 1.5x
    _inferIntervalMs = _inferIntervalMs.clamp(90, 220); // クランプ
  }

  Future<void> _processFrame(Uint8List rgbBytes, int width, int height) async {
    if (_warmupLeft > 0) {
      _warmupLeft--;
      if (_warmupLeft == 0 && mounted) {
        setState(() {
          _topLabels = const [];
          _hasDetection = false;
          _boxes = const [];
          _srcW = width;
          _srcH = height;
          _speakingLabel = null;
        });
      }
      return;
    }

    final sw = Stopwatch()..start();
    final results =
        _yolo.runFrame(rgbBytes, width, height, threshold: kScoreThreshold);
    sw.stop();
    _updateInferInterval(sw.elapsedMilliseconds);

    final top3 = _yolo.lastTop
        .where((e) => e.value >= kScoreThreshold)
        .take(3)
        .map((e) => e.key)
        .toList();

    if (results.isEmpty) {
      _noHitFrames++;
      if (_noHitFrames >= kClearAfterNoHit) {
        _hasDetection = false;
        _topLabels = const [];
        if (!_speaking) _speakingLabel = null;
      }
    } else {
      _noHitFrames = 0;
      _hasDetection = true;
    }

    if (!mounted) return;

    final now = DateTime.now();
    final shouldUpdateHud =
        kShowDebugHud && now.difference(_lastHudAt).inMilliseconds >= 500;
    if (shouldUpdateHud) _lastHudAt = now;

    setState(() {
      _boxes = _yolo.lastDetections;
      _srcW = width;
      _srcH = height;
      _topLabels = top3;
      if (shouldUpdateHud) {
        _debugInfo =
            'fps=${_fps.toStringAsFixed(1)} | ${_yolo.modelInfo()}\n${_yolo.lastDebugLine}';
      }
    });

    _maybeStartSpeaking();
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

  // ===== デモ動画フレームの取得ループ（動的間引き）=====
  void _startVideoGrabLoop() {
    _grabTimer?.cancel();
    _scheduleNextGrab();
  }

  void _scheduleNextGrab() {
    _grabTimer?.cancel();
    _grabTimer = Timer(Duration(milliseconds: _inferIntervalMs), () async {
      if (!mounted || !_videoReady) return;
      await _grabFromVideoOnce();
      _scheduleNextGrab();
    });
  }

  Future<void> _grabFromVideoOnce() async {
    if (_grabbing || _inferBusy) return;
    _grabbing = true;
    _inferBusy = true;

    try {
      final ctx = _videoKey.currentContext;
      if (ctx == null) return;
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;

      // ★ pixelRatio を定数で調整（解像度↑ほど負荷↑）
      final ui.Image img =
          await boundary.toImage(pixelRatio: kVideoGrabPixelRatio);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return;

      final w = img.width, h = img.height;
      final rgba = byteData.buffer.asUint8List();
      final rgb = _rgbaToRgb(rgba, w, h);

      _updateFps(DateTime.now());
      await _processFrame(rgb, w, h);
    } catch (_) {
      // ignore
    } finally {
      _inferBusy = false;
      _grabbing = false;
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
                  .take(3)
                  .map((k) => Chip(label: Text(kJaName[k] ?? k)))
                  .toList(),
            ),
          )
        : const SizedBox.shrink();

    final bottom = _speakingLabel != null
        ? Positioned(
            left: 24,
            right: 24,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                kMeaning[_speakingLabel!] ?? _speakingLabel!,
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
          // ===== 背景：カメラ or デモ動画 =====
          if (!kUseDemoVideo)
            Positioned.fill(
              child: CameraMacOSView(
                key: const ValueKey('macCamera'),
                cameraMode: CameraMacOSMode.video,
                fit: BoxFit.cover,
                onCameraInizialized: (controller) async {
                  _ctrl = controller;
                  await _ctrl!.startImageStream((imageData) async {
                    final now = DateTime.now();
                    _updateFps(now);

                    final tooSoon =
                        now.difference(_lastInferAt).inMilliseconds <
                            _inferIntervalMs;
                    if (_inferBusy ||
                        tooSoon ||
                        !_yolo.isReady ||
                        imageData == null) {
                      return;
                    }
                    _inferBusy = true;
                    _lastInferAt = now;

                    try {
                      final bytes = imageData.bytes;
                      final w = imageData.width;
                      final h = imageData.height;
                      if (bytes == null || w == null || h == null) return;

                      int? bpr;
                      final v = imageData.bytesPerRow;
                      if (v is int) bpr = v;

                      final rgb = _bytesToRgb(bytes, w, h, bytesPerRow: bpr);
                      await _processFrame(rgb, w, h);
                    } finally {
                      _inferBusy = false;
                    }
                  });
                },
              ),
            )
          else
            // ★ デモ動画（move.mp4）を背景に再生し、そのフレームで推論
            Positioned.fill(
              child: BackgroundVideo(
                repaintKey: _videoKey,
                assetPath: 'assets/move2.mov',
                onReady: () {
                  _videoReady = true;
                  _startVideoGrabLoop();
                },
              ),
            ),

          // 検出ボックス（共通）
          if (_srcW > 0 && _srcH > 0)
            Positioned.fill(
              child: RepaintBoundary(
                child: IgnorePointer(
                  ignoring: true,
                  child: CustomPaint(
                    painter: _BoxPainter(
                        _boxes, Size(_srcW.toDouble(), _srcH.toDouble())),
                  ),
                ),
              ),
            ),

          // 上部ラベル / 下部カード / デバッグHUD
          SafeArea(
            child: Stack(
              children: [
                if (kShowChips) chips,
                bottom,
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
    _grabTimer?.cancel();
    try {
      _ctrl?.stopImageStream();
      _ctrl?.destroy();
    } catch (_) {}
    try {
      _tts.stop();
    } catch (_) {}
    super.dispose();
  }
}
