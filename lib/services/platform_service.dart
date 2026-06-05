import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../data/models/screenshot_record.dart';
import '../data/models/chat_memory.dart';
import 'ocr_service.dart';
import 'rule_engine.dart';

class PlatformService {
  static const _floatingBallChannel =
      MethodChannel('com.chathelper/floating_ball');
  static const _screenshotChannel =
      MethodChannel('com.chathelper/screenshot');

  final AppDatabase _db;
  final OcrService _ocrService;

  void Function(ScreenshotRecord record, OcrResult ocr)? onScreenshotReady;
  void Function(String message)? onError;

  String? _currentContactIdSnapshot;
  double _screenWidth = 1080;
  double _screenHeight = 2400;

  PlatformService({
    required AppDatabase db,
    required OcrService ocrService,
  })  : _db = db,
        _ocrService = ocrService {
    _registerHandlers();
  }

  void _registerHandlers() {
    _floatingBallChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onFloatingBallClick':
          await _handleFloatingBallClick();
          return null;
        default:
          throw MissingPluginException('Unknown method: ${call.method}');
      }
    });
  }

  // ---- 公开 API ----

  Future<bool> showFloatingBall() async {
    try {
      return await _floatingBallChannel.invokeMethod<bool>('showFloatingBall') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[PlatformService] showFloatingBall: ${e.code}');
      return false;
    }
  }

  Future<bool> hideFloatingBall() async {
    try {
      return await _floatingBallChannel.invokeMethod<bool>('hideFloatingBall') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[PlatformService] hideFloatingBall: ${e.code}');
      return false;
    }
  }

  Future<bool> startService() async {
    try {
      return await _floatingBallChannel.invokeMethod<bool>('startService') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[PlatformService] startService: ${e.code}');
      return false;
    }
  }

  /// 请求截图权限（MediaProjection 一次性授权）
  Future<bool> requestScreenshotPermission() async {
    try {
      return await _screenshotChannel.invokeMethod<bool>('requestScreenshotPermission') ?? false;
    } on PlatformException {
      _emitError('截图权限请求失败');
      return false;
    }
  }

  /// 打开系统无障碍设置页
  Future<bool> openAccessibilitySettings() async {
    try {
      return await _screenshotChannel.invokeMethod<bool>('openAccessibilitySettings') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<String?> captureScreenshot() async {
    try {
      return await _screenshotChannel.invokeMethod<String>('captureScreenshot');
    } on PlatformException catch (e) {
      _emitError(_mapError(e));
      return null;
    }
  }

  // ---- 配置 ----

  String? get currentContactId => _currentContactIdSnapshot;

  void setCurrentContactId(String? id) {
    _currentContactIdSnapshot = id;
  }

  void setScreenSize(double width, double height) {
    _screenWidth = width;
    _screenHeight = height;
  }

  // ---- 内部流水线 ----

  Future<void> _handleFloatingBallClick() async {
    try {
      final path = await captureScreenshot();
      if (path == null) return; // error 已通过 onError 回调

      final recordId = const Uuid().v4();
      var record = ScreenshotRecord(
        id: recordId,
        contactId: _currentContactIdSnapshot,
        filePath: path,
        ai1Status: 'processing',
        createdAt: DateTime.now(),
      );
      await _db.insertScreenshot(record);

      OcrResult ocr;
      try {
        ocr = await _ocrService.recognize(File(path), _screenWidth, _screenHeight);
      } catch (e) {
        ocr = OcrResult(
          blocks: const [],
          parsedChat: ParsedChatResult(messages: const [], confidence: 'low',
              warning: 'OCR 异常 (${e.runtimeType})'),
        );
      }

      record = _recordWithOcr(record, ocr);
      await _db.updateScreenshot(record);

      if (ocr.parsedChat.messages.isNotEmpty) {
        final memories = ocr.parsedChat.messages
            .map((m) => ChatMemory(
                  id: const Uuid().v4(),
                  contactId: _currentContactIdSnapshot ?? '_default',
                  screenshotId: recordId,
                  speaker: m.speaker,
                  content: m.content,
                  createdAt: DateTime.now(),
                ))
            .toList();
        await _db.insertMemories(memories);
      }

      onScreenshotReady?.call(record, ocr);
    } catch (e, st) {
      debugPrint('[PlatformService] pipeline: $e\n$st');
      _emitError('截图处理失败');
    }
  }

  void dispose() {
    onScreenshotReady = null;
    onError = null;
  }

  ScreenshotRecord _recordWithOcr(ScreenshotRecord base, OcrResult ocr) {
    return ScreenshotRecord(
      id: base.id, contactId: base.contactId,
      filePath: base.filePath, thumbnailPath: base.thumbnailPath,
      ai1ResultJson: ocr.parsedChat.toJsonString(),
      ai1Status: 'done', ai1Error: ocr.parsedChat.warning,
      parseConfidence: ocr.parsedChat.confidence, createdAt: base.createdAt,
    );
  }

  void _emitError(String msg) {
    debugPrint('[PlatformService] $msg');
    onError?.call(msg);
  }

  String _mapError(PlatformException e) {
    switch (e.code) {
      case 'A11Y_SERVICE_OFF':
        return '请先在 设置→无障碍 中开启 Chat-Helper 截图服务';
      case 'BUSY': return '截图正在处理中，请稍候';
      default: return '截图失败: ${e.message ?? e.code}';
    }
  }
}
