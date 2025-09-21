// lib/yolo.dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'dart:math' as math;
import 'dart:io' show Platform;

class YoloService {
  bool isReady = false;
  late Interpreter _interpreter;
  late List<String> _labels;

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
        options.addDelegate(GpuDelegateV2()); // AndroidのみGPU
        debugPrint('[YOLO] GPU delegate enabled');
      } else {
        debugPrint('[YOLO] iOS: CPU 使用'); // iOSはまずCPUで安定化
      }
    } catch (e) {
      debugPrint('[YOLO] delegate setup failed: $e (CPU継続)');
    }

    try {
      _interpreter = await Interpreter.fromAsset(
          'assets/models/best_float32.tflite',
          options: options);
    } catch (e) {
      // 最終フォールバック（CPU）
      debugPrint(
          '[YOLO] Interpreter init failed with delegate: $e — retry CPU only');
      _interpreter = await Interpreter.fromAsset(
          'assets/models/best_float32.tflite',
          options: InterpreterOptions()..threads = 2);
    }

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
      numChannels: 3,
    );

    final resized = img.copyResize(rgbImg, width: 640, height: 640);

    final out = Float32List(640 * 640 * 3);
    int i = 0;
    for (var y = 0; y < 640; y++) {
      for (var x = 0; x < 640; x++) {
        final p = resized.getPixel(x, y);
        out[i++] = p.r / 255.0;
        out[i++] = p.g / 255.0;
        out[i++] = p.b / 255.0;
      }
    }
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

  double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

  /// 出力 shape = [1, 25, 8400] を想定（= [x,y,w,h, 21クラス(ロジット)] × 8400）
  List<String> runFrame(
    Uint8List rgbBytes,
    int srcW,
    int srcH, {
    double threshold = 0.65,
  }) {
    if (!isReady) return [];

    // 前処理
    final input = _preprocess(rgbBytes, srcW, srcH);

    // 出力 shape 確認
    final outT = _interpreter.getOutputTensor(0);
    final outShape = outT.shape; // 例: [1, 25, 8400]
    if (outShape.length != 3 || outShape[1] < 5) {
      debugPrint('[YOLO] Unexpected output shape: $outShape');
      return [];
    }

    final channels = outShape[1]; // 25 = 4 + numClasses(=21)
    final boxes = outShape[2]; // 8400
    final numClasses = channels - 4;

    // 受け皿
    final output = List.generate(
      1,
      (_) => List.generate(
        channels,
        (_) => List<double>.filled(boxes, 0.0),
      ),
    );

    // 推論実行
    _interpreter.run(
      input.buffer.asFloat32List().reshape([1, 640, 640, 3]),
      output,
    );

// --- 後処理 ---
// softmax 関数（obj なしモデル用）
    List<double> _softmax(List<double> xs) {
      final m = xs.reduce((a, b) => a > b ? a : b);
      final exps = xs.map((x) => math.exp(x - m)).toList();
      final sum = exps.fold(0.0, (a, b) => a + b);
      return exps.map((e) => e / sum).toList();
    }

    final scored = <(int boxIdx, int classIdx, double score)>[];
    for (var i = 0; i < boxes; i++) {
      // ★ obj なしなので softmax を使う
      final logits =
          List<double>.generate(numClasses, (c) => output[0][4 + c][i]);
      final probs = _softmax(logits);

      // 一番確率の高いクラスだけ採用
      double best = -1;
      int bestIdx = -1;
      for (var c = 0; c < numClasses; c++) {
        if (probs[c] > best) {
          best = probs[c];
          bestIdx = c;
        }
      }
      if (bestIdx >= 0) {
        scored.add((i, bestIdx, best));
      }
    }

// スコア順に上位を使う
    scored.sort((a, b) => b.$3.compareTo(a.$3));
    final topK = scored.take(100);

// 閾値以上だけ返す
    final results = <String>{};
    for (final s in topK) {
      if (s.$3 >= threshold) {
        final idx = s.$2;
        if (idx >= 0 && idx < _labels.length) {
          results.add(_labels[idx]);
        }
      }
    }

    return results.toList();
  }
}
