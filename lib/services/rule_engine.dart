import 'dart:convert';
import '../utils/constants.dart';

/// OCR文字块(带坐标) → 规则分类左右 → 按Y坐标排序 → 输出JSON
class RuleEngine {
  /// 解析OCR识别结果，生成结构化聊天记录
  static ParsedChatResult parse({
    required List<OcrTextBlock> blocks,
    required double screenWidth,
    required double screenHeight,
  }) {
    if (blocks.isEmpty) {
      return ParsedChatResult(messages: [], confidence: 'low',
          warning: 'OCR未识别到任何文字');
    }

    const statusBarEstimate = 80.0; // 状态栏高度估算(dp)
    const inputBarEstimate = 120.0; // 底部输入栏高度估算(dp)
    final midlineX = screenWidth * AppConstants.midlineThreshold;
    final midXRange = screenWidth * 0.15; // 居中判定范围

    final parsed = <ParsedMessage>[];
    int leftCount = 0;
    int rightCount = 0;
    int centerCount = 0;

    for (final block in blocks) {
      // 过滤非聊天区域
      if (block.boundingBox.top < statusBarEstimate) continue;
      if (block.boundingBox.top > screenHeight - inputBarEstimate) continue;

      final cx = block.boundingBox.center.dx;

      // 系统消息检测
      if (_isSystemMessage(block)) continue;

      // 判定说话人
      String speaker;
      if ((cx - midlineX).abs() < midXRange) {
        speaker = 'system';
        centerCount++;
      } else if (cx > midlineX) {
        speaker = 'me';
        rightCount++;
      } else {
        speaker = 'partner';
        leftCount++;
      }

      if (speaker == 'system') continue;

      final content = _extractContent(block.text);
      final timestamp = _extractTimestamp(block.text);

      if (content.isNotEmpty) {
        parsed.add(ParsedMessage(
          speaker: speaker,
          content: content,
          timestamp: timestamp,
          y: block.boundingBox.top,
        ));
      }
    }

    // 按垂直位置排序
    parsed.sort((a, b) => a.y.compareTo(b.y));

    // 合并相邻同说话人
    final merged = _mergeAdjacent(parsed);

    // 置信度评估
    final total = leftCount + rightCount;
    String confidence = 'high';
    String? warning;
    if (total == 0) {
      confidence = 'low';
      warning = '未检测到标准聊天气泡布局';
    } else if (centerCount > total * 0.5) {
      confidence = 'low';
      warning = '大量居中对齐文本，可能非标准聊天App';
    } else if (leftCount == 0 || rightCount == 0) {
      confidence = 'low';
      warning = '仅检测到单侧对话，可能布局解析异常';
    }

    return ParsedChatResult(
      messages: merged,
      confidence: confidence,
      warning: warning,
    );
  }

  static bool _isSystemMessage(OcrTextBlock block) {
    final text = block.text.trim();
    const sysPatterns = [
      '撤回了一条消息',
      '加入了群聊',
      '退出了群聊',
      '修改群名为',
      '以上是打招呼的内容',
      '对方正在输入',
      '你已添加了',
    ];
    for (final p in sysPatterns) {
      if (text.contains(p)) return true;
    }
    return false;
  }

