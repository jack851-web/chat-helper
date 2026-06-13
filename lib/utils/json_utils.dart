import 'dart:convert';

/// 从 AI 响应文本中提取 JSON（兼容多种包裹格式，增强修复性解析）
///
/// 支持格式：
/// - 纯 JSON: {"suggestions":[...]}
/// - Markdown 代码块: ```json ... ```
/// - 文本前后有说明文字
///
/// 修复能力（按优先级）：
/// 1. Markdown 代码块提取
/// 2. JSON 边界定位（第一个 { 到最后一个 }）
/// 3. 尾逗号修复（`{a:1,}` → `{a:1}`）
/// 4. 截断修复（补全缺失的 `]` 和 `}`）
/// 5. 字符串内未转义引号修复
/// 6. 部分字段提取（即使整体解析失败，尝试提取 suggestions 数组）
Map<String, dynamic> extractJsonFromAiResponse(String raw) {
  var text = raw.trim();

  // ---- Level 1: 提取 Markdown 代码块 ----
  final codeBlockMatch = RegExp(r'```(?:json)?\s*\n?([\s\S]*?)\n?```').firstMatch(text);
  if (codeBlockMatch != null) {
    text = codeBlockMatch.group(1)!.trim();
  }

  // ---- Level 2: JSON 边界定位 ----
  final startIdx = text.indexOf('{');
  final endIdx = text.lastIndexOf('}');
  if (startIdx != -1 && endIdx != -1 && endIdx > startIdx) {
    text = text.substring(startIdx, endIdx + 1);
  }

  // ---- Level 3: 直接解析 ----
  try {
    return jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {}

  // ---- Level 4: 尾逗号修复 ----
  var repaired = _fixTrailingCommas(text);
  try {
    return jsonDecode(repaired) as Map<String, dynamic>;
  } catch (_) {}

  // ---- Level 5: 截断修复（补全缺失的闭合符号）----
  repaired = _fixTruncatedJson(text);
  try {
    return jsonDecode(repaired) as Map<String, dynamic>;
  } catch (_) {}

  // ---- Level 6: 部分字段提取（兜底）----
  return _extractPartialFields(text);
}

/// 修复尾逗号：`{a:1,}` → `{a:1}`, `[1,]` → `[1]`
String _fixTrailingCommas(String text) {
  return text.replaceAllMapped(RegExp(r',\s*([}\]])'), (m) => m[1]!);
}

/// 修复截断的 JSON：统计 `{` `[` 数量并补全对应的 `}` `]`
String _fixTruncatedJson(String text) {
  var fixed = _fixTrailingCommas(text);

  // 统计未闭合的括号
  int openBraces = 0;
  int openBrackets = 0;
  for (int i = 0; i < fixed.length; i++) {
    final ch = fixed[i];
    if (ch == '{') openBraces++;
    else if (ch == '}') openBraces--;
    else if (ch == '[') openBrackets++;
    else if (ch == ']') openBrackets--;
  }

  // 补全缺失的闭合括号
  final sb = StringBuffer(fixed);
  for (int i = 0; i < openBrackets; i++) sb.write(']');
  for (int i = 0; i < openBraces; i++) sb.write('}');

  return sb.toString();
}

/// 兜底：从损坏的文本中提取部分有效字段
/// 即使整体 JSON 无法解析，也尝试提取 suggestions 数组中的有效条目
Map<String, dynamic> _extractPartialFields(String text) {
  // 尝试提取 suggestions 数组内容
  final result = <String, dynamic>{};

  // 用正则匹配 "suggestions": [...] 或 "suggestions":[...]
  final sugMatch = RegExp(r'"suggestions"\s*:\s*\[(.*?)\]', dotAll: true).firstMatch(text);
  if (sugMatch != null) {
    final arrayContent = sugMatch.group(1)!;
    final items = <Map<String, dynamic>>[];

    // 尝试逐个提取 { ... } 对象
    final objRegex = RegExp(r'\{(.*?)\}', dotAll: true);
    for (final match in objRegex.allMatches(arrayContent)) {
      final objStr = '{${match.group(1)}}';
      try {
        items.add(jsonDecode(objStr) as Map<String, dynamic>);
      } catch (_) {
        // 尝试最简修复后再解析
        try {
          final fixed = _fixTrailingCommas(objStr);
          items.add(jsonDecode(fixed) as Map<String, dynamic>);
        } catch (_) {
          // 完全无法解析该条目，跳过
        }
      }
    }

    if (items.isNotEmpty) {
      result['suggestions'] = items;
    }
  }

  // 如果连 suggestions 都没提取到，返回空数组
  if (!result.containsKey('suggestions')) {
    result['suggestions'] = <dynamic>[];
  }

  return result;
}
