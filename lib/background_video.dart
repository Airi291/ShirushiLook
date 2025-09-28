import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

/// 背景で mp4 をループ再生するだけの軽量ウィジェット。
/// ※ RepaintBoundary を Video の“内側”に置き、toImage でネイティブ解像度を取得しやすくする。
class BackgroundVideo extends StatefulWidget {
  final GlobalKey repaintKey;
  final VoidCallback? onReady; // 再生準備完了コールバック
  final String assetPath; // 例: 'assets/move.mp4'

  const BackgroundVideo({
    super.key,
    required this.repaintKey,
    required this.assetPath,
    this.onReady,
  });

  @override
  State<BackgroundVideo> createState() => _BackgroundVideoState();
}

class _BackgroundVideoState extends State<BackgroundVideo> {
  late final VideoPlayerController _vc;

  @override
  void initState() {
    super.initState();
    _vc = VideoPlayerController.asset(widget.assetPath)
      ..setLooping(true)
      ..setVolume(0.0);
    _init();
  }

  Future<void> _init() async {
    await _vc.initialize();
    if (!mounted) return;
    setState(() {});
    await _vc.play();
    widget.onReady?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_vc.value.isInitialized) {
      return const SizedBox.expand(child: ColoredBox(color: Color(0xFF000000)));
    }

    // 画面全体には cover 表示。ただしキャプチャ対象（RepaintBoundary）は
    // “内側”にあり、Video のネイティブ解像度できっちり描画される。
    return FittedBox(
      fit: BoxFit.cover,
      child: RepaintBoundary(
        key: widget.repaintKey,
        child: SizedBox(
          width: _vc.value.size.width,
          height: _vc.value.size.height,
          child: VideoPlayer(_vc),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _vc.dispose();
    super.dispose();
  }
}
