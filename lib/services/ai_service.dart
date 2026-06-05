import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';

enum AiErrorKind { network, auth, quota, parse, notConfigured, unknown }

class AiException implements Exception {
  final AiErrorKind kind;
  final String userMessage;
  final int? httpStatus;
  final Object? cause;
  const AiException(this.kind, this.userMessage, {this.httpStatus, this.cause});

  @override
  String toString() => 'AiException($kind, $userMessage)';
}

/// DeepSeek AI 服务 — 无状态 API，每次请求由客户端自行拼接完整 messages[]。
class AiService {
  static const _prefsModelKey = 'ai2_model';
  static const _prefsCloudFallbackKey = 'cloud_fallback_enabled';
  static const _secureApiKeyKey = 'ai_api_key';

  /// 固定 Base URL（DeepSeek 官方地址，无 v1 后缀）
  static const baseUrl = 'https://api.deepseek.com';

  late SharedPreferences _prefs;
  final _secureStorage = const FlutterSecureStorage();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ---- 配置 ----

  static const _validModels = {'deepseek-v4-pro', 'deepseek-chat', 'deepseek-reasoner'};

  String get model {
    final v = _prefs.getString(_prefsModelKey);
    return (v != null && _validModels.contains(v)) ? v : 'deepseek-v4-pro';
  }
  set model(String v) => _prefs.setString(_prefsModelKey, v);

  Future<String?> get apiKey async =>
      await _secureStorage.read(key: _secureApiKeyKey);

  Future<void> setApiKey(String? v) async {
    if (v != null && v.isNotEmpty) {
      await _secureStorage.write(key: _secureApiKeyKey, value: v);
    } else {
      await _secureStorage.delete(key: _secureApiKeyKey);
    }
  }

  Future<String?> getCachedApiKey() async =>
      await _secureStorage.read(key: _secureApiKeyKey);

  bool get cloudFallbackEnabled =>
      _prefs.getBool(_prefsCloudFallbackKey) ?? true;
  set cloudFallbackEnabled(bool v) =>
      _prefs.setBool(_prefsCloudFallbackKey, v);

  Future<bool> get isConfigured async {
    final key = await apiKey;
    return key != null && key.isNotEmpty;
  }

  // ==================== AI-2: DeepSeek 建议 ====================

  /// 将 OCR 解析结果转为 DeepSeek messages[] 格式。
  /// partner → "user", me → "assistant"
  static List<Map<String, String>> buildMessages(
      List<Map<String, String>> parsedMessages) {
    final out = <Map<String, String>>[];
    for (final m in parsedMessages) {
      final speaker = m['speaker'] ?? '';
      final content = m['content'] ?? '';
      if (content.isEmpty) continue;
      if (speaker == 'partner') {
        out.add({'role': 'user', 'content': content});
      } else if (speaker == 'me') {
        out.add({'role': 'assistant', 'content': content});
      }
    }
    return out;
  }

  /// 结构化 context：partner 消息 → "user", me 消息 → "assistant"
  /// 不含 system message，由本方法内部添加。
  Future<AiSuggestionResult> generateSuggestions({
    required List<Map<String, String>> historyMessages,
    required String tone,
    required String length,
    required double creativity,
  }) async {
    final key = await apiKey;
    if (key == null || key.isEmpty) {
      return AiSuggestionResult(
        suggestions: const [],
        error: const AiException(
          AiErrorKind.notConfigured,
          '请先在设置中配置 DeepSeek API Key',
        ),
      );
    }

    final systemPrompt = '''你是一个高情商社交助手Chat-Helper。
你的任务是根据聊天历史，为用户生成3条不同风格的回复建议。

规则:
1. 回复语气: $tone
2. 回复长度: $length
3. 创意程度: ${(creativity * 10).round()}/10
4. 每条建议使用不同的风格（如热情、幽默、稳妥、直白、温柔）
5. 每条建议附带简短的推荐理由
6. 回复要自然、有"人味"，避免AI腔
7. 最后一轮 user 消息是需要你生成回复的"最新消息"

请严格按以下JSON格式输出（不要包含其他文字）:
{
  "suggestions": [
    {
      "style": "热情",
      "content": "回复话术内容",
      "reason": "推荐理由"
    }
  ]
}''';

    // 构建 messages[]：system + 历史对话 (user/assistant 交替)
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
    ];
    for (final m in historyMessages) {
      messages.add(m);
    }

