// lib/yolo.dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart' show rootBundle;

class YoloService {
  bool isReady = false;
  late Interpreter _interpreter;
  late List<String> _labels;

  Future<void> loadModel() async {
    // ラベル読込だけ先に（軽い）
    final raw = await rootBundle.loadString('assets/labels_mtsd21.txt');
    _labels = raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // まずは GPU をトライ、ダメなら CPU に自動フォールバック
    final options = InterpreterOptions()..threads = 2;
    try {
      // iOS/Android 共通：GPU Delegate
      options.addDelegate(GpuDelegateV2());
      debugPrint('[YOLO] Try GPU delegate');
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float32.tflite',
        options: options,
      );
      debugPrint('[YOLO] GPU delegate enabled');
    } catch (e) {
      debugPrint('[YOLO] GPU delegate failed: $e');
      // GPU が使えなければ CPU で再作成
      final cpuOptions = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float32.tflite',
        options: cpuOptions,
      );
      debugPrint('[YOLO] CPU fallback enabled');
    }

    isReady = true;
  }

  // まずはダミー
  List<String> runMock(Uint8List bytes) => ["stop", "speed_limit"];
}
