// lib/yolo.dart
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

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
      } else {
        debugPrint('[YOLO] iOS: CPU 使用');
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

  /// 出力 shape = [1, 25, 8400] を想定
  /// 閾値は一旦 0.15 に下げて様子見（後で上げ戻す）
// lib/yolo.dart の runFrame を丸ごと置き換え
  /// 出力 shape = [1, 25, 8400] を想定（= 4 + 21クラス）
  List<String> runFrame(
    Uint8List rgbBytes,
    int srcW,
    int srcH, {
    double threshold = 0.65,
  }) {
    if (!isReady) return [];

    // === 計測 ===
    final swPre = Stopwatch()..start();
    final input = _preprocess(
        rgbBytes, srcW, srcH); // pre_mean は _preprocess 内で lastDebugLine に入る
    swPre.stop();

    // 出力 shape
    final outT = _interpreter.getOutputTensor(0);
    final outShape = outT.shape; // 期待: [1,25,8400]
    if (outShape.length != 3 || outShape[1] < 5) {
      lastDebugLine = 'bad shape: $outShape | $lastDebugLine';
      return [];
    }
    final cDim = outShape[1]; // 25
    final nBox = outShape[2]; // 8400
    final numClasses = cDim - 4; // 21

    // 受け皿（ListでOK）
    final output = List.generate(
      1,
      (_) => List.generate(
        cDim,
        (_) => List<double>.filled(nBox, 0.0),
      ),
    );

    // 推論
    final swInfer = Stopwatch()..start();
    _interpreter.run(
      input.buffer.asFloat32List().reshape([1, 640, 640, 3]),
      output,
    );
    swInfer.stop();

    // 後処理
    final swPost = Stopwatch()..start();

    // logit 範囲を見る（ゼロ地獄チェック）
    double minLogit = double.infinity, maxLogit = -double.infinity;
    for (int i = 0; i < nBox; i++) {
      for (int c = 0; c < numClasses; c++) {
        final v = output[0][4 + c][i];
        if (v < minLogit) minLogit = v;
        if (v > maxLogit) maxLogit = v;
      }
    }

    // obj なしモデル想定：各クラスに sigmoid
    double sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

    final scored = <(int boxIdx, int classIdx, double score)>[];
    for (int i = 0; i < nBox; i++) {
      double best = -1;
      int bestIdx = -1;
      for (int c = 0; c < numClasses; c++) {
        final logit = output[0][4 + c][i];
        final prob = sigmoid(logit);
        if (prob > best) {
          best = prob;
          bestIdx = c;
        }
      }
      if (bestIdx >= 0) scored.add((i, bestIdx, best));
    }

    // スコア順
    scored.sort((a, b) => b.$3.compareTo(a.$3));

    // 各クラス名ごとの最高スコアを集計（threshold もここで適用）
    final Map<String, double> bestByLabel = {};
    for (final s in scored) {
      final idx = s.$2;
      if (idx < 0 || idx >= _labels.length) continue;
      final label = _labels[idx];
      final score = s.$3;
      if (score >= threshold) {
        final prev = bestByLabel[label];
        if (prev == null || score > prev) bestByLabel[label] = score;
      } else {
        // 以降はスコアが下がるので打ち切り（任意）
        break;
      }
    }

    // UI で使う上位表示用ソート済みリストを保存
    lastTop = bestByLabel.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 返却用（ユニークなラベル一覧）
    final unique = bestByLabel.keys.toSet();

    // デバッグ用 top3 表示
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