    return _safeSuggest(() async {
      final response = await http
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': model,
              'messages': messages,
              'temperature': 0.3 + creativity * 0.6,
              'max_tokens': 1024,
            }),
          )
          .timeout(
            const Duration(seconds: AppConstants.apiTimeoutSeconds),
          );

      if (response.statusCode == 200) {
        return _parseSuggestionsResponse(response.body);
      }
      throw _httpError(response.statusCode, response.body);
    });
  }

  // ==================== 云端兜底解析 ====================

  Future<ParsedChatFallback?> cloudFallbackParse(String rawOcrText) async {
    if (!cloudFallbackEnabled) return null;
    final key = await apiKey;
    if (key == null || key.isEmpty) return null;

    final result = await _safeCall<ParsedChatFallback>(() async {
      final response = await http
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {
                  'role': 'system',
                  'content': '你是一个聊天记录解析器。将OCR识别的聊天文本解析为JSON。',
                },
                {
                  'role': 'user',
                  'content':
                      '请将以下OCR识别的聊天文本解析为JSON，区分说话人(me/partner)，按时间顺序排列:\n\n$rawOcrText',
                },
              ],
              'temperature': 0.1,
              'max_tokens': 512,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw _httpError(response.statusCode, response.body);
      }
      return _parseFallbackResponse(response.body);
    });

    return result;
  }

  // ==================== 连接测试 ====================

  Future<bool> testConnection() async {
    final key = await apiKey;
    if (key == null || key.isEmpty) return false;
    final result = await _safeCall<bool>(() async {
      // 发送简单请求测试连通性（DeepSeek 不保证支持 /models 端点）
      final response = await http
          .post(
            Uri.parse('$baseUrl/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'user', 'content': 'ping'},
              ],
              'temperature': 0,
              'max_tokens': 1,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 || response.statusCode == 401) {
        // 401 也说明网络连通（仅 Key 无效），不算网络错误
        return true;
      }
      throw _httpError(response.statusCode, response.body);
    });
    return result ?? false;
  }

  // ---- 内部工具 ----

  Future<AiSuggestionResult> _safeSuggest(
    Future<AiSuggestionResult> Function() body,
  ) async {
    try {
      return await body();
    } on AiException catch (e) {
      debugPrint('[AiService] ${e.kind}: ${e.userMessage}');
      return AiSuggestionResult(suggestions: const [], error: e);
    } on http.ClientException catch (e) {
      debugPrint('[AiService] network: ${e.message}');
      return AiSuggestionResult(
        suggestions: const [],
        error: AiException(AiErrorKind.network, '网络异常，请检查连接', cause: e.message),
      );
    } catch (e) {
      debugPrint('[AiService] unknown: ${e.runtimeType}');
      return AiSuggestionResult(
        suggestions: const [],
        error: AiException(AiErrorKind.unknown, '服务暂时不可用，请稍后重试',
            cause: e.runtimeType.toString()),
      );
    }
  }

  Future<T?> _safeCall<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on AiException catch (e) {
      debugPrint('[AiService] ${e.kind}: ${e.userMessage}');
      return null;
    } on http.ClientException catch (e) {
      debugPrint('[AiService] network: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[AiService] unknown: ${e.runtimeType}');
      return null;
    }
  }

  AiException _httpError(int status, String body) {
    debugPrint('[AiService] HTTP $status, body length=${body.length}');
    switch (status) {
      case 401:
      case 403:
        return const AiException(AiErrorKind.auth, 'API Key 无效或权限不足');
      case 429:
        return const AiException(AiErrorKind.quota, '请求过于频繁或配额已用尽');
      case 500:
      case 502:
      case 503:
      case 504:
        return const AiException(AiErrorKind.network, 'AI 服务暂不可用');
      default:
        return AiException(AiErrorKind.unknown, '请求失败 ($status)');
    }
  }

  AiSuggestionResult _parseSuggestionsResponse(String body) {
    final data = jsonDecode(body);
    final content =
        (data['choices'] as List).first['message']['content'] as String;
    final jsonStr = _extractJson(content);
    if (jsonStr == null) {
      throw const AiException(AiErrorKind.parse, 'AI 返回格式异常，请重试');
    }
    final parsed = jsonDecode(jsonStr);
    final list = parsed['suggestions'];
    if (list is! List) {
      throw const AiException(AiErrorKind.parse, 'AI 返回字段异常');
    }
    final suggestions = list
        .whereType<Map>()
        .map((s) => SuggestionItem(
              style: (s['style'] ?? '').toString(),
              content: (s['content'] ?? '').toString(),
              reason: s['reason']?.toString(),
            ))
        .where((s) => s.content.isNotEmpty)
        .toList();
    return AiSuggestionResult(suggestions: suggestions);
  }

  ParsedChatFallback _parseFallbackResponse(String body) {
    final data = jsonDecode(body);
    final content =
        (data['choices'] as List).first['message']['content'] as String;
    final jsonStr = _extractJson(content);
    if (jsonStr == null) {
      throw const AiException(AiErrorKind.parse, 'AI 返回格式异常');
    }
    final parsed = jsonDecode(jsonStr);
    final list = parsed['messages'];
    if (list is! List) {
      throw const AiException(AiErrorKind.parse, 'AI 返回字段异常');
    }
    return ParsedChatFallback(
      messages: list
          .whereType<Map>()
          .map((m) => FallbackMessage(
                speaker: (m['speaker'] ?? 'partner').toString(),
                content: (m['content'] ?? '').toString(),
                timestamp: m['timestamp']?.toString(),
              ))
          .toList(),
    );
  }

  @visibleForTesting
  static String? extractJson(String text) => _extractJson(text);

  static String? _extractJson(String text) {
    final codeBlock =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (codeBlock != null) {
      text = codeBlock.group(1)!;
    }
    final firstBrace = text.indexOf('{');
    if (firstBrace == -1) return null;
    int depth = 0;
    for (int i = firstBrace; i < text.length; i++) {
      if (text[i] == '{') depth++;
      if (text[i] == '}') depth--;
      if (depth == 0) {
        final jsonStr = text.substring(firstBrace, i + 1);
        try {
          jsonDecode(jsonStr);
          return jsonStr;
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }
}

class AiSuggestionResult {
  final List<SuggestionItem> suggestions;
  final Object? error;

  AiSuggestionResult({required this.suggestions, this.error});

  String? get userErrorMessage {
    final e = error;
    if (e is AiException) return e.userMessage;
    if (e is String) return e;
    return null;
  }

  bool get hasError => error != null;
}

class SuggestionItem {
  final String style;
  final String content;
  final String? reason;

  const SuggestionItem({
    required this.style,
    required this.content,
    this.reason,
  });
}

class ParsedChatFallback {
  final List<FallbackMessage> messages;
  ParsedChatFallback({required this.messages});
}

class FallbackMessage {
  final String speaker;
  final String content;
  final String? timestamp;
  FallbackMessage({
    required this.speaker,
    required this.content,
    this.timestamp,
  });
}
