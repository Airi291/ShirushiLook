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

  /// 出力 shape = [1, 25, 8400] を想定（= [x,y,w,h, 21クラス] × 8400）
  double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

  List<String> runFrame(
    Uint8List rgbBytes,
    int srcW,
    int srcH, {
    double threshold = 0.50,
  }) {
    if (!isReady) return [];

    final input = _preprocess(rgbBytes, srcW, srcH);
    final inputTensor = input.buffer.asFloat32List().reshape([1, 640, 640, 3]);

    // ✅ 出力テンソルの一覧を取得（個数=length）
    final outTensors = _interpreter.getOutputTensors();
    if (outTensors.isEmpty) {
      debugPrint('[YOLO] No output tensors');
      return [];
    }

    // ✅ ここに run のための出力バッファ（Map<int, Object>）を作る
    final Map<int, Object> outBuffers = {};
    // 後で読み出すために shape と合わせて保管
    final List<({int index, List<int> shape, Object buf})> views = [];

    for (var i = 0; i < outTensors.length; i++) {
      final t = outTensors[i];
      final shape = t.shape; // 例: [1, 26, 8400] / [1, 8400, 26] など

      if (shape.length != 3) {
        // 3次元以外はスキップ（PostProcess付きモデルは別処理にする）
        continue;
      }
      final b = shape[0];
      final a = shape[1];
      final c = shape[2];

      // ✅ shape に合わせた3次元のListを用意（batch=1想定）
      final buf = List.generate(
        b,
        (_) => List.generate(a, (_) => List<double>.filled(c, 0.0)),
      );

      outBuffers[i] = buf;
      views.add((index: i, shape: shape, buf: buf));
    }

    if (outBuffers.isEmpty) {
      debugPrint('[YOLO] No usable 3D outputs');
      return [];
    }

    // ✅ 推論（入力はList、出力はMap<int,Object>）
    _interpreter.runForMultipleInputs([inputTensor], outBuffers);

    final labels = _labels;
    final found = <String, double>{};

    double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

    void consumeOneOutput(List<int> shape, Object buf) {
      // buf は List[batch][A][B] 構造
      final batch = buf as List; // 長さ=1想定
      final mat = batch[0] as List; // 長さ=A
      final A = shape[1];
      final B = shape[2];

      // mat は List<List<double>> のはず（[A][B]）
      final out = List<List<double>>.from(
        List.generate(A, (i) => List<double>.from(mat[i] as List)),
      );

      // どっちがD(=4+1+classes)で、どっちがN(=boxes)かを判定
      final Dwant = 4 + 1 + labels.length;
      final candidates = <({int D, int N, bool trans})>[];

      if (A == Dwant && B > A)
        candidates.add((D: A, N: B, trans: false)); // [D,N]
      if (B == Dwant && A > B)
        candidates.add((D: B, N: A, trans: true)); // [N,D]

      if (candidates.isEmpty) {
        if (A < B && A >= 5) candidates.add((D: A, N: B, trans: false));
        if (B < A && B >= 5) candidates.add((D: B, N: A, trans: true));
      }
      if (candidates.isEmpty) {
        debugPrint('[YOLO] Unrecognized output shape [1,$A,$B], skip');
        return;
      }

      final cand = candidates.first;
// 置き換え：クラススコア計算部だけ差し替え
      final D = cand.D;
      final N = cand.N;
      double at(int d, int n) => cand.trans ? out[n][d] : out[d][n];

// D == 4 + classes なら obj なし
      final bool noObj = (D == 4 + labels.length);
      final int classStart = noObj ? 4 : 5;
      final int numClasses = D - classStart;

      for (var i = 0; i < N; i++) {
        // obj ありモデルなら sigmoid(obj)、なしなら 1.0
        final double obj = noObj ? 1.0 : _sigmoid(at(4, i));

        double bestScore = -1;
        int bestCls = -1;

        for (var c = 0; c < numClasses; c++) {
          final clsProb = _sigmoid(at(classStart + c, i));
          final score = obj * clsProb; // objなしなら = clsProb
          if (score > bestScore) {
            bestScore = score;
            bestCls = c;
          }
        }

        if (bestCls >= 0 && bestCls < labels.length && bestScore >= threshold) {
          final name = labels[bestCls];
          if (bestScore > (found[name] ?? -1)) found[name] = bestScore;
        }
      }
    }

    for (final v in views) {
      consumeOneOutput(v.shape, v.buf);
    }

    final sorted = found.keys.toList()
      ..sort((a, b) => (found[b]!).compareTo(found[a]!));
    return sorted;
  }
}
