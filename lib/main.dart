import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

late final List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Demo',
      theme: ThemeData(useMaterial3: true),
      home: const CameraPage(),
    );
  }
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  CameraDescription? _selected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // アプリ状態に合わせてカメラを再開/停止（iOSで安定させるため）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _setupCamera(selected: _selected);
    }
  }

  void _setupCamera({CameraDescription? selected}) {
    // バックカメラを優先して選択
    _selected = selected ??
        (_cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => _cameras.first,
        ));

    _controller = CameraController(
      _selected!,
      ResolutionPreset.high,
      enableAudio: false, // 静止画だけなら false でOK
      imageFormatGroup: ImageFormatGroup.yuv420, // iOSでも安定
    );

    _initFuture = _controller!.initialize().then((_) async {
      // iOSで露出やフォーカスの挙動が気になるときはここで設定も可能
      if (!mounted) return;
      setState(() {});
    }).catchError((e) {
      debugPrint('Camera init error: $e');
      if (mounted) setState(() {});
    });

    setState(() {});
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (controller.value.isTakingPicture) return;

    try {
      final XFile file = await controller.takePicture();

      // 一旦、アプリの一時ディレクトリに保存（ギャラリー保存は別プラグインが必要）
      final dir = await getTemporaryDirectory();
      final savedPath =
          '${dir.path}/shot_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(file.path).copy(savedPath);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('撮影しました: $savedPath')),
      );
    } catch (e) {
      debugPrint('Take picture error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('撮影に失敗しました: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cameras.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('カメラが見つかりませんでした')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('iPhone Camera Preview'),
        actions: [
          // 前面/背面の切り替え
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () {
              if (_cameras.length < 2) return;
              final next = (_selected?.lensDirection == CameraLensDirection.back)
                  ? _cameras.firstWhere(
                      (c) => c.lensDirection == CameraLensDirection.front,
                      orElse: () => _selected!,
                    )
                  : _cameras.firstWhere(
                      (c) => c.lensDirection == CameraLensDirection.back,
                      orElse: () => _selected!,
                    );
              _controller?.dispose();
              _setupCamera(selected: next);
            },
          ),
        ],
      ),
      body: (_controller == null)
          ? const Center(child: CircularProgressIndicator())
          : FutureBuilder(
              future: _initFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    _controller!.value.isInitialized) {
                  return CameraPreview(_controller!);
                }
                if (snapshot.hasError) {
                  return Center(
                      child: Text('初期化に失敗しました: ${snapshot.error}'));
                }
                return const Center(child: CircularProgressIndicator());
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _takePicture,
        child: const Icon(Icons.camera_alt),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
