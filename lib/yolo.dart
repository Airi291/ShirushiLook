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

  /// 右上HUDなどで使う簡易デバッグ行（処理時間・ヒット数・上位3件）
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

    final options = InterpreterOptions()..threads = 2;
    try {
      if (Platform.isAndroid) {
        options.addDelegate(GpuDelegateV2());
        debugPrint('[YOLO] GPU delegate enabled');
      } else if (Platform.isIOS) {
        debugPrint('[YOLO] iOS: CPU 使用');
      } else if (Platform.isMacOS) {
        debugPrint('[YOLO] macOS: CPU 使用');
      }
    } catch (e) {
      debugPrint('[YOLO] delegate setup failed: $e (CPU継続)');
    }

    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float32.tflite',
        options: options,
      );
    } catch (e) {
      debugPrint(
          '[YOLO] Interpreter init failed with delegate: $e — retry CPU only');
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float32.tflite',
        options: InterpreterOptions()..threads = 2,
      );
    }

    // ★ ここを追加：入力テンソル形状を [1,640,640,3] に固定してから allocate
    final want = [1, 640, 640, 3];
    final cur = _interpreter.getInputTensor(0).shape;
    if (!listEquals(cur, want)) {
      debugPrint('[YOLO] resize input $cur -> $want');
      _interpreter.resizeInputTensor(0, want);
    }
    _interpreter.allocateTensors();

    // モデル情報ログ
    try {
      final inT = _interpreter.getInputTensor(0);
      final outT = _interpreter.getOutputTensor(0);
      debugPrint('=== YOLO MODEL INFO ===\n'
          'input=${inT.shape}(${inT.type}) / output=${outT.shape}(${outT.type}) / labels=${_labels.length}\n'
          '=======================');
    } catch (_) {}

    isReady = true;
  }

  // RGB 0–255 → [1,640,640,3] float32(0–1)
  Float32List _preprocess(Uint8List rgbBytes, int srcW, int srcH) {
    final rgbImg = img.Image.fromBytes(
      width: srcW,
      height: srcH,
      bytes: rgbBytes.buffer,
      rowStride: srcW * 3,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );

    final resized = img.copyResize(rgbImg, width: 640, height: 640);

    final out = Float32List(640 * 640 * 3);
    int i = 0;
    double mean = 0.0;
    for (var y = 0; y < 640; y++) {
      for (var x = 0; x < 640; x++) {
        final p = resized.getPixel(x, y);
        final r = p.r / 255.0;
        final g = p.g / 255.0;
        final b = p.b / 255.0;
        out[i++] = r;
        out[i++] = g;
        out[i++] = b;
        mean += (r + g + b) / 3.0;
      }
    }
    mean /= (out.length / 3);
    lastDebugLine = 'pre_mean=${mean.toStringAsFixed(3)}';
    return out;
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

  // lib/yolo.dart の runFrame を差し替え
  List<String> runFrame(
    Uint8List rgbBytes,
    int srcW,
    int srcH, {
    double threshold = 0.65,
  }) {
    if (!isReady) return [];

    // 前処理：RGB → 640x640 float32 [0,1] フラット
    final swPre = Stopwatch()..start();
    final Float32List inputFlat = _preprocess(rgbBytes, srcW, srcH);
    swPre.stop();

    // 出力テンソル形状（期待: [1,25,8400]）
    final outT = _interpreter.getOutputTensor(0);
    final outShape = outT.shape;
    if (outShape.length != 3 || outShape[0] != 1 || outShape[1] < 5) {
      lastDebugLine = 'bad shape: $outShape | $lastDebugLine';
      return [];
    }
    final int b = outShape[0]; // 1
    final int cDim = outShape[1]; // 25 (=4+21)
    final int nBox = outShape[2]; // 8400
    final int numClasses = cDim - 4;

    // ===== 入力 [1,640,640,3]（最内層は Float32List(3) のままでOK）=====
    final List<List<List<Float32List>>> input4d =
        List<List<List<Float32List>>>.generate(
      1,
      (_) => List<List<Float32List>>.generate(
        640,
        (y) => List<Float32List>.generate(
          640,
          (x) {
            final base = (y * 640 + x) * 3;
            final f = Float32List(3);
            f[0] = inputFlat[base + 0];
            f[1] = inputFlat[base + 1];
            f[2] = inputFlat[base + 2];
            return f;
          },
          growable: false,
        ),
        growable: false,
      ),
      growable: false,
    );

    // ===== 出力 [1, cDim, nBox]（最内層は List<double> にする！）=====
    final List<List<List<double>>> output = List<List<List<double>>>.generate(
      b, // =1
      (_) => List<List<double>>.generate(
        cDim,
        (_) => List<double>.filled(nBox, 0.0, growable: false),
        growable: false,
      ),
      growable: false,
    );

    // 推論
    final swInfer = Stopwatch()..start();
    _interpreter.run(input4d, output);
    swInfer.stop();

    // 後処理
    final swPost = Stopwatch()..start();
    double sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

    double minLogit = double.infinity, maxLogit = -double.infinity;
    final scored = <(int boxIdx, int classIdx, double score)>[];

    for (int i = 0; i < nBox; i++) {
      double best = -1.0;
      int bestIdx = -1;
      for (int c = 0; c < numClasses; c++) {
        final double logit = output[0][4 + c][i]; // [batch=0][class][index]
        if (logit < minLogit) minLogit = logit;
        if (logit > maxLogit) maxLogit = logit;
        final p = sigmoid(logit);
        if (p > best) {
          best = p;
          bestIdx = c;
        }
      }
      if (bestIdx >= 0) scored.add((i, bestIdx, best));
    }

    // スコア降順 & ラベル別最高のみ
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
        'logit=[${minLogit.toStringAsFixed(2)},${maxLogit.toStringAsFixed(2)}] '
        'top3=${top3Dbg.join(", ")} | $preMeanLine';

    return unique.toList();
  }
}
