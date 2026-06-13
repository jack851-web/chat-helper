import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/json_utils.dart';
import 'package:http/http.dart' as http;
import '../data/models/chat_memory.dart';
import '../utils/constants.dart';

/// 豆包 AI 服务（单引擎多任务版）
///
/// 在一次 API 调用中同时完成：
///   1. 截图对话提取（增量去重）
///   2. 回复建议生成（场景感知 + 方向铁律）
///
/// 不同模型对应不同端点格式（火山引擎方舟平台）：
///   - doubao-seed 系列：使用 /responses 端点（input/input_image/input_text）
///   - doubao-1.5-vision-pro：使用 /chat/completions 端点（messages/image_url/text）
///
/// 通过 [endpointTypeFor] 按模型名自动判断。
///
/// 上下文注入分层（PRD V2）：
///   L1: 最近 6 条记忆 → 用于增量去重判断
///   L2: 全量历史记忆（头尾保留策略）→ 用于建议生成参考
///   L3: 联系人档案 → 个性化参数
///   L4: 当前截图 + 当前时间
class VisionService {
  static const _secureApiKeyKey = 'ai1_doubao_api_key';
  static const _prefsModelKey = 'ai1_model';
  final _secureStorage = const FlutterSecureStorage();
  late final SharedPreferences _prefs;

  /// 豆包 API Base URL（火山引擎方舟）
  static const baseUrl = 'https://ark.cn-beijing.volces.com/api/v3';

  /// /responses 端点（Seed 系列）
  static const responsesEndpoint = '$baseUrl/responses';

  /// /chat/completions 端点（1.5 Vision Pro）
  static const completionsEndpoint = '$baseUrl/chat/completions';

  /// 预设模型列表（用户也可输入自定义 Endpoint ID）
  ///
  /// format 字段指明该模型对应的官方 SDK 调用方式：
  ///   - 'responses': client.responses.create() 风格 → /responses
  static const presetModels = {
    'doubao-seed-2-0-mini-260428': {
      'label': 'Seed 2.0 Mini',
      'desc': '最新轻量模型，识别速度快',
      'format': 'responses',
    },
    'doubao-seed-2-0-pro-260215': {
      'label': 'Seed 2.0 Pro',
      'desc': '更强能力，回复质量更高',
      'format': 'responses',
    },
    // 用户可在设置中输入自定义 Endpoint ID（火山引擎控制台）
  };

  /// 默认模型（推荐使用）
  static const defaultModel = 'doubao-seed-2-0-mini-260428';

  /// 根据模型名自动判断应使用哪个端点格式
  ///
  /// 规则：
  ///   - 预设模型直接查表
  ///   - 包含 'seed' 字样 → responses
  ///   - 包含 '1.5' / '1-5' / 'vision-pro' / 'vision_lite' → completions
  ///   - 其他 → responses（默认新模型都走 responses 端点）
  static String endpointTypeFor(String modelId) {
    final m = modelId.toLowerCase();

    // 1. 预设模型查表
    final preset = presetModels[modelId];
    if (preset != null) return preset['format']!;

    // 2. 自定义模型：按命名规则启发式判断
    if (m.contains('1.5') ||
        m.contains('1-5') ||
        m.contains('vision-pro') ||
        m.contains('vision_pro') ||
        m.contains('vision-lite') ||
        m.contains('vision_lite')) {
      return 'completions';
    }
    if (m.contains('seed')) return 'responses';

    // 3. 兜底：默认走 responses（新模型多用此端点）
    return 'responses';
  }

  /// 当前模型应使用的 API URL
  String get endpoint => endpointTypeFor(model) == 'completions'
      ? completionsEndpoint
      : responsesEndpoint;

  Future<void> init() async => _prefs = await SharedPreferences.getInstance();

  // ---- 配置 ----

  String get model => _prefs.getString(_prefsModelKey) ?? defaultModel;
  set model(String v) => _prefs.setString(_prefsModelKey, v);

  /// 去重时加载的记忆条数（PRD §5.4.3）
  static const dedupMemoryCount = 6;

  // ---- 配置 ----

