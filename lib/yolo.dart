// lib/yolo.dart
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:io' show Platform;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/foundation.dart' show listEquals, debugPrint;

class YoloDetection {
  final String label;
  final double score;
  final Rect rect; // 元フレーム座標（srcW x srcH 基準）
  const YoloDetection(this.label, this.score, this.rect);
}

class YoloService {
  List<MapEntry<String, double>> lastTop = const [];
  List<YoloDetection> lastDetections = const [];
  bool isReady = false;

  late Interpreter _interpreter;
  late List<String> _labels;

  final int _inW = 640, _inH = 640;
  late int _cDim, _nBox;

  // 再利用バッファ
  late final Float32List _inFlat; // 640*640*3
  late final List<List<List<Float32List>>> _in4d; // [1,640,640,3]
  late final List<List<List<double>>> _out3d; // [1,cDim,nBox]

  String lastDebugLine = '';

  Future<void> loadModel() async {
    // ラベル読込
    final raw =
        await rootBundle.loadString('assets/models/labels_mtsd_yolo21.txt');
    _labels = raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final options = InterpreterOptions();

    // Delegate（モバイル=GPU、macOS=XNNPACK CPU）
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // 利用環境によりオプション列挙が無い場合があるので素の V2 を付与
        options.addDelegate(GpuDelegateV2());
        debugPrint('[YOLO] GPU delegate enabled (mobile)');
      } else if (Platform.isMacOS) {
        try {
          options.addDelegate(
            XNNPackDelegate(options: XNNPackDelegateOptions(numThreads: 4)),
          );
          debugPrint('[YOLO] XNNPACK delegate enabled (macOS CPU fast)');
        } catch (e) {
          debugPrint('[YOLO] XNNPACK unavailable: $e (fallback CPU)');
        }
      }
    } catch (e) {
      debugPrint('[YOLO] delegate setup failed: $e (fallback CPU)');
    }

    // Interpreter 準備
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

    // 入力サイズ固定 & allocate
    final want = [1, _inW, _inH, 3];
    final cur = _interpreter.getInputTensor(0).shape;
    if (!listEquals(cur, want)) {
      debugPrint('[YOLO] resize input $cur -> $want');
      _interpreter.resizeInputTensor(0, want);
    }
    _interpreter.allocateTensors();

    final inT = _interpreter.getInputTensor(0);
    final outT = _interpreter.getOutputTensor(0);
    _cDim = outT.shape[1]; // 25 (=4+21)
    _nBox = outT.shape[2]; // 8400

    // 再利用バッファ初期化
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

    debugPrint('=== YOLO MODEL INFO ===\n'
        'input=${inT.shape}(${inT.type}) / output=${outT.shape}(${outT.type}) / labels=${_labels.length}\n'
        '=======================');

    isReady = true;
  }

  // RGB 0–255 → [1,640,640,3] float32(0–1) フラット
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

  String modelInfo() {
    try {
      final inT = _interpreter.getInputTensor(0);
      final outT = _interpreter.getOutputTensor(0);
      return 'input=${inT.shape}(${inT.type}) / output=${outT.shape}(${outT.type}) / labels=${_labels.length}';
    } catch (e) {
      return 'modelInfo error: $e';
    }
  }

  List<String> runFrame(
    Uint8List rgbBytes,
    int srcW,
    int srcH, {
    double threshold = 0.65,
  }) {
    if (!isReady) return [];

    // ===== 前処理 =====
    final swPre = Stopwatch()..start();
    final flat = _preprocess(rgbBytes, srcW, srcH);
    // 既存の _in4d に値だけ詰める（アロケーション無し）
    int k = 0;
    for (int y = 0; y < _inH; y++) {
      final row = _in4d[0][y];
      for (int x = 0; x < _inW; x++) {
        final f = row[x];
        f[0] = flat[k++]; // r
        f[1] = flat[k++]; // g
        f[2] = flat[k++]; // b
      }
    }
    swPre.stop();

    // ===== 推論 =====
    final swInfer = Stopwatch()..start();
    _interpreter.run(_in4d, _out3d);
    swInfer.stop();

    // ===== 後処理（ボックス復元＋NMS）=====
    final swPost = Stopwatch()..start();
    double sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

    final numClasses = _cDim - 4;
    final sx = srcW / _inW;
    final sy = srcH / _inH;

    final proposals = <({int cls, double score, Rect rect})>[];
    for (int i = 0; i < _nBox; i++) {
      // クラス最大
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

      // bbox [cx,cy,w,h]（640基準）→ 元サイズへ
      final cx = _out3d[0][0][i];
      final cy = _out3d[0][1][i];
      final bw = _out3d[0][2][i];
      final bh = _out3d[0][3][i];

      final left = (cx - bw / 2) * sx;
      final top = (cy - bh / 2) * sy;
      final right = (cx + bw / 2) * sx;
      final bottom = (cy + bh / 2) * sy;

      final rect = Rect.fromLTRB(
        left.clamp(0.0, srcW.toDouble()),
        top.clamp(0.0, srcH.toDouble()),
        right.clamp(0.0, srcW.toDouble()),
        bottom.clamp(0.0, srcH.toDouble()),
      );
      proposals.add((cls: bestIdx, score: best, rect: rect));
    }

    double iou(Rect a, Rect b) {
      final inter = Rect.fromLTRB(
        math.max(a.left, b.left),
        math.max(a.top, b.top),
        math.min(a.right, b.right),
        math.min(a.bottom, b.bottom),
      );
      final interArea =
          math.max(0.0, inter.width) * math.max(0.0, inter.height);
      final unionArea = a.width * a.height + b.width * b.height - interArea;
      return unionArea <= 0 ? 0.0 : interArea / unionArea;
    }

    proposals.sort((a, b) => b.score.compareTo(a.score));
    final kept = <({int cls, double score, Rect rect})>[];
    const iouTh = 0.45;
    for (final p in proposals) {
      bool suppress = false;
      for (final q in kept) {
        if (p.cls == q.cls && iou(p.rect, q.rect) > iouTh) {
          suppress = true;
          break;
        }
      }
      if (!suppress) kept.add(p);
      if (kept.length >= 30) break; // 上限で描画負荷を抑制
    }

    // ラベル別にまとめ＋保持
    final Map<String, double> bestByLabel = {};
    final dets = <YoloDetection>[];
    for (final kx in kept) {
      if (kx.cls < 0 || kx.cls >= _labels.length) continue;
      final label = _labels[kx.cls];
      bestByLabel[label] = math.max(bestByLabel[label] ?? 0.0, kx.score);
      dets.add(YoloDetection(label, kx.score, kx.rect));
    }
    lastDetections = dets;

    lastTop = bestByLabel.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final unique = bestByLabel.keys.toSet();

    final top3Dbg = lastTop
        .take(3)
        .map((e) => '${e.key}(${e.value.toStringAsFixed(2)})')
        .toList();

    swPost.stop();
    final preMeanLine = lastDebugLine;
    lastDebugLine = 'pre=${swPre.elapsedMilliseconds}ms '
        'infer=${swInfer.elapsedMilliseconds}ms '
        'post=${swPost.elapsedMilliseconds}ms '
        'hits=${unique.length} '
        'top3=${top3Dbg.join(", ")} | $preMeanLine';

    return unique.toList();
  }
}
