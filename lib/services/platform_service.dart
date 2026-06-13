import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/models/chat_memory.dart';
import '../data/models/screenshot_record.dart';
import '../data/models/suggestion.dart';
import 'vision_service.dart';

/// 悬浮球点击后的完整处理流水线（PRD V2 单 AI 引擎版）
///
/// 数据流：截图 → 加载最近 6 条记忆 + 全量历史 → 豆包单次多任务调用
///       → 增量消息落库 + 建议落库 + 联系人画像更新 → 全局浮窗卡片
class PlatformService {
  static const _floatingBallChannel =
      MethodChannel('com.chathelper/floating_ball');
  static const _screenshotChannel = MethodChannel('com.chathelper/screenshot');

  final AppDatabase _db;
  final VisionService _visionService;

  /// V2 流水线结果回调（截图 + 单次多任务输出）
  void Function(ScreenshotRecord record, UnifiedResult result)? onUnifiedResult;
  void Function(String message)? onError;
  void Function(String message)? onInfo;

  String? _currentContactIdSnapshot;
  String? _lastOverlayContactId;
  bool _quickReplyEnabled = false;
  bool _isProcessing = false;

  /// 当前 App 选中的联系人 ID（main 注入的"用户当前联系人"）
  String? get currentContactId => _currentContactIdSnapshot;

  /// Dart 端是否正在处理任务（用于 Java onResume 恢复球状态）
  bool get isProcessing => _isProcessing;

  /// 最近一次"显示建议浮窗"时的联系人 ID。
  /// 用于"换一批"时保证与原截图上下文一致，避免用户在 App 内切换联系人后误用新联系人重新生成。
  String? get lastOverlayContactId => _lastOverlayContactId;

  PlatformService({
    required AppDatabase db,
    required VisionService visionService,
  })  : _db = db,
        _visionService = visionService;

  /// Java 端已完成截图 → 接收路径后继续处理 AI + 落库 + 浮窗
  /// 新架构：消除 Dart→Java 截图往返在 Activity 后台时的阻塞
  Future<void> processScreenshotResult(String screenshotPath) async {
    await _processAfterScreenshot(screenshotPath);
  }

  /// 通知 Java 悬浮球更新状态（processing / success / error / idle）
  Future<void> _updateBallStatus(String status) async {
    try {
      await _floatingBallChannel
          .invokeMethod<void>('updateBallStatus', {'status': status});
    } catch (e) {
      debugPrint('[PlatformService] updateBallStatus 失败: $e');
    }
  }

  /// 显示原生建议卡片浮窗（WindowManager，覆盖所有App）
  Future<void> showSuggestionOverlay({
    required UnifiedResult result,
    required int autoDismissSeconds,
    String? contactId,
  }) async {
    // 记录"换一批"时该用的联系人（与产生本张截图的联系人保持一致）
    if (contactId != null) {
      _lastOverlayContactId = contactId;
    }
    try {
      // 构建传给 Java 的数据 Map（V2 字段：scene/sceneDescription/direction/contactInsight）
      final suggestionsData = result.suggestions.map((s) {
        return {
          'style': s.style,
          'content': s.content,
          'reason': s.reason ?? '',
        };
      }).toList();

      await _floatingBallChannel.invokeMethod<void>('showSuggestionOverlay', {
        'scene': result.scene,
        'sceneDescription': result.sceneDescription,
        'direction': result.direction,
        'contactInsight': result.contactInsight,
        'suggestions': suggestionsData,
        'autoDismissSeconds': autoDismissSeconds,
      });
    } catch (e) {
      debugPrint('[PlatformService] showSuggestionOverlay 失败: $e');
    }
  }

  /// 隐藏原生建议浮窗
  Future<void> hideSuggestionOverlay() async {
    // 浮窗关闭后清掉联系人快照，避免下一次截图时仍用旧联系人
    _lastOverlayContactId = null;
    try {
      await _floatingBallChannel.invokeMethod<void>('hideSuggestionOverlay');
    } catch (e) {
      debugPrint('[PlatformService] hideSuggestionOverlay 失败: $e');
    }
  }

  // ---- 公开 API ----

  Future<bool> showFloatingBall() async {
    try {
      return await _floatingBallChannel
              .invokeMethod<bool>('showFloatingBall') ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[PlatformService] showFloatingBall: ${e.code}');
      return false;
    }
  }

  Future<bool> hideFloatingBall() async {
    try {
      return await _floatingBallChannel
              .invokeMethod<bool>('hideFloatingBall') ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[PlatformService] hideFloatingBall: ${e.code}');
      return false;
    }
  }

  Future<bool> startService() async {
    try {
      return await _floatingBallChannel.invokeMethod<bool>('startService') ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[PlatformService] startService: ${e.code}');
      return false;
    }
  }