  Future<String?> get apiKey async =>
      await _secureStorage.read(key: _secureApiKeyKey);

  Future<void> setApiKey(String? v) async {
    if (v != null && v.isNotEmpty) {
      await _secureStorage.write(key: _secureApiKeyKey, value: v);
    } else {
      await _secureStorage.delete(key: _secureApiKeyKey);
    }
  }

  Future<bool> get isConfigured async {
    final key = await apiKey;
    return key != null && key.isNotEmpty;
  }

  // ==================== 核心调用：单次多任务（V2 合并版） ====================

  /// 单次 API 调用同时完成：对话提取 + 回复建议生成
  ///
  /// 上下文注入分层：
  ///   [imageFile]          截图文件
  ///   [recentMemories]     最近 6 条记忆（用于增量去重）
  ///   [allMemories]        全量历史记忆（用于建议生成参考，头尾保留）
  ///   [contactName]        联系人名称
  ///   [tone]               语气偏好 (neutral/warm/playful/...)
  ///   [length]             长度偏好 (short/medium/long)
  ///   [creativity]         创意度 0.0-1.0
  ///   [currentTime]        当前时间戳
  Future<UnifiedResult> extractAndSuggest({
    required File imageFile,
    required List<ChatMemory> recentMemories,
    required List<ChatMemory> allMemories,
    String contactName = '对方',
    String tone = 'neutral',
    String length = 'medium',
    double creativity = 0.5,
    DateTime? currentTime,
    bool quickReply = false,
  }) async {
    final key = await apiKey;
    if (key == null || key.isEmpty) {
      return UnifiedResult(
        messages: [],
        suggestions: [],
        error: VisionError.notConfigured,
      );
    }

    // 读取图片并编码为 base64
    Uint8List bytes = await imageFile.readAsBytes();

    // 图片压缩：超过 1920px 宽时缩小，降低内存峰值（原始 5-10MB → 压缩后 ~1-3MB）
    bytes = await _compressImageIfNeeded(bytes);

    // 防止超大截图导致 OOM（限制 10MB 压缩后大小）
    if (bytes.length > 10 * 1024 * 1024) {
      return UnifiedResult(
        messages: [],
        suggestions: [],
        error: const VisionError(VisionErrorKind.unknown, '截图文件过大，请尝试降低分辨率'),
      );
    }
    final base64Image = base64Encode(bytes);

    // 构建上下文文本
    final contextText = _buildUnifiedContext(
      recentMemories: recentMemories,
      allMemories: allMemories,
      contactName: contactName,
      tone: tone,
      length: length,
      creativity: creativity,
      currentTime: currentTime ?? DateTime.now(),
      quickReply: quickReply,
    );

    // 带重试的 AI 调用：超时/网络错误自动重试 1 次
    const maxRetries = 2;
    VisionError? lastError;

    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $key',
              },
              body: jsonEncode(
                  _buildUnifiedRequestBody(base64Image, contextText)),
            )
            .timeout(
              Duration(seconds: AppConstants.visionTimeoutSeconds),
            );

        if (response.statusCode == 200) {
          return _parseUnifiedResponse(response.body);
        }

        debugPrint(
            '[VisionService] HTTP ${response.statusCode} (attempt $attempt/$maxRetries): ${response.body}');
        lastError = _mapHttpError(response.statusCode, response.body);
        // HTTP 错误（4xx/5xx）不重试，直接返回
        return UnifiedResult(
          messages: [],
          suggestions: [],
          error: lastError,
        );
      } on TimeoutException catch (e) {
        debugPrint('[VisionService] 超时 (attempt $attempt/$maxRetries): $e');
        if (attempt < maxRetries) {
          // 等待 2 秒后重试
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        return UnifiedResult(
          messages: [],
          suggestions: [],
          error: const VisionError(
            VisionErrorKind.timeout,
            'AI 响应超时（60s），请检查网络后重试',
          ),
        );
      } on http.ClientException catch (e) {
        debugPrint(
            '[VisionService] 网络 (attempt $attempt/$maxRetries): ${e.message}');
        if (attempt < maxRetries) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        return UnifiedResult(
          messages: [],
          suggestions: [],
          error: VisionError(VisionErrorKind.network, '网络异常: ${e.message}'),
        );
      } catch (e, st) {
        // 编程 Bug / 格式异常等不可恢复错误 → 不重试，立即返回
        debugPrint(
            '[VisionService] 异常 (attempt $attempt/$maxRetries): $e\n$st');
        return UnifiedResult(
          messages: [],
          suggestions: [],
          error: VisionError(VisionErrorKind.unknown, '未知错误: $e'),
        );
      }
    }

    // 不应到达此处，但作为兜底
    return UnifiedResult(
      messages: [],
      suggestions: [],
      error: lastError ?? const VisionError(VisionErrorKind.unknown, '处理失败'),
    );
  }

  /// HTTP 状态码 → VisionError 映射
  VisionError _mapHttpError(int status, [String? body]) {
    switch (status) {
      case 401:
      case 403:
        return const VisionError(VisionErrorKind.auth, '豆包 API Key 无效或权限不足');
      case 429:
        return const VisionError(VisionErrorKind.quota, '请求过于频繁或配额已用尽');
      case 500:
      case 502:
      case 503:
      case 504:
        return const VisionError(VisionErrorKind.network, '豆包服务暂不可用');
      default:
        final detail = body != null && body.length < 200
            ? ' ($status) $body'
            : '请求失败 ($status)';
        return VisionError(VisionErrorKind.unknown, detail);
    }
  }

  // ==================== 内部方法：V2 上下文与请求体 ====================

  /// 构建 V2 单次多任务调用的上下文文本（PRD §11）
  ///
  /// 注入顺序：
  ///   L1 联系人档案
  ///   L2 当前时间
  ///   L3 全量历史记忆（头尾保留：开头 20 + 结尾 180）
  ///   L4 最近 6 条记忆（独立 section，仅用于去重判断）
  String _buildUnifiedContext({
    required List<ChatMemory> recentMemories,
    required List<ChatMemory> allMemories,
    required String contactName,
    required String tone,
    required String length,
    required double creativity,
    required DateTime currentTime,
    bool quickReply = false,
  }) {
    final sb = StringBuffer();

    // L1: 联系人档案
    sb.writeln('【联系人档案】');
    sb.writeln('- 联系人: $contactName');
    sb.writeln('- 语气偏好: ${_toneLabel(tone)}');
    sb.writeln('- 长度偏好: ${_lengthLabel(length)}');
    sb.writeln('- 创意度: ${(creativity * 100).toInt()}%');
    sb.writeln();

    // L2: 当前时间
    sb.writeln('【当前时间】');
    sb.writeln(currentTime.toIso8601String());
    sb.writeln('(${formatRelativeTime(currentTime)})');
    sb.writeln();

    // L3: 全量历史（DB层已执行头尾保留策略：前20条+最近200条，总上限220条）
    // 此处直接使用传入的 allMemories，不再二次截断
    sb.writeln('【全量历史记忆】');
    if (allMemories.isEmpty) {
      sb.writeln('（暂无历史记忆，这是你们的第一次对话）');
    } else {
      sb.writeln('（共 ${allMemories.length} 条）');
      sb.writeln(_formatAllMemories(allMemories));
    }
    sb.writeln();

    // L4: 最近 N 条记忆（用于增量去重判断；N = dedupMemoryCount）
    sb.writeln('【最近 $dedupMemoryCount 条记忆 — 增量去重基准】');
    if (recentMemories.isEmpty) {
      sb.writeln('（无）');
    } else {
      sb.writeln('以下消息已存在于记忆库，请勿重复输出到 new_messages:');
      sb.writeln(_formatRecentForDedup(recentMemories));
    }

    // L6: 任务指令（快速回复模式）
    if (quickReply) {
      sb.writeln();
      sb.writeln('【⚡ 快速回复模式 — 已开启】');
      sb.writeln('用户开启了"快速回复"，意味着对方在等、或者场景需要秒回。');
      sb.writeln('');
      sb.writeln('核心要求：');
      sb.writeln('- 每条建议 5-15 字，极短（特殊情况不超过 20 字）');
      sb.writeln('- 像微信里随手打的字，不是精心编辑的');
      sb.writeln('- 可以只用一两个字回应："嗯嗯" "哈哈" "真的？" "可以啊" "行吧"');
      sb.writeln('- direction 控制在 8-15 字');
      sb.writeln('');
      sb.writeln('快速回复示例：');
      sb.writeln('| 对方消息 | 快速回复 |');
      sb.writeln('|---------|---------|');
      sb.writeln('| "到了吗" | "刚到" / "在路上了" |');
      sb.writeln('| "吃了吗" | "吃了 你呢" |');
      sb.writeln('| "今天好累" | "辛苦 早点休息" |');
      sb.writeln('| "哈哈哈太好笑了" | "笑死我了哈哈哈哈" |');
    }

    return sb.toString();
  }

  /// 图片压缩：宽超过 1920px 时等比缩小，PNG→JPEG 编码降低体积
  /// 目标：将 5-10MB 原始截图压缩至 ~1-3MB，减少 base64 内存峰值
  static const _maxImageWidth = 1920;

  Future<Uint8List> _compressImageIfNeeded(Uint8List bytes) async {
    // 小于 2MB 的图片跳过压缩（压缩收益不大）
    if (bytes.length < 2 * 1024 * 1024) return bytes;

    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // 超过最大宽度时缩小
      int targetWidth = image.width;
      int targetHeight = image.height;
      if (targetWidth > _maxImageWidth) {
        final scale = _maxImageWidth / targetWidth;
        targetWidth = _maxImageWidth;
        targetHeight = (targetHeight * scale).round();
      }

      // 仅在需要缩小时重新编码
      if (targetWidth != image.width) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
          Paint()..filterQuality = FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        final resized = await picture.toImage(targetWidth, targetHeight);
        final byteData =
            await resized.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        resized.dispose();
        if (byteData != null) {
          debugPrint(
              '[VisionService] 图片压缩: ${bytes.length} → ${byteData.lengthInBytes} 字节');
          return byteData.buffer.asUint8List();
        }
      }
      image.dispose();
    } catch (e) {
      debugPrint('[VisionService] 图片压缩失败，使用原图: $e');
    }
    return bytes;
  }

  String _toneLabel(String t) {
    switch (t) {
      case 'warm':
        return '温柔体贴';
      case 'playful':
        return '俏皮活泼';
      case 'humorous':
        return '幽默风趣';
      case 'sincere':
        return '真诚深情';
      case 'flirty':
        return '暧昧撩人';
      case 'neutral':
      default:
        return '自然中性';
    }
  }

  String _lengthLabel(String l) {
    switch (l) {
      case 'short':
        return '简短（< 20 字）';
      case 'long':
        return '详细（> 50 字）';
      case 'medium':
      default:
        return '适中（20-50 字）';
    }
  }

  String _formatAllMemories(List<ChatMemory> mems) {
    final lines = <String>[];
    for (final m in mems) {
      final tag = m.speaker == 'me' ? '[self]' : '[other]';
      final ts = m.timestampEstimate?.toIso8601String() ??
          m.createdAt.toIso8601String();
      lines.add('$tag $ts  ${m.content}');
    }
    return lines.join('\n');
  }

  String _formatRecentForDedup(List<ChatMemory> mems) {
    final lines = <String>[];
    for (final m in mems) {
      final tag = m.speaker == 'me' ? '[self]' : '[other]';
      lines.add('- $tag: ${m.content}');
    }
    return lines.join('\n');
  }

  /// 构建 V2 单次多任务调用的请求体
  Map<String, dynamic> _buildUnifiedRequestBody(
      String base64Image, String contextText) {
    if (endpointTypeFor(model) == 'completions') {
      // /chat/completions 格式（1.5 Vision Pro）
      return {
        'model': model,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png;base64,$base64Image'},
              },
              {
                'type': 'text',
                'text': '${_buildUnifiedSystemPrompt()}\n\n$contextText',
              },
            ],
          },
        ],
      };
    } else {
      // /responses 格式（Seed 系列）
      return {
        'model': model,
        'input': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'input_image',
                'image_url': 'data:image/png;base64,$base64Image',
              },
              {
                'type': 'input_text',
                'text': '${_buildUnifiedSystemPrompt()}\n\n$contextText',
              },
            ],
          },
        ],
      };
    }
  }

  /// V2 单次多任务调用的 System Prompt（PRD §5.4.2）
  /// 缓存为静态字段：内容完全静态，无需每次调用重新拼接 ~3KB 字符串
  /// 如需强制重建（如 prompt 模板变更），调用 [clearPromptCache]
  static String? _cachedSystemPrompt;

  /// 清除 System Prompt 缓存（prompt 模板变更时调用）
  static void clearPromptCache() {
    _cachedSystemPrompt = null;
  }

  String _buildUnifiedSystemPrompt() {
    if (_cachedSystemPrompt != null) return _cachedSystemPrompt!;
    _cachedSystemPrompt =
        '''你是一个"聊天场景理解 + 话术生成"专家。请同时完成两项任务，并严格按 JSON Schema 输出。

━━━━━━━━━━━━━━━━━━━━━━━━
【任务 A：截图对话增量识别】
━━━━━━━━━━━━━━━━━━━━━━━━

【你的身份】
截图是一段"手机两人私聊"窗口的聊天记录。你只负责"读取 + 识别"截图内容并判断是否为新增消息。

【角色判定规则 — 两人私聊】
- 屏幕右半区气泡 → "me"（手机持有者 / 截图者 / 需要建议的一方）
- 屏幕左半区气泡 → "partner"（对话对象）
- 辅助：右气泡通常带绿色/蓝色背景；左气泡通常带白色/灰色背景
- me 的头像在右侧或不可见；partner 的头像在左侧

【图片消息的发送者判定 — 重要！】
聊天中经常有人发图片，必须正确判断图片是谁发的：
- 图片在屏幕**右侧**（或右半区，带绿色/蓝色背景）→ **me 发的图**，speaker = "me"
- 图片在屏幕**左侧**（或左半区，带白色/灰色背景）→ **partner 发的图**，speaker = "partner"
- 判断依据与文字气泡相同：看图片在截图中的左右位置
- 图片消息也要纳入 new_messages 输出，content 可简写为 "[图片]" 或描述图片内容
- ⚠️ 常见错误：把 partner 发的图片误判为 me 发的，导致后续建议方向完全错误

【增量输出规则 — 严格】
- 仅输出"最近 $dedupMemoryCount 条记忆"中不存在的消息
- 重复判定：speaker 相同 + content 高度相似（允许表情/标点的微小差异）
- 如果截图中的消息都已存在 → new_messages 输出空数组 []
- 每条必须包含 time 字段（从截图估算时间，ISO8601 格式）

【过滤规则】
- 忽略：撤回提示、时间戳分隔线、状态栏、"对方正在输入..."
- emoji 保留原样
- 空白无效区域不输出

━━━━━━━━━━━━━━━━━━━━━━━━
【任务 B：回复建议生成】
━━━━━━━━━━━━━━━━━━━━━━━━

【三大场景判定 — 必选其一】
- 场景 A · 待回复（partner 发了消息，me 还没回）：建议应直接回应 partner 最新消息
- 场景 B · 主动开启（me 找 partner，开启新话题）：建议应轻松自然、不突兀
- 场景 C · 后续推进（之前有未完话题，需要跟进）：建议应承接上文、推进对话

⚠️ 【致命红线 — 违反即判零分】
★ 你生成的每一条建议，都必须是「me（截图者/手机持有者）要发出去的消息」。
★ 判定方法：先看截图里「最后一条消息是谁发的」
  - 最后一条是 partner 发的 → 你要帮 me 想怎么回 partner
  - 最后一条是 me 发的 → 你要帮 me 想接下来主动说什么（或等 partner 回复时 me 可以说什么）
★ 常见错误（绝对禁止）：
  ❌ 最后明明是 me 发了消息，你却生成"谢谢你的分享""我也这么觉得"这种像是 partner 在回 me 的话
  ❌ 生成的内容看起来像是在"回应 me"而不是"me 回应 partner"
  ❌ 用"你"指代 me、"我"指代 partner（人称反了）
★ 正确的人称：建议中的"我"= me（截图者），"你"= partner（对方）

═══════════════════════════
【真人聊天铁律 — 违反任何一条都算失败】
═══════════════════════════

★ 核心原则：你生成的是「me 要发出去的消息」，不是在写文章、做分析、给建议。
想象一下：这是你（me）打开微信、看到对方消息后、手指在输入框里打出来的字。

【绝对禁止 — 出现即扣分】
❌ 公文腔/书面语："首先...其次..." "综上所述" "由此可见" "总而言之"
❌ 心理咨询腔："我理解你的感受" "我能感受到你的情绪" "这对你来说一定不容易吧"
❌ 过度礼貌/客套："亲爱的" "亲爱的XX" "非常感谢你的分享" "很高兴听到这个消息"
❌ 总结复述对方的话："也就是说你是说..." "你的意思是..."
❌ 空洞表态："我会一直支持你" "我会关心你的" "有什么事随时找我"
❌ 完美句式：每句话都结构完整、逻辑严密、用词精准 → 真人不会这样说话
❌ 情绪过度饱满：每条建议都带感叹号、emoji堆砌、"太棒了！！""真的吗！！！"

【必须做到 — 真人聊天的特征】
✅ 像打字一样自然：允许口语化、省略主语、不完整的句子
✅ 有个性/有态度：不是每个回复都温温柔柔，可以调侃、可以吐槽、可以冷淡、可以兴奋
✅ 具体而非抽象：说"这家店上次吃的那个牛肉面不错" 而不说 "我们可以一起品尝美食"
✅ 回应有针对性：针对对方说的具体内容回应，而不是泛泛而谈
✅ 长度有变化：有时一句话就够，有时多说两句，不要每条都是差不多长度
✅ 适当留白：不用把话说满，让对方有接话的空间
✅ 可以"不正经"：朋友之间可以开玩笑、可以互损、可以发无厘头的东西

【真人 vs AI 对比示例】

| 场景 | AI味重（错误） | 真人会说的（正确） |
|------|---------------|-------------------|
| 对方说今天加班好累 | "辛苦了！工作确实很消耗精力，记得好好休息哦 💪" | "又加班啊 几点走的" / "惨 今周第几天了" |
| 对方分享美食 | "看起来非常美味呢！感谢你的分享，有机会我也要尝试一下" | "看着不错啊 哪家的" / "啊啊我想吃" |
| 对方说心情不好 | "我理解你现在的心情不好受。无论发生什么，我都会支持你的。" | "咋了" / "出啥事了" / "抱抱 发生什么了" |
| 对方问周末干嘛 | "我计划在这个周末进行一些放松活动，比如阅读和散步。" | "还没想好 可能躺尸" / "应该在家 你呢" |
| 开启新话题 | "最近怎么样？希望一切都好！" | "在吗 给你看个东西" / "刚看到一个搞笑的哈哈哈哈" |

【方向（direction）】
一句话描述"me 现在应该怎么推进对话"。要求 10-30 字，口语化。
例："顺着他说的事往下聊" "先问问具体情况再决定怎么回" "直接约个时间见面说"

【联系人画像（contact_insight）】
基于全量历史记忆总结：
- 性格特点（话多/话少/直接/含蓄/爱用表情）
- 沟通偏好（喜欢简短/长聊/主动/被动）
- 关系状态（朋友/暧昧/刚认识/有矛盾）
- 最近关注点/情绪状态
1-3 句话，不超过 80 字。

【3 条具体话术】
- 风格差异化：如 直接型 + 温和型 + 搞怪型 / 或 认真型 + 随意型 + 互动型
- 必须是 me 会真正打字发出去的内容，不是"示范性回复"
- 每条附"理由"说明为什么这样建议

━━━━━━━━━━━━━━━━━━━━━━━━
【输出 JSON Schema — 严格遵守】
━━━━━━━━━━━━━━━━━━━━━━━━

{
  "new_messages": [
    {"speaker": "me|partner", "content": "消息内容", "time": "ISO8601格式时间"}
  ],
  "scene": "A" | "B" | "C",
  "scene_description": "当前场景的 1 句话说明（20-50 字）",
  "contact_insight": "联系人画像（1-3 句话，不超过 80 字）",
  "direction": "对话方向（1 句话，20-50 字）",
  "suggestions": [
    {
      "style": "风格名（2-4 字）",
      "content": "具体话术内容",
      "reason": "为什么这样建议（1 句话）"
    }
  ]
}

【输出要求】
1. 仅输出 JSON，不要任何前缀说明、Markdown 包裹、注释
2. 字段缺失时：scene = "A"、scene_description = "无具体上下文"、contact_insight = "暂无足够信息"、direction = "自然回应对方最新消息"、suggestions = []（空数组）
3. 如果截图无新增消息：new_messages = []，仍要输出场景/画像/方向/建议
4. 如果完全无对话历史：contact_insight = "暂无足够信息"，suggestions 仍要基于截图内容生成 3 条''';
    return _cachedSystemPrompt!;
  }

  /// 解析 V2 单次多任务调用的响应
  UnifiedResult _parseUnifiedResponse(String body) {
    try {
      final data = jsonDecode(body);
      final type = endpointTypeFor(model);
      debugPrint(
          '[VisionService] unified parse (endpoint=$type) keys: ${data.keys.toList()}');

      String content = '';
      if (type == 'completions') {
        // /chat/completions 格式：choices[0].message.content
        content = (data['choices'] as List?)
                ?.firstOrNull?['message']?['content']
                ?.toString() ??
            '';
      } else {
        // /responses 格式：从 output 数组中提取文本内容
        if (data['output'] is List && (data['output'] as List).isNotEmpty) {
          final outputs = data['output'] as List;
          Map<String, dynamic>? messageItem;
          for (final item in outputs) {
            if (item is Map && item['type'] == 'message') {
              messageItem = Map<String, dynamic>.from(item);
              break;
            }
          }
          messageItem ??= outputs.last is Map
              ? Map<String, dynamic>.from(outputs.last)
              : null;
          if (messageItem != null) {
            if (messageItem['content'] is List) {
              final contents = messageItem['content'] as List;
              final textParts = contents
                  .whereType<Map>()
                  .where((c) => c['type'] == 'output_text')
                  .map((c) => (c['text'] ?? '').toString())
                  .toList();
              content = textParts.join('\n');
            } else if (messageItem['content'] is String) {
              content = messageItem['content'] as String;
            }
          }
        }
      }

      if (content.isEmpty) {
        return UnifiedResult(
          messages: [],
          suggestions: [],
          error: const VisionError(VisionErrorKind.parse, 'AI 返回内容为空'),
        );
      }

      final parsed = extractJsonFromAiResponse(content);
      debugPrint(
          '[VisionService] unified parsed keys: ${parsed.keys.toList()}');

      // 1) 解析 new_messages
      final messages = <VisionMessage>[];
      final newMsgs = parsed['new_messages'];
      if (newMsgs is List) {
        for (final raw in newMsgs) {
          if (raw is! Map) continue;
          final content = (raw['content'] ?? '').toString().trim();
          if (content.isEmpty) continue;
          messages.add(VisionMessage(
            speaker: (raw['speaker'] ?? 'partner').toString(),
            content: content,
            timestamp: raw['time']?.toString(),
          ));
        }
      }

      // 2) 解析 suggestions
      final suggestions = <UnifiedSuggestion>[];
      final sugList = parsed['suggestions'];
      if (sugList is List) {
        for (final raw in sugList) {
          if (raw is! Map) continue;
          final content = (raw['content'] ?? '').toString().trim();
          if (content.isEmpty) continue;
          suggestions.add(UnifiedSuggestion(
            style: (raw['style'] ?? '建议').toString(),
            content: content,
            reason: raw['reason']?.toString(),
          ));
        }
      }

      // 3) 解析场景/画像/方向
      final scene = parsed['scene']?.toString();
      final sceneDesc = parsed['scene_description']?.toString();
      final insight = parsed['contact_insight']?.toString();
      final direction = parsed['direction']?.toString();

      return UnifiedResult(
        messages: messages,
        suggestions: suggestions,
        scene: scene,
        sceneDescription: sceneDesc,
        contactInsight: insight,
        direction: direction,
      );
    } catch (e, st) {
      debugPrint('[VisionService] unified parse error: $e\n$st');
      return UnifiedResult(
        messages: [],
        suggestions: [],
        error: VisionError(VisionErrorKind.parse, '解析失败: $e'),
      );
    }
  }
  // ==================== 连接测试（V2 兼容） ====================

  /// 轻量级连通性测试：在设置页校验豆包 API Key 是否有效。
  ///
  /// 端点格式与 [extractAndSuggest] 完全一致，但只发送 "ping" 文本。
  /// 401/403 也算"网络通"，仅说明 Key 无效。
  Future<bool> testConnection() async {
    final key = await apiKey;
    if (key == null || key.isEmpty) return false;
    try {
      final type = endpointTypeFor(model);
      final Map<String, dynamic> body = (type == 'completions')
          ? {
              'model': model,
              'messages': [
                {'role': 'user', 'content': 'ping'},
              ],
            }
          : {
              'model': model,
              'input': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'input_text', 'text': 'ping'},
                  ],
                },
              ],
            };
      final response = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200 || response.statusCode == 401;
    } catch (_) {
      return false;
    }
  }
}

