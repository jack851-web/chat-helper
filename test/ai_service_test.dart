import 'package:flutter_test/flutter_test.dart';
import 'package:chat_helper/services/ai_service.dart';

void main() {
  group('AiService.extractJson', () {
    test('解析纯 JSON 对象', () {
      const input = '{"suggestions": [{"style": "热情", "content": "好的"}]}';
      final out = AiService.extractJson(input);
      expect(out, isNotNull);
      expect(out, contains('"suggestions"'));
    });

    test('从 markdown 代码块中提取 JSON', () {
      const input = '```json\n{"a": 1, "b": [1, 2]}\n```';
      final out = AiService.extractJson(input);
      expect(out, isNotNull);
      expect(out, contains('"a"'));
    });

    test('从带解释文字 + JSON 的混合输出中提取', () {
      const input = '好的以下是建议：\n{"x": 1}\n请参考。';
      final out = AiService.extractJson(input);
      expect(out, '{"x": 1}');
    });

    test('含嵌套大括号时正确匹配到末尾', () {
      const input = '前缀 {"a": {"b": 2}} 后缀';
      final out = AiService.extractJson(input);
      expect(out, '{"a": {"b": 2}}');
    });

    test('无大括号时返回 null', () {
      const input = '没有任何 JSON';
      expect(AiService.extractJson(input), isNull);
    });

    test('不闭合的括号返回 null', () {
      const input = '{"a": 1';
      expect(AiService.extractJson(input), isNull);
    });

    test('空字符串返回 null', () {
      expect(AiService.extractJson(''), isNull);
    });

    test('含字符串内的大括号不算嵌套', () {
      // "a {b} c" 中的 } 是字符串字面量，整体 JSON 应到最外层 } 结束
      const input = '{"k": "value with { and } inside"}';
      final out = AiService.extractJson(input);
      expect(out, input);
    });
  });
}