  /// 打开系统无障碍设置页
  Future<bool> openAccessibilitySettings() async {
    try {
      return await _screenshotChannel
              .invokeMethod<bool>('openAccessibilitySettings') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  // ---- 配置 ----

  void setCurrentContactId(String? id) {
    _currentContactIdSnapshot = id;
    // 同步联系人标签到悬浮球
    _syncContactLabel(id);
  }

  void setQuickReplyEnabled(bool enabled) {
    _quickReplyEnabled = enabled;
  }

  /// 同步当前选中联系人的名字到悬浮球旁的标签
  Future<void> _syncContactLabel(String? contactId) async {
    if (contactId == null || contactId.isEmpty) {
      try {
        await _floatingBallChannel
            .invokeMethod<void>('updateContactLabel', {'name': ''});
      } catch (_) {}
      return;
    }
    try {
      final contact = await _db.getContact(contactId);
      final name = contact?.name ?? '';
      await _floatingBallChannel
          .invokeMethod<void>('updateContactLabel', {'name': name});
    } catch (e) {
      debugPrint('[PlatformService] _syncContactLabel 失败: $e');
    }
  }

  // ==================== 核心流水线（V2 单 AI 多任务版）====================

  /// 悬浮球点击后的完整处理流程（PRD V2 §6）：
  ///
  /// 1. 截图
  /// 2. 加载最近 6 条记忆（去重基准）+ 全量历史（建议生成参考）
  /// 3. 调用豆包单次多任务（提取 + 建议 + 画像）
  /// 4. 增量消息入库（按 contact+speaker+content+timestamp 幂等去重）
  /// 5. 更新联系人画像（覆盖式）
  /// 6. 建议落库
  /// 7. 浮窗展示（WindowManager 覆盖所有App）
  Future<void> _processAfterScreenshot(String path) async {
    // 必须先选择联系人，否则记忆无法正确归属
    if (_currentContactIdSnapshot == null) {
      _emitError('请先选择联系人');
      await _updateBallStatus('error');
      return;
    }

    // 网络预检：无网络时立即提示，避免等待60s超时
    if (!await _hasNetwork()) {
      _emitError('网络不可用，请检查连接后重试');
      await _updateBallStatus('error');
      return;
    }

    // 标记开始处理（用于 onResume 恢复球状态）
    _isProcessing = true;

    final contactId = _currentContactIdSnapshot!;
    ScreenshotRecord? record;
    final stopwatch = Stopwatch()..start();

    try {
      final recordId = const Uuid().v4();
      record = ScreenshotRecord(
        id: recordId,
        contactId: contactId,
        filePath: path,
        ai1Status: 'processing',
        createdAt: DateTime.now(),
      );
      await _db.insertScreenshot(record);

      // ---- Step 2: 加载记忆（PRD §11）----
      final recentMemories = await _db.getRecentMemories(
        contactId,
        limit: VisionService.dedupMemoryCount,
      );
      final allMemories = await _db.getAllMemories(contactId);
      debugPrint(
          '[PlatformService] L1去重基准=${recentMemories.length} 条, L2全量=${allMemories.length} 条');

      // 加载联系人档案
      final contact = await _db.getContact(contactId);

      // ---- Step 3: 豆包单次多任务调用（进度提示：识别对话中）----
      await _updateBallStatus('processing'); // 保持 processing，文字已为"识别中..."
      // 可选：通过新状态值更新加载文字（Java端 updateBallStatus 已支持）
      try {
        await _floatingBallChannel
            .invokeMethod<void>('updateBallStatus', {'status': 'analyzing'});
      } catch (_) {}

      final result = await _visionService.extractAndSuggest(
        imageFile: File(path),
        recentMemories: recentMemories,
        allMemories: allMemories,
        contactName: contact?.name ?? '对方',
        tone: contact?.tonePreference ?? 'neutral',
        length: contact?.lengthPreference ?? 'medium',
        creativity: contact?.creativityPreference ?? 0.5,
        currentTime: DateTime.now(),
        quickReply: _quickReplyEnabled,
      );

      stopwatch.stop();
      final durationMs = stopwatch.elapsedMilliseconds;
      debugPrint('[PlatformService] 单次多任务调用耗时 ${durationMs}ms');

      // 错误处理
      if (result.hasError) {
        debugPrint('[PlatformService] AI 错误: ${result.error}');
        record = _recordWithUnified(record, result, durationMs);
        await _db.updateScreenshot(record);
        _emitError('对话识别失败: ${result.error?.message}');
        await _updateBallStatus('error');
        onUnifiedResult?.call(record, result);
        return;
      }

      // ---- Steps 4-6: 增量消息落库 + 画像更新 + 建议落库（统一方法）----
      // 进度提示：生成建议中
      try {
        await _floatingBallChannel
            .invokeMethod<void>('updateBallStatus', {'status': 'generating'});
      } catch (_) {}
      await _persistAiResult(
        contactId: contactId,
        recordId: recordId,
        result: result,
      );

      // ---- Step 7: 更新截图记录 + 回调 ----
      record = _recordWithUnified(record, result, durationMs);
      await _db.updateScreenshot(record);
      onUnifiedResult?.call(record, result);

      // 信息反馈
      debugPrint(
          '[PlatformService] AI 完成: 新增消息 ${result.messages.length} 条, 建议 ${result.suggestions.length} 条');

      // 球状态：成功（哪怕没有新增，识别流程本身成功）
      await _updateBallStatus('success');
      _isProcessing = false;
    } on SocketException catch (e) {
      await _handleProcessingError(e, null, record: record);
    } on TimeoutException catch (e) {
      await _handleProcessingError(e, null, record: record);
    } on FormatException catch (e) {
      await _handleProcessingError(e, null, record: record);
    } catch (e, st) {
      await _handleProcessingError(e, st, record: record);
    }
  }

  /// 重新生成建议（"换一批"按钮触发）
  ///
  /// V2 简化版：直接用最近一次截图重新调用豆包，传入相同上下文
  Future<void> regenerateSuggestions(String contactId) async {
    // 悬浮球进入处理中状态（横条"识别中..."）
    await _updateBallStatus('processing');
    _isProcessing = true;

    try {
      final contact = await _db.getContact(contactId);
      final allMemories = await _db.getAllMemories(contactId);

      // 找到该联系人最近一次"成功"的截图（含 done / no_new 两种语义）
      final rows = await _db.db.query(
        'screenshots',
        where: 'contact_id = ? AND ai1_status IN (?, ?)',
        whereArgs: [contactId, 'done', 'no_new'],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (rows.isEmpty) {
        _emitError('无最近截图，无法换一批');
        _isProcessing = false;
        return;
      }
      final record = ScreenshotRecord.fromMap(rows.first);
      final path = record.filePath;
      final file = File(path);
      if (!await file.exists()) {
        _emitError('截图文件已不存在');
        _isProcessing = false;
        return;
      }

      final recentMemories = await _db.getRecentMemories(
        contactId,
        limit: VisionService.dedupMemoryCount,
      );

      final result = await _visionService.extractAndSuggest(
        imageFile: file,
        recentMemories: recentMemories,
        allMemories: allMemories,
        contactName: contact?.name ?? '对方',
        tone: contact?.tonePreference ?? 'neutral',
        length: contact?.lengthPreference ?? 'medium',
        creativity: contact?.creativityPreference ?? 0.5,
        currentTime: DateTime.now(),
        quickReply: _quickReplyEnabled,
      );

      if (result.hasError) {
        _emitError('重新生成失败: ${result.error?.message}');
        await _updateBallStatus('error');
        _isProcessing = false;
        return;
      }

      // ---- 统一落库（增量消息 + 画像更新 + 建议批量查重）----
      await _persistAiResult(
        contactId: contactId,
        recordId: record.id,
        result: result,
      );

      // ---- 更新截图记录 ----
      final updatedRecord = _recordWithUnified(record, result, 0);
      await _db.updateScreenshot(updatedRecord);

      onUnifiedResult?.call(updatedRecord, result);
      await _updateBallStatus('success');
      _isProcessing = false;
    } on SocketException catch (e) {
      await _handleProcessingError(e, null, prefix: '换一批');
    } on TimeoutException catch (e) {
      await _handleProcessingError(e, null, prefix: '换一批');
    } on FormatException catch (e) {
      await _handleProcessingError(e, null, prefix: '换一批');
    } catch (e, st) {
      await _handleProcessingError(e, st, prefix: '换一批', fallbackMsg: '重新生成失败，请重试');
    }
  }

  /// 统一落库方法：增量消息 + 画像更新 + 建议批量查重
  ///
  /// 被 _processAfterScreenshot 和 regenerateSuggestions 共享，
  /// 消除两处完全重复的落库逻辑。
  Future<void> _persistAiResult({
    required String contactId,
    required String recordId,
    required UnifiedResult result,
  }) async {
    // Step A: 增量消息落库（幂等去重）
    final newMemories = <ChatMemory>[];
    for (final m in result.messages) {
      newMemories.add(m.toChatMemory(
        id: const Uuid().v4(),
        contactId: contactId,
        screenshotId: recordId,
      ));
    }
    final inserted = await _db.insertMemoriesDedupe(newMemories);
    debugPrint(
        '[PlatformService] 落库: AI返回 ${result.messages.length} 条消息 -> 实际新增 ${inserted.length} 条');

    // Step B: 更新联系人画像（覆盖式）
    if (result.contactInsight != null &&
        result.contactInsight!.isNotEmpty &&
        result.contactInsight != '暂无足够信息') {
      await _db.updateContactInsight(contactId, result.contactInsight!);
    }

    // Step C: 建议批量查重后落库（1-2次DB查询，而非逐条N次）
    if (result.hasSuggestions) {
      await _insertSuggestionsBatch(contactId, recordId, result.suggestions);
    }
  }

  /// 批量建议查重插入：先查出已存在的 content 集合 → 过滤 → batch INSERT
  ///
  /// 相比逐条 findSuggestionByContent（N次RTT），本方法：
  /// - 1次 SELECT 查出所有已有 content
  /// - 内存过滤出需新增的建议
  /// - 1次 batch INSERT
  Future<void> _insertSuggestionsBatch(
    String contactId,
    String screenshotId,
    List<UnifiedSuggestion> suggestions,
  ) async {
    if (suggestions.isEmpty) return;

    // 1) 一次查出该截图下已有的建议 content 集合（通过封装方法）
    final contents = suggestions.map((s) => s.content).toList();
    final existingContents = await _db.getExistingSuggestionContents(
      screenshotId,
      contents,
    );

    // 2) 过滤出需要新增的
    final toInsert = suggestions
        .where((s) => !existingContents.contains(s.content))
        .toList();
    if (toInsert.isEmpty) return;

    // 3) Batch insert（单次 RTT）
    final batchItems = toInsert
        .map((s) => Suggestion(
              id: const Uuid().v4(),
              contactId: contactId,
              screenshotId: screenshotId,
              style: s.style,
              content: s.content,
              reason: s.reason,
              createdAt: DateTime.now(),
            ))
        .toList();
    await _db.insertSuggestionsBatch(batchItems);
    debugPrint(
        '[PlatformService] 建议落库: ${suggestions.length} 条 -> 新增 ${toInsert.length} 条');
  }

  void dispose() {
    onUnifiedResult = null;
    onError = null;
    onInfo = null;
  }

  // ---- 内部工具 ----

  /// 将截图记录标记为 error 状态（防止 processing 卡死）
  Future<void> _markRecordError(ScreenshotRecord? record) async {
    if (record == null) return;
    try {
      await _db.updateScreenshot(record.copyWith(ai1Status: 'error'));
    } catch (_) {
      // DB 更新失败不阻塞主流程
    }
  }

  ScreenshotRecord _recordWithUnified(
    ScreenshotRecord base,
    UnifiedResult result,
    int durationMs,
  ) {
    final messagesJson = result.messages.isNotEmpty
        ? jsonEncode(result.messages.map((m) {
            return {
              'speaker': m.speaker,
              'content': m.content,
              'time': m.timestamp,
            };
          }).toList())
        : null;

    return base.copyWith(
      ai1Status: result.hasError
          ? 'error'
          : (result.messages.isEmpty ? 'no_new' : 'done'),
      ai1Error: result.error?.message,
      parseConfidence: result.hasError ? 'low' : 'high',
      ai1ResultJson: messagesJson,
      scene: result.scene,
      sceneDescription: result.sceneDescription,
      contactInsight: result.contactInsight,
      direction: result.direction,
      durationMs: durationMs,
    );
  }

  void _emitError(String msg) {
    debugPrint('[PlatformService] ERROR: $msg');
    onError?.call(msg);
  }

  /// 统一异常处理：网络/超时/格式/其他 → 更新球状态 + 标记错误 + 重置处理标志
  Future<void> _handleProcessingError(
    Object e,
    StackTrace? st, {
    String prefix = '',
    ScreenshotRecord? record,
    String fallbackMsg = '处理失败，请重试',
  }) async {
    final tag = prefix.isNotEmpty ? '$prefix ' : '';
    if (e is SocketException) {
      debugPrint('${tag}[PlatformService] 网络异常: $e');
      _emitError('网络连接失败，请检查网络');
    } else if (e is TimeoutException) {
      debugPrint('${tag}[PlatformService] 超时: $e');
      _emitError('AI 响应超时，请稍后重试');
    } else if (e is FormatException) {
      debugPrint('${tag}[PlatformService] 格式异常: $e');
      _emitError('AI 返回数据格式异常');
    } else {
      debugPrint('${tag}[PlatformService] 未预期异常: $e${st != null ? "\n$st" : ""}');
      _emitError(fallbackMsg);
    }
    await _updateBallStatus('error');
    if (record != null) await _markRecordError(record);
    _isProcessing = false;
  }

  /// 快速网络检测：DNS 查询火山引擎域名，超时 3 秒
  Future<bool> _hasNetwork() async {
    try {
      final result = await InternetAddress.lookup('ark.cn-beijing.volces.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