// ==================== 数据类 ====================

/// 单条识别出的消息
class VisionMessage {
  final String speaker; // 'me' | 'partner'
  final String content;
  final String? timestamp; // ISO8601 时间或相对时间

  VisionMessage({
    required this.speaker,
    required this.content,
    this.timestamp,
  });

  /// 转为 ChatMemory 用于落库
  ChatMemory toChatMemory({
    required String id,
    required String contactId,
    required String screenshotId,
  }) {
    DateTime? ts;
    if (timestamp != null && timestamp!.isNotEmpty) {
      try {
        ts = DateTime.parse(timestamp!);
      } catch (_) {
        // 无法解析则使用当前时间
      }
    }
    return ChatMemory(
      id: id,
      contactId: contactId,
      screenshotId: screenshotId,
      speaker: speaker,
      content: content,
      timestampEstimate: ts,
      createdAt: DateTime.now(),
    );
  }
}

enum VisionErrorKind {
  network,
  timeout,
  auth,
  quota,
  parse,
  notConfigured,
  unknown
}

class VisionError {
  final VisionErrorKind kind;
  final String message;

  const VisionError(this.kind, this.message);

  static const notConfigured =
      VisionError(VisionErrorKind.notConfigured, '请先在设置中配置豆包 API Key');

  @override
  String toString() => 'VisionError($kind, $message)';
}

