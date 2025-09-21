import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

// ==== 英語ラベル → 日本語表示名 ====
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

// ==== 英語ラベル → 意味 ====
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

  // 横画面固定
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final cameras = await availableCameras();
  runApp(_App(cameras: cameras));
}

class _App extends StatelessWidget {
  final List<CameraDescription> cameras;
  const _App({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _CameraOverlayPage(cameras: cameras),
    );
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

  // 音声
  final FlutterTts _tts = FlutterTts();

  // 上部/下部の表示内容
  List<String> topLabels = ['stop', 'speed_limit'];
  String? bottomLabel = 'speed_limit';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _setupTts();
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage("ja-JP");
    await _tts.setSpeechRate(0.5); // ← 速度はここで調整（0.5=ゆっくり）
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> _initCamera() async {
    final back = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    final ctrl = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await ctrl.initialize();
    if (!mounted) return;

    setState(() {
      _cam = ctrl;
      _ready = true;
    });

    // 初期表示時に下部テキストを読み上げ
    final text = bottomLabel != null ? kMeaning[bottomLabel!] : null;
    if (text != null) _speak(text);
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
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cam?.dispose();
    _tts.stop();
    super.dispose();
  }

  // 端末の向き→回転角（横固定なので 0 or π）
  double _rotationRad() {
    if (_cam == null) return 0;
    switch (_cam!.value.deviceOrientation) {
      case DeviceOrientation.landscapeLeft:
        return 0; // 左横持ち
      case DeviceOrientation.landscapeRight:
        return math.pi; // 右横持ち（上下反転）
      case DeviceOrientation.portraitUp:
        return -math.pi / 2;
      case DeviceOrientation.portraitDown:
        return math.pi / 2;
    }
  }

  // カメラ映像を“画面いっぱい”に表示
  Widget _buildCameraFull() {
    final c = _cam!;
    if (!c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final preview = c.value.previewSize!;
    // iOS は縦基準のため、横表示に合わせて幅高を入れ替え
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
    if (!_ready || _cam == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final bottomText = bottomLabel != null ? kMeaning[bottomLabel!] : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ✅ 背景：横画面のカメラを画面いっぱいに
          _buildCameraFull(),

          // ✅ オーバーレイは SafeArea の内側に配置
          SafeArea(
            child: Stack(
              children: [
                if (topLabels.isNotEmpty)
                  Positioned(
                    top: 12,
                    left: 24,
                    right: 24,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
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
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: topLabels
                                .map(
                                  (k) => Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: Chip(
                                      label: Text(
                                        kJaName[k] ?? k,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (bottomText != null)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
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
                        bottomText,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
