// lib/yolo.dart
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/foundation.dart' show listEquals, debugPrint;

class YoloService {
  List<MapEntry<String, double>> lastTop = const [];
  bool isReady = false;

  late Interpreter _interpreter;
  late List<String> _labels;

  final int _inW = 640, _inH = 640;
  late int _cDim, _nBox;

  // 再利用バッファ
  late Float32List _inFlat; // 640*640*3
  late List<List<List<Float32List>>> _in4d; // [1,640,640,3]
  late List<List<List<double>>> _out3d; // [1,cDim,nBox]

  String lastDebugLine = '';

// yolo.dart の loadModel() だけ差し替え（他はそのまま使えます）
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

    // 可能ならスレッド数（古いバージョンでエラーになる場合があるので try/catch）
    try {
      // デスクトップは少し多め（お好みで）
      // ignore: invalid_use_of_visible_for_testing_member
      options.threads = Platform.isMacOS ? 4 : 2;
    } catch (_) {}

    // === Delegate 適用 ===
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // バージョン差異で列挙型が無い環境があるので、素の GpuDelegateV2() を渡す
        options.addDelegate(GpuDelegateV2());
        debugPrint('[YOLO] GPU delegate enabled (mobile)');
      } else if (Platform.isMacOS) {
        // macOS は標準で GPU 未対応 → XNNPACK(あれば) で高速CPU
        try {
          options.addDelegate(XNNPackDelegate(
            options: XNNPackDelegateOptions(numThreads: 4),
          ));
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
          options: options);
    } catch (e) {
      debugPrint('[YOLO] init with delegate failed: $e — retry CPU only');
      _interpreter = await Interpreter.fromAsset(
          'assets/models/best_float32.tflite',
          options: InterpreterOptions());
    }

    // 入力サイズ固定 & allocate
    final want = [1, 640, 640, 3];
    final cur = _interpreter.getInputTensor(0).shape;
    if (!listEquals(cur, want)) {
      debugPrint('[YOLO] resize input $cur -> $want');
      _interpreter.resizeInputTensor(0, want);
    }
    _interpreter.allocateTensors();

    final inT = _interpreter.getInputTensor(0);
    final outT = _interpreter.getOutputTensor(0);
    _cDim = outT.shape[1]; // 25
    _nBox = outT.shape[2]; // 8400

    // 既存の再利用バッファ初期化（あなたの yolo.dart で使っているものがあればそのままでOK）
    _inFlat = Float32List(640 * 640 * 3);
    _in4d = List.generate(
        1,
        (_) => List.generate(640,
            (_) => List.generate(640, (_) => Float32List(3), growable: false),
            growable: false),
        growable: false);
    _out3d = List.generate(
        1,
        (_) => List.generate(
            _cDim, (_) => List<double>.filled(_nBox, 0.0, growable: false),
            growable: false),
        growable: false);

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

    final swInfer = Stopwatch()..start();
    _interpreter.run(_in4d, _out3d);
    swInfer.stop();

    final swPost = Stopwatch()..start();
    double sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));
    final numClasses = _cDim - 4;

    final scored = <(int boxIdx, int classIdx, double score)>[];
    for (int i = 0; i < _nBox; i++) {
      double best = -1.0;
      int bestIdx = -1;
      for (int c = 0; c < numClasses; c++) {
        final double logit = _out3d[0][4 + c][i];
        final p = sigmoid(logit);
        if (p > best) {
          best = p;
          bestIdx = c;
        }
      }
      if (bestIdx >= 0) scored.add((i, bestIdx, best));
    }
    scored.sort((a, b) => b.$3.compareTo(a.$3));

    final Map<String, double> bestByLabel = {};
    for (final s in scored) {
      final cls = s.$2;
      if (cls < 0 || cls >= _labels.length) continue;
      final label = _labels[cls];
      final score = s.$3;
      if (score >= threshold) {
        final prev = bestByLabel[label];
        if (prev == null || score > prev) bestByLabel[label] = score;
      } else {
        break;
      }
    }

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