// ==================== V2 单次多任务结果 ====================

/// V2 单次多任务调用结果（PRD §5.4.3）
///
/// 同时包含：
///   - 增量识别的新增消息
///   - 场景/画像/方向
///   - 3 条具体话术
class UnifiedResult {
  /// 增量识别的新增消息（已去重）
  final List<VisionMessage> messages;

  /// 回复建议（3 条）
  final List<UnifiedSuggestion> suggestions;

  /// 场景：A | B | C
  final String? scene;

  /// 场景描述
  final String? sceneDescription;

  /// 联系人画像摘要
  final String? contactInsight;

  /// 对话方向
  final String? direction;

  /// 错误信息
  final VisionError? error;

  UnifiedResult({
    required this.messages,
    required this.suggestions,
    this.scene,
    this.sceneDescription,
    this.contactInsight,
    this.direction,
    this.error,
  });

  bool get hasError => error != null;
  bool get hasNewMessages => messages.isNotEmpty;
  bool get hasSuggestions => suggestions.isNotEmpty;
  bool get isAllDuplicate => messages.isEmpty && !hasError;
}

/// V2 单条建议
class UnifiedSuggestion {
  final String style;
  final String content;
  final String? reason;

  UnifiedSuggestion({
    required this.style,
    required this.content,
    this.reason,
  });

  Map<String, dynamic> toJson() => {
        'style': style,
        'content': content,
        'reason': reason,
      };
}
