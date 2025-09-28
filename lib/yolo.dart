import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

/// 1件の検出結果
class YoloDetection {
  final String label;
  final double score;
  final Rect rect; // 元フレーム座標（srcW×srcH）
  const YoloDetection(this.label, this.score, this.rect);
}

/// YOLO 推論サービス（レターボックス前処理＋NMS）
class YoloService {
  List<MapEntry<String, double>> lastTop = const []; // 最高スコア降順
  List<YoloDetection> lastDetections = const []; // 全検出ボックス
  bool isReady = false;

  late Interpreter _interpreter;
  late List<String> _labels;

  final int _inW = 640, _inH = 640;
  late int _cDim;
  late int _nBox;

  // 入出力バッファ
  late final Float32List _inFlat; // 640*640*3
  late final List<List<List<Float32List>>> _in4d; // [1,640,640,3]
  late final List<List<List<double>>> _out3d; // [1,cDim,nBox]

  // 直近前処理のレターボックス情報（後処理で元サイズへ戻すため）
  double _lbScale = 1.0; // scale = min(640/srcW, 640/srcH)
  int _lbPadX = 0; // 左右パディング（dest 上の左オフセット）
  int _lbPadY = 0; // 上下パディング（dest 上の上オフセット）

  String lastDebugLine = '';

