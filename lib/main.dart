// lib/main.dart
import 'dart:async';
import 'dart:math' as math;
import 'yolo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

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
    // シンプルなプレースホルダー
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
              ElevatedButton(
                onPressed: _loadCameras,
                child: const Text('再試行'),
              )
            ],
          ),
        ),
      );
    }
    // 取得できたら本画面へ
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
    await _initCamera(); // ① すぐプレビュー
    Future.delayed(Duration(seconds: 2), _loadYoloInBackground);
    await _setupTts(); // ② TTS
    _loadYoloInBackground(); // ③ YOLO
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
      _ready = true; // プレビュー表示OK
    });
  }

  void _loadYoloInBackground() {
    unawaited(Future.microtask(() async {
      try {
        await _yolo.loadModel();
        debugPrint('[YOLO] loaded');
        if (!mounted) return;
        _maybeStartStream();
      } catch (e, st) {
        debugPrint('[YOLO] load error: $e\n$st');
      }
    }));
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

  Future<void> _maybeStartStream() async {
    if (!_yolo.isReady || _cam == null || !_cam!.value.isInitialized) return;

    bool _isProcessing = false;
    int _frameCount = 0;
    int _lastMs = DateTime.now().millisecondsSinceEpoch;

    try {
      await _cam!.startImageStream((CameraImage image) async {
        _frameCount++;
        if (_frameCount % 3 != 0) return; // 3 枚に 1 回だけ処理
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastMs < 100) return; // 100ms に 1 回だけ処理
        _lastMs = now;

        if (_isProcessing) return;
        _isProcessing = true;
        try {
          final bytes = Uint8List.fromList(image.planes[0].bytes);
          await _processFrame(bytes);
        } finally {
          _isProcessing = false;
        }
      });
    } catch (e) {
      debugPrint('[Camera] startImageStream error: $e');
    }
  }

  String? _lastSpoken;
  DateTime _lastSpeakTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isSpeaking = false;
  final List<String> _speakQueue = [];

  Future<void> _processFrame(Uint8List bytes) async {
    if (!_yolo.isReady) return;
    final results = _yolo.runMock(bytes);
    if (!mounted) return;

    setState(() {
      topLabels = results;
      bottomLabel = results.isNotEmpty ? results.first : null;
    });

    if (bottomLabel != null) {
      final now = DateTime.now();
      final text = kMeaning[bottomLabel!];

      if (text != null) {
        // 🔑 2秒クールダウン & 同じ標識を連呼しない
        final isSameAsBefore = bottomLabel == _lastSpoken;
        final isCooldownOver = now.difference(_lastSpeakTime).inSeconds >= 2;

        if (!isSameAsBefore || isCooldownOver) {
          _lastSpoken = bottomLabel;
          _lastSpeakTime = now;
          _enqueueSpeak(text);
        }
      }
    }
  }

  void _enqueueSpeak(String text) {
    _speakQueue.add(text);
    if (!_isSpeaking) _dequeueAndSpeak();
  }

  Future<void> _dequeueAndSpeak() async {
    if (_speakQueue.isEmpty) return;
    _isSpeaking = true;
    final text = _speakQueue.removeAt(0);

    try {
      await _tts.stop(); // 前の音声をキャンセル
      await _tts.speak(text);
      _tts.setCompletionHandler(() {
        if (mounted) {
          setState(() => bottomLabel = null); // 読み終わりで下部メッセージを消す
        }
        _isSpeaking = false;
        _dequeueAndSpeak(); // 次があれば続けて読む
      });
    } catch (_) {
      _isSpeaking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    final cam = _cam;
    if (cam == null) return;
    if (state == AppLifecycleState.inactive) {
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

  Widget _buildCameraFull() {
    final c = _cam!;
    if (!c.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final preview = c.value.previewSize!;
    final rotatedW = preview.height;
    final rotatedH = preview.width;

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: rotatedW,
          height: rotatedH,
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
          if (_ready && _cam != null) _buildCameraFull(),
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
                          .map((k) => Chip(
                                label: Text(kJaName[k] ?? k),
                              ))
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
                              offset: Offset(0, 2))
                        ],
                      ),
                      child: Text(
                        kMeaning[bottomLabel!] ?? bottomLabel!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Colors.red,
                            letterSpacing: 1.2),
                      ),
                    ),
                  ),
                // 右上に簡易リロード
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.refresh),
                    onPressed: () async {
                      setState(() => _ready = false);
                      await _cam?.dispose();
                      await _initCamera();
                      _maybeStartStream();
                    },
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
