import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// 1件の検出結果
class YoloDetection {
  final String label;
  final double score;
  final Rect rect;
  const YoloDetection(this.label, this.score, this.rect);
}

/// YOLO 推論
class YoloService {
  List<MapEntry<String, double>> lastTop = const []; // 最高スコア降順
  List<YoloDetection> lastDetections = const []; // 全検出ボックス
  bool isReady = false;

  late Interpreter _interpreter;
  late List<String> _labels;

  final int _inW = 640, _inH = 640;
  late int _cDim;
  late int _nBox;

  late final Float32List _inFlat;
  late final List<List<List<Float32List>>> _in4d;
  late final List<List<List<double>>> _out3d;

  String lastDebugLine = '';

  /// モデル読み込み & 初期化
  Future<void> loadModel() async {
    final raw =
        await rootBundle.loadString('assets/models/labels_mtsd_yolo21.txt');
    _labels = raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final options = InterpreterOptions();
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        options.addDelegate(GpuDelegateV2());
      } else if (Platform.isMacOS) {
        options.addDelegate(
            XNNPackDelegate(options: XNNPackDelegateOptions(numThreads: 4)));
      }
    } catch (e) {
      debugPrint('[YOLO] delegate setup failed: $e (CPU fallback)');
    }

    try {
      _interpreter = await Interpreter.fromAsset(
          'assets/models/best_float32.tflite',
          options: options);
    } catch (e) {
      debugPrint('[YOLO] delegate init failed: $e — retry CPU only');
      _interpreter = await Interpreter.fromAsset(
          'assets/models/best_float32.tflite',
          options: InterpreterOptions());
    }

    final want = [1, _inW, _inH, 3];
    final cur = _interpreter.getInputTensor(0).shape;
    if (!listEquals(cur, want)) {
      _interpreter.resizeInputTensor(0, want);
    }
    _interpreter.allocateTensors();

    final outT = _interpreter.getOutputTensor(0);
    _cDim = outT.shape[1];
    _nBox = outT.shape[2];

    _inFlat = Float32List(_inW * _inH * 3);
    _in4d = List.generate(
      1,
      (_) => List.generate(_inH,
          (_) => List.generate(_inW, (_) => Float32List(3), growable: false),
          growable: false),
      growable: false,
    );
    _out3d = List.generate(
      1,
      (_) => List.generate(
          _cDim, (_) => List<double>.filled(_nBox, 0.0, growable: false),
          growable: false),
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

  /// 前処理
  Float32List _preprocess(Uint8List rgbBytes, int srcW, int srcH) {
    final rgbImg = img.Image.fromBytes(
      width: srcW,
      height: srcH,
      bytes: rgbBytes.buffer,
      rowStride: srcW * 3,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );

    final resized = img.copyResize(
      rgbImg,
      width: _inW,
      height: _inH,
      interpolation: img.Interpolation.linear,
    );

    int i = 0;
    double mean = 0.0;
    for (var y = 0; y < _inH; y++) {
      for (var x = 0; x < _inW; x++) {
        final p = resized.getPixel(x, y);
        final r = p.r / 255.0, g = p.g / 255.0, b = p.b / 255.0;
        _inFlat[i++] = r;
        _inFlat[i++] = g;
        _inFlat[i++] = b;
        mean += (r + g + b) / 3.0;
      }
    }
    mean /= (_inFlat.length / 3);
    lastDebugLine = 'pre_mean=${mean.toStringAsFixed(3)}';
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

    final swPre = Stopwatch()..start();
    final flat = _preprocess(rgbBytes, srcW, srcH);
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

    final swInfer = Stopwatch()..start();
    _interpreter.run(_in4d, _out3d);
    swInfer.stop();

    final swPost = Stopwatch()..start();
    double sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

    final numClasses = _cDim - 4;
    final sx = srcW / _inW, sy = srcH / _inH;

    final proposals = <({int cls, double score, Rect rect})>[];
    for (int i = 0; i < _nBox; i++) {
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

      final cx = _out3d[0][0][i], cy = _out3d[0][1][i];
      final bw = _out3d[0][2][i], bh = _out3d[0][3][i];

      final rect = Rect.fromLTRB(
        (cx - bw / 2) * sx,
        (cy - bh / 2) * sy,
        (cx + bw / 2) * sx,
        (cy + bh / 2) * sy,
      ).intersect(Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()));

      proposals.add((cls: bestIdx, score: best, rect: rect));
    }

    final kept = _nms(proposals, iouTh: 0.45, maxKeep: 30);

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
    final preMeanLine = lastDebugLine;
    lastDebugLine = 'pre=${swPre.elapsedMilliseconds}ms '
        'infer=${swInfer.elapsedMilliseconds}ms '
        'post=${swPost.elapsedMilliseconds}ms '
        'hits=${unique.length} '
        'top3=[$top3Dbg] | $preMeanLine';

    return unique.toList();
  }
}