  /// モデル読み込み & 初期化
  Future<void> loadModel() async {
    // ラベル（2パス読み込み：models/ 配下→assets/直下の順でフォールバック）
    Future<List<String>> _loadLabels() async {
      try {
        final raw =
            await rootBundle.loadString('assets/models/labels_mtsd_yolo21.txt');
        return raw
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } catch (_) {
        final raw = await rootBundle.loadString('assets/labels_mtsd21.txt');
        return raw
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    }

    _labels = await _loadLabels();

    final options = InterpreterOptions();
    // GPU（Android/iOS）/ XNNPACK（macOS）を優先
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        options.addDelegate(GpuDelegateV2());
        debugPrint('[YOLO] GPU delegate enabled (mobile)');
      } else if (Platform.isMacOS) {
        options.addDelegate(XNNPackDelegate(
          options: XNNPackDelegateOptions(numThreads: 4),
        ));
        debugPrint('[YOLO] XNNPACK delegate enabled (macOS CPU fast)');
      }
    } catch (e) {
      debugPrint('[YOLO] delegate setup failed: $e (CPU fallback)');
    }

    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float32.tflite',
        options: options,
      );
    } catch (e) {
      debugPrint('[YOLO] init with delegate failed: $e — retry CPU only');
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float32.tflite',
        options: InterpreterOptions(),
      );
    }

    // 入力を固定しつつ allocate
    final want = [1, _inH, _inW, 3];
    final cur = _interpreter.getInputTensor(0).shape;
    if (!listEquals(cur, want)) {
      _interpreter.resizeInputTensor(0, want);
    }
    _interpreter.allocateTensors();

    final outT = _interpreter.getOutputTensor(0);
    _cDim = outT.shape[1];
    _nBox = outT.shape[2];

    // バッファ確保（使い回し）
    _inFlat = Float32List(_inW * _inH * 3);
    _in4d = List.generate(
      1,
      (_) => List.generate(
        _inH,
        (_) => List.generate(_inW, (_) => Float32List(3), growable: false),
        growable: false,
      ),
      growable: false,
    );
    _out3d = List.generate(
      1,
      (_) => List.generate(
        _cDim,
        (_) => List<double>.filled(_nBox, 0.0, growable: false),
        growable: false,
      ),
      growable: false,
    );

    isReady = true;
  }

  /// デバッグ用
  String modelInfo() {
    try {
      final inT = _interpreter.getInputTensor(0);
      final outT = _interpreter.getOutputTensor(0);
      return 'input=${inT.shape}(${inT.type}) / output=${outT.shape}(${outT.type}) / labels=${_labels.length}';
    } catch (e) {
      return 'modelInfo error: $e';
    }
  }

  /// 前処理：RGB(0–255) → Letterbox 640×640 float32(0–1)
  /// 速度重視の最近傍リサイズ＋114のパディング（精度/速度バランス良）
  Float32List _preprocessLetterboxRgb(Uint8List rgb, int srcW, int srcH) {
    // レターボックス情報（後処理で使う）
    final scale = math.min(_inW / srcW, _inH / srcH);
    final newW = (srcW * scale).floor();
    final newH = (srcH * scale).floor();
    final padX = ((_inW - newW) ~/ 2);
    final padY = ((_inH - newH) ~/ 2);
    _lbScale = scale;
    _lbPadX = padX;
    _lbPadY = padY;

    // まず全体を 114/255 で埋める（YOLO の標準パディング色）
    const padVal = 114.0 / 255.0;
    for (int i = 0; i < _inFlat.length; i++) {
      _inFlat[i] = padVal;
    }

    // 配置先矩形に最近傍で詰める
    // 先に逆数を出しておくと速い
    final invScale = 1.0 / scale;
    int dstBaseRow = (padY * _inW * 3);
    for (int y = 0; y < newH; y++) {
      final srcY = (y * invScale).floor().clamp(0, srcH - 1);
      int dstIdx = dstBaseRow + padX * 3;
      int srcBase = srcY * srcW * 3;
      for (int x = 0; x < newW; x++) {
        final srcX = (x * invScale).floor().clamp(0, srcW - 1);
        final si = srcBase + srcX * 3;

        // 正規化して格納
        _inFlat[dstIdx++] = rgb[si] / 255.0; // R
        _inFlat[dstIdx++] = rgb[si + 1] / 255.0; // G
        _inFlat[dstIdx++] = rgb[si + 2] / 255.0; // B
      }
      dstBaseRow += (_inW * 3);
    }

    // デバッグ（簡易明るさ）
    double mean = 0.0;
    for (int i = 0; i < _inFlat.length; i += 3) {
      mean += (_inFlat[i] + _inFlat[i + 1] + _inFlat[i + 2]) / 3.0;
    }
    mean /= (_inFlat.length / 3);
    lastDebugLine =
        'pre_mean=${mean.toStringAsFixed(3)} scale=${scale.toStringAsFixed(3)} pad=($_lbPadX,$_lbPadY)';

    return _inFlat;
  }

  static double _iou(Rect a, Rect b) {
    final inter = Rect.fromLTRB(
      math.max(a.left, b.left),
      math.max(a.top, b.top),
      math.min(a.right, b.right),
      math.min(a.bottom, b.bottom),
    );
    final interArea = math.max(0.0, inter.width) * math.max(0.0, inter.height);
    final unionArea = a.width * a.height + b.width * b.height - interArea;
    return unionArea <= 0 ? 0.0 : interArea / unionArea;
  }

  static List<({int cls, double score, Rect rect})> _nms(
    List<({int cls, double score, Rect rect})> props, {
    double iouTh = 0.45,
    int maxKeep = 30,
  }) {
    props.sort((a, b) => b.score.compareTo(a.score));
    final kept = <({int cls, double score, Rect rect})>[];
    for (final p in props) {
      bool suppress = false;
      for (final q in kept) {
        if (p.cls == q.cls && _iou(p.rect, q.rect) > iouTh) {
          suppress = true;
          break;
        }
      }
      if (!suppress) kept.add(p);
      if (kept.length >= maxKeep) break;
    }
    return kept;
  }

  /// 前処理→推論→後処理
  List<String> runFrame(Uint8List rgbBytes, int srcW, int srcH,
      {double threshold = 0.65}) {
    if (!isReady) return [];

    // ===== 前処理（レターボックス）=====
    final swPre = Stopwatch()..start();
    final flat = _preprocessLetterboxRgb(rgbBytes, srcW, srcH);

    // 入力 4D テンソルに詰め替え（再利用バッファ）
    int k = 0;
    for (int y = 0; y < _inH; y++) {
      final row = _in4d[0][y];
      for (int x = 0; x < _inW; x++) {
        final f = row[x];
        f[0] = flat[k++];
        f[1] = flat[k++];
        f[2] = flat[k++];
      }
    }
    swPre.stop();

    // ===== 推論 =====
    final swInfer = Stopwatch()..start();
    _interpreter.run(_in4d, _out3d);
    swInfer.stop();

    // ===== 後処理 =====
    final swPost = Stopwatch()..start();
    double sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

    final numClasses = _cDim - 4;

    // 640空間の bbox を「元フレーム座標」に戻すための係数
    final invScale = 1.0 / _lbScale;
    final padX = _lbPadX.toDouble();
    final padY = _lbPadY.toDouble();

    final proposals = <({int cls, double score, Rect rect})>[];
    for (int i = 0; i < _nBox; i++) {
      // 最良クラス
      double best = -1.0;
      int bestIdx = -1;
      for (int c = 0; c < numClasses; c++) {
        final p = sigmoid(_out3d[0][4 + c][i]);
        if (p > best) {
          best = p;
          bestIdx = c;
        }
      }
      if (bestIdx < 0 || best < threshold) continue;

      // [cx,cy,w,h]（640空間）
      final cx = _out3d[0][0][i];
      final cy = _out3d[0][1][i];
      final bw = _out3d[0][2][i];
      final bh = _out3d[0][3][i];

      // レターボックス解除 → 元フレーム座標へ
      double x1 = (cx - bw / 2.0 - padX) * invScale;
      double y1 = (cy - bh / 2.0 - padY) * invScale;
      double x2 = (cx + bw / 2.0 - padX) * invScale;
      double y2 = (cy + bh / 2.0 - padY) * invScale;

      if (x1 > x2) {
        final t = x1;
        x1 = x2;
        x2 = t;
      }
      if (y1 > y2) {
        final t = y1;
        y1 = y2;
        y2 = t;
      }

      final rect = Rect.fromLTRB(
        x1.clamp(0.0, srcW.toDouble()),
        y1.clamp(0.0, srcH.toDouble()),
        x2.clamp(0.0, srcW.toDouble()),
        y2.clamp(0.0, srcH.toDouble()),
      );

      if (rect.width > 1 && rect.height > 1) {
        proposals.add((cls: bestIdx, score: best, rect: rect));
      }
    }

    // NMS（クラス別）
    final kept = _nms(proposals, iouTh: 0.45, maxKeep: 30);

    // UI向け集約
    final Map<String, double> bestByLabel = {};
    final dets = <YoloDetection>[];
    for (final p in kept) {
      if (p.cls < 0 || p.cls >= _labels.length) continue;
      final label = _labels[p.cls];
      bestByLabel[label] = math.max(bestByLabel[label] ?? 0.0, p.score);
      dets.add(YoloDetection(label, p.score, p.rect));
    }
    lastDetections = dets;

    lastTop = bestByLabel.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final unique = bestByLabel.keys.toSet();

    final top3Dbg = lastTop
        .take(3)
        .map((e) => '${e.key}(${e.value.toStringAsFixed(2)})')
        .join(', ');
    lastDebugLine =
        'pre=${swPre.elapsedMilliseconds}ms infer=${swInfer.elapsedMilliseconds}ms '
        'post=${swPost.elapsedMilliseconds}ms hits=${unique.length} top3=[$top3Dbg] | $lastDebugLine';
    swPost.stop();

    return unique.toList();
  }
}
