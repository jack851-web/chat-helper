import 'package:flutter_test/flutter_test.dart';
import 'package:chat_helper/services/rule_engine.dart';

void main() {
  group('RuleEngine._extractContent', () {
    OcrTextBlock block(String text, {double x = 100, double y = 500}) {
      return OcrTextBlock(
        text: text,
        boundingBox: OcrRect(
          left: x,
          top: y,
          right: x + 200,
          bottom: y + 50,
        ),
      );
    }

    test('保留含有 http:// 的完整内容（不应误删冒号）', () {
      final r = RuleEngine.parse(
        blocks: [block('看这个 https://example.com/abc 很棒')],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages.length, 1);
      expect(r.messages.first.content, contains('https://example.com/abc'));
    });

    test('保留含有 "我说：你去" 这种正文中带冒号的内容', () {
      final r = RuleEngine.parse(
        blocks: [block('我说：你赶紧去吃饭')],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages.length, 1);
      expect(r.messages.first.content, '我说：你赶紧去吃饭');
    });

    test('正确去除中文全角冒号形式的昵称前缀', () {
      final r = RuleEngine.parse(
        blocks: [block('小明：今天怎么样')],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages.length, 1);
      expect(r.messages.first.content, '今天怎么样');
    });

    test('正确去除英文冒号形式的昵称前缀', () {
      final r = RuleEngine.parse(
        blocks: [block('Alice: hello world')],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages.length, 1);
      expect(r.messages.first.content, 'hello world');
    });

    test('去行首/行尾孤立时间戳', () {
      final r = RuleEngine.parse(
        blocks: [block('12:30 你好世界')],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages.length, 1);
      expect(r.messages.first.content, '你好世界');
    });

    test('空块不报错，confidence 标记为 low', () {
      final r = RuleEngine.parse(
        blocks: const [],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages, isEmpty);
      expect(r.confidence, 'low');
    });
  });

  group('RuleEngine 布局判定', () {
    OcrTextBlock block(String text, {required double x, required double y}) {
      return OcrTextBlock(
        text: text,
        boundingBox: OcrRect(
          left: x,
          top: y,
          right: x + 200,
          bottom: y + 50,
        ),
      );
    }

    test('左侧块标记为 partner', () {
      final r = RuleEngine.parse(
        blocks: [block('你好', x: 50, y: 500)],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages.length, 1);
      expect(r.messages.first.speaker, 'partner');
    });

    test('右侧块标记为 me', () {
      final r = RuleEngine.parse(
        blocks: [block('我很好', x: 800, y: 500)],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages.length, 1);
      expect(r.messages.first.speaker, 'me');
    });

    test('状态栏附近的文字被过滤', () {
      final r = RuleEngine.parse(
        blocks: [block('Wi-Fi 4G', x: 500, y: 20)],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages, isEmpty);
    });

    test('底部输入栏附近的文字被过滤', () {
      final r = RuleEngine.parse(
        blocks: [block('输入消息...', x: 500, y: 2350)],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages, isEmpty);
    });

    test('系统消息被识别并过滤', () {
      final r = RuleEngine.parse(
        blocks: [block('对方撤回了一条消息', x: 500, y: 1000)],
        screenWidth: 1080,
        screenHeight: 2400,
      );
      expect(r.messages, isEmpty);
    });
  });
}
