// lib/main.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'yolo.dart';

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

class _Entry extends StatefulWidget {
  const _Entry({super.key});
  @override
  State<_Entry> createState() => _EntryState();
}

class _EntryState extends State<_Entry> {
  List<CameraDescription>? _cams;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCameras();
  }

  Future<void> _loadCameras() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cams = await Future.any<List<CameraDescription>>([
        availableCameras(),
        Future<List<CameraDescription>>.delayed(
          const Duration(seconds: 6),
          () => throw TimeoutException('availableCameras timeout'),
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _cams = cams;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
            child: Text('カメラ初期化中...', style: TextStyle(color: Colors.white))),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('カメラ初期化に失敗しました',
                  style: TextStyle(color: Colors.white)),
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadCameras, child: const Text('再試行')),
            ],
          ),
        ),
      );
    }
    return _CameraOverlayPage(cameras: _cams!);
  }
}

class _CameraOverlayPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const _CameraOverlayPage({super.key, required this.cameras});

  @override
  State<_CameraOverlayPage> createState() => _CameraOverlayPageState();
}

class _CameraOverlayPageState extends State<_CameraOverlayPage>
    with WidgetsBindingObserver {
  CameraController? _cam;
  bool _ready = false;
  bool _streamingStarted = false;

  String _debugInfo = 'YOLO init…';

  final FlutterTts _tts = FlutterTts();
  final YoloService _yolo = YoloService();

  List<String> topLabels = [];
  String? bottomLabel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _initCamera();
    unawaited(_loadYoloInBackground());
    await _setupTts();
  }

  Future<void> _initCamera() async {
    final back = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    final ctrl = CameraController(
      back,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await Future.any([
        ctrl.initialize(),
        Future.delayed(const Duration(seconds: 6),
            () => throw TimeoutException('camera initialize timeout')),
      ]);
    } catch (e) {
      debugPrint('[Camera] initialize error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('カメラ初期化に時間がかかっています。右上から再起動してください。')),
        );
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _cam = ctrl;
      _ready = true;
    });
  }

  Future<void> _loadYoloInBackground() async {
    try {
      await _yolo.loadModel();
      if (!mounted) return;
      setState(() => _debugInfo = _yolo.modelInfo());
      _maybeStartStream();
    } catch (e, st) {
      debugPrint('[YOLO] load error: $e\n$st');
    }
  }

  Future<void> _setupTts() async {
    try {
      await _tts.setLanguage("ja-JP");
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (e) {
      debugPrint('[TTS] setup error: $e');
    }
  }

  // YUV420 → RGB（連続 3ch バイト）
  Uint8List _yuv420ToRgb(CameraImage image) {
    final int w = image.width, h = image.height;

    final yPlane = image.planes[0];
    final uPlane = image.planes.length > 1 ? image.planes[1] : yPlane;
    final vPlane = image.planes.length > 2 ? image.planes[2] : null;

    // iOS(NV12) は U/V が交互で plane[1] に入ることがある。
    final bool uvInterleaved =
        vPlane == null || vPlane.bytes.isEmpty || vPlane.bytesPerRow == 0;

    final int yRowStride = yPlane.bytesPerRow;
    final int uvRowStride = uPlane.bytesPerRow;

    // bytesPerPixel が null の端末があるのでデフォルト 2（NV12）でフォールバック
    final int uvPixelStride = (uPlane.bytesPerPixel ?? (uvInterleaved ? 2 : 1));

    final out = Uint8List(w * h * 3);

    for (int y = 0; y < h; y++) {
      final yOff = y * yRowStride;
      final uvOff = (y >> 1) * uvRowStride;

      for (int x = 0; x < w; x++) {
        final int yp = yPlane.bytes[yOff + x];

        int up, vp;
        if (uvInterleaved) {
          // NV12: plane[1] に [U,V,U,V,...]
          final idx = (x >> 1) * uvPixelStride + uvOff;
          up = uPlane.bytes[idx];
          vp = uPlane.bytes[idx + 1];
        } else {
          // Android 典型: U/V が別プレーン
          final idx = (x >> 1) * uvPixelStride + uvOff;
          up = uPlane.bytes[idx];
          vp = vPlane!.bytes[idx];
        }

        // YUV → RGB（BT.601 近似）
        int r = (yp + 1.370705 * (vp - 128)).round();
        int g = (yp - 0.337633 * (up - 128) - 0.698001 * (vp - 128)).round();
        int b = (yp + 1.732446 * (up - 128)).round();

        if (r < 0)
          r = 0;
        else if (r > 255) r = 255;
        if (g < 0)
          g = 0;
        else if (g > 255) g = 255;
        if (b < 0)
          b = 0;
        else if (b > 255) b = 255;

        final o = (y * w + x) * 3;
        out[o] = r;
        out[o + 1] = g;
        out[o + 2] = b;
      }
    }

    return out;
  }

  Future<void> _maybeStartStream() async {
    if (_streamingStarted) return;
    if (!_yolo.isReady || _cam == null || !_cam!.value.isInitialized) return;

    _streamingStarted = true;
    bool busy = false;

    try {
      await _cam!.startImageStream((CameraImage image) async {
        if (busy) return;
        busy = true;
        try {
          final rgb = _yuv420ToRgb(image);
          await _processFrame(rgb, image.width, image.height);
        } finally {
          busy = false;
        }
      });
    } catch (e) {
      debugPrint('[Camera] startImageStream error: $e');
    }
  }

  String? _lastSpoken;
  DateTime _lastSpeakTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _speaking = false;
  final List<String> _queue = [];

  Future<void> _processFrame(Uint8List rgbBytes, int width, int height) async {
    if (!_yolo.isReady) return;

    final results = _yolo.runFrame(rgbBytes, width, height, threshold: 0.6);

    setState(() {
      topLabels = results;
      bottomLabel = results.isNotEmpty ? results.first : null;
      _debugInfo = _yolo.modelInfo();
    });

    if (bottomLabel != null) {
      final now = DateTime.now();
      final text = kMeaning[bottomLabel!];
      if (text != null) {
        final same = bottomLabel == _lastSpoken;
        final cool = now.difference(_lastSpeakTime).inSeconds >= 2;
        if (!same || cool) {
          _lastSpoken = bottomLabel;
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
        if (mounted) setState(() => bottomLabel = null);
        _speaking = false;
        _dequeue();
      });
    } catch (_) {
      _speaking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    final cam = _cam;
    if (cam == null) return;
    if (state == AppLifecycleState.inactive) {
      _streamingStarted = false;
      await cam.dispose();
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _ready = false);
      await _initCamera();
      _maybeStartStream();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamingStarted = false;
    _cam?.dispose();
    _tts.stop();
    super.dispose();
  }

  double _rotationRad() {
    if (_cam == null) return 0;
    switch (_cam!.value.deviceOrientation) {
      case DeviceOrientation.landscapeLeft:
        return 0;
      case DeviceOrientation.landscapeRight:
        return math.pi;
      case DeviceOrientation.portraitUp:
        return -math.pi / 2;
      case DeviceOrientation.portraitDown:
        return math.pi / 2;
    }
  }

  Widget _cameraPreview() {
    final c = _cam;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    final preview = c.value.previewSize!;
    final w = preview.height, h = preview.width;
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: w,
          height: h,
          child: Transform.rotate(
            angle: _rotationRad(),
            child: CameraPreview(c),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_ready && _cam != null) _cameraPreview(),
          if (!_ready)
            const Center(
              child:
                  Text('プレビュー準備中...', style: TextStyle(color: Colors.white70)),
            ),
          SafeArea(
            child: Stack(
              children: [
                if (topLabels.isNotEmpty)
                  Positioned(
                    top: 12,
                    left: 24,
                    right: 24,
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: topLabels
                          .map((k) => Chip(label: Text(kJaName[k] ?? k)))
                          .toList(),
                    ),
                  ),
                if (bottomLabel != null)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: const [
                          BoxShadow(
                            blurRadius: 6,
                            color: Colors.black26,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        kMeaning[bottomLabel!] ?? bottomLabel!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.red,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        color: Colors.black54,
                        child: Text(
                          _debugInfo,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        color: Colors.white,
                        icon: const Icon(Icons.refresh),
                        onPressed: () async {
                          setState(() => _ready = false);
                          await _cam?.dispose();
                          await _initCamera();
                          _maybeStartStream();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