  /// 提取纯聊天文本（去时间戳、去昵称前缀）
  static String _extractContent(String rawText) {
    var text = rawText.trim();
    // 只去除行首/行尾的孤立时间戳
    text = text.replaceAll(RegExp(r'^\d{1,2}:\d{2}\s*'), '');
    text = text.replaceAll(RegExp(r'\s*\d{1,2}:\d{2}$'), '');
    // 去掉昵称前缀：仅当整行恰好 1 个 [：:]、冒号前 1-12 字符内无空白
    // 且冒号后还有内容（不是孤立的"姓名："）时才剥离。
    // 避免误删正文中的 "http://"、"我说：你去" 等含冒号的内容
    final colonCount = RegExp(r'[：:]').allMatches(text).length;
    if (colonCount == 1) {
      final colonMatch = RegExp(r'^(\S{1,12})[：:](.*)$').firstMatch(text);
      if (colonMatch != null) {
        final prefix = colonMatch.group(1)!;
        final rest = colonMatch.group(2)!;
        // 启发式判定 prefix 更像昵称而非正文：
        // 1) 不能含 URL 特征或连续数字串
        // 2) 长度必须 <=8 字符（昵称通常较短）
        // 3) 整段是代词/动词（"我"、"你说"、"他说"、"我觉得"）不算昵称
        const pronouns = {'我', '你', '他', '她', '它', '我们', '你们', '他们',
                           '她们', '这', '那', '这里', '那里', '这些', '那些'};
        const verbs = {'说', '讲', '问', '答', '想', '觉得', '认为', '以为', '感觉'};
        // 代词开头（"我说" "你觉得" "他问"）：前 1-2 字符必须是代词
        final prefixRunes = prefix.runes.toList();
        final firstChar = prefixRunes.isNotEmpty
            ? String.fromCharCode(prefixRunes.first)
            : '';
        final firstTwo = prefixRunes.length >= 2
            ? String.fromCharCode(prefixRunes[0]) +
                String.fromCharCode(prefixRunes[1])
            : '';
        final isAllPronounOrVerb = pronouns.contains(prefix) || verbs.contains(prefix);
        final startsWithPronoun =
            pronouns.contains(firstChar) || pronouns.contains(firstTwo);
        final isLikelyName = !prefix.contains(RegExp(r'[/\\@]')) &&
            !RegExp(r'\d{2,}').hasMatch(prefix) &&
            prefix.runes.length <= 8 &&
            rest.trim().isNotEmpty &&
            !isAllPronounOrVerb &&
            !startsWithPronoun;
        if (isLikelyName) {
          text = rest.trim();
        }
      }
    }
    return text;
  }

  static String? _extractTimestamp(String text) {
    final match = RegExp(r'(\d{1,2}:\d{2})').firstMatch(text);
    return match?.group(1);
  }

  static List<ParsedMessage> _mergeAdjacent(List<ParsedMessage> messages) {
    if (messages.isEmpty) return messages;

    final merged = <ParsedMessage>[];
    ParsedMessage? current;

    for (final msg in messages) {
      if (current == null) {
        current = ParsedMessage(
          speaker: msg.speaker,
          content: msg.content,
          timestamp: msg.timestamp,
          y: msg.y,
        );
      } else if (current.speaker == msg.speaker &&
          (msg.y - current.y) < 120) {
        // 同一说话人，智能合并（避免重复标点）
        final needsSep = !current.content.endsWith('.') &&
            !current.content.endsWith('。') &&
            !current.content.endsWith('！') &&
            !current.content.endsWith('？') &&
            !current.content.endsWith('?') &&
            !current.content.endsWith('!');
        current = ParsedMessage(
          speaker: current.speaker,
          content: needsSep
              ? '${current.content}。${msg.content}'
              : '${current.content}${msg.content}',
          timestamp: current.timestamp ?? msg.timestamp,
          y: current.y,
        );
      } else {
        merged.add(current);
        current = ParsedMessage(
          speaker: msg.speaker,
          content: msg.content,
          timestamp: msg.timestamp,
          y: msg.y,
        );
      }
    }
    if (current != null) merged.add(current);

    if (merged.length > AppConstants.maxExtractMessages) {
      return merged.sublist(merged.length - AppConstants.maxExtractMessages);
    }
    return merged;
  }
}

// ---- 数据类型（使用独立命名避免与 dart:ui 冲突） ----

class OcrTextBlock {
  final String text;
  final OcrRect boundingBox;

  OcrTextBlock({required this.text, required this.boundingBox});
}

class OcrRect {
  final double left;
  final double top;
  final double right;
  final double bottom;

  OcrRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get width => right - left;
  double get height => bottom - top;
  OcrPoint get center => OcrPoint((left + right) / 2, (top + bottom) / 2);
}

class OcrPoint {
  final double dx;
  final double dy;
  const OcrPoint(this.dx, this.dy);
}

class ParsedMessage {
  final String speaker;
  final String content;
  final String? timestamp;
  final double y;

  ParsedMessage({
    required this.speaker,
    required this.content,
    this.timestamp,
    required this.y,
  });

  Map<String, dynamic> toJson() => {
        'speaker': speaker,
        'content': content,
        'timestamp': timestamp,
      };
}

class ParsedChatResult {
  final List<ParsedMessage> messages;
  final String confidence;
  final String? warning;

  ParsedChatResult({
    required this.messages,
    required this.confidence,
    this.warning,
  });

  Map<String, dynamic> toJson() => {
        'messages': messages.map((m) => m.toJson()).toList(),
        'message_count': messages.length,
        'parse_confidence': confidence,
        if (warning != null) 'warning': warning,
      };

  String toJsonString() => jsonEncode(toJson());
}
