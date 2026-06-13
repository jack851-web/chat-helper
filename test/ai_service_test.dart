import 'package:flutter_test/flutter_test.dart';
import 'package:chat_helper/utils/json_utils.dart';

void main() {
  group('extractJsonFromAiResponse', () {
    test('解析纯 JSON 对象', () {
      const input = '{"suggestions": [{"style": "热情", "content": "好的"}]}';
      final out = extractJsonFromAiResponse(input);
      expect(out, containsPair('suggestions', isA<List>()));
    });

    test('从 markdown 代码块中提取 JSON', () {
      const input = '```json\n{"a": 1, "b": [1, 2]}\n```';
      final out = extractJsonFromAiResponse(input);
      expect(out, containsPair('a', 1));
    });

    test('从带解释文字 + JSON 的混合输出中提取', () {
      const input = '好的以下是建议：\n{"x": 1}\n请参考。';
      final out = extractJsonFromAiResponse(input);
      expect(out, containsPair('x', 1));
    });

    test('含嵌套大括号时正确匹配到末尾', () {
      const input = '前缀 {"a": {"b": 2}} 后缀';
      final out = extractJsonFromAiResponse(input);
      expect(out, containsPair('a', isA<Map>()));
    });

    test('无效输入返回非 null 的兜底 map（包含空 suggestions）', () {
      const input = '没有任何 JSON';
      final out = extractJsonFromAiResponse(input);
      expect(out, isNotNull);
      expect(out, isA<Map<String, dynamic>>());
      // 兜底结构：含空 suggestions 列表，保证调用方不会 NPE
      expect(out['suggestions'], isA<List>());
      expect(out['suggestions'], isEmpty);
    });

    test('不闭合的括号返回兜底 map', () {
      const input = '{"a": 1';
      final out = extractJsonFromAiResponse(input);
      expect(out, isNotNull);
      expect(out['suggestions'], isA<List>());
    });

    test('空字符串返回兜底 map', () {
      final out = extractJsonFromAiResponse('');
      expect(out, isNotNull);
      expect(out['suggestions'], isA<List>());
    });

    test('含字符串内的大括号正确解析', () {
      const input = '{"k": "value with { and } inside"}';
      final out = extractJsonFromAiResponse(input);
      expect(out, containsPair('k', 'value with { and } inside'));
    });
  });
}
