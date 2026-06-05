import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'rule_engine.dart';

class OcrService {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.chinese);

  /// 从图片文件执行OCR，返回带坐标的识别结果
  Future<OcrResult> recognize(File imageFile, double screenWidth,
      double screenHeight) async {
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final visionText = await _recognizer.processImage(inputImage);

      final blocks = <OcrTextBlock>[];
      for (final block in visionText.blocks) {
        final rect = block.boundingBox;

        // 合并该block内所有行
        final lines = block.lines.map((l) => l.text).join(' ');

        blocks.add(OcrTextBlock(
          text: lines,
          boundingBox: OcrRect(
            left: rect.left.toDouble(),
            top: rect.top.toDouble(),
            right: rect.right.toDouble(),
            bottom: rect.bottom.toDouble(),
          ),
        ));
      }

      final parsed = RuleEngine.parse(
        blocks: blocks,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
      );

      return OcrResult(
        blocks: blocks,
        parsedChat: parsed,
      );
    } catch (e) {
      return OcrResult(
        blocks: [],
        parsedChat: ParsedChatResult(
          messages: [],
          confidence: 'low',
          warning: 'OCR识别异常 (${e.runtimeType})',
        ),
      );
    }
  }

  void dispose() {
    _recognizer.close();
  }
}

class OcrResult {
  final List<OcrTextBlock> blocks;
  final ParsedChatResult parsedChat;

  OcrResult({required this.blocks, required this.parsedChat});
}
