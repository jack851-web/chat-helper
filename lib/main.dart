import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'data/database.dart';
import 'services/platform_service.dart';
import 'services/vision_service.dart';
import 'utils/constants.dart';

/// 浮浮球/建议浮窗 MethodChannel（与 Java MainActivity 通信）
const _floatingBallChannel = MethodChannel('com.chathelper/floating_ball');

// 保存 listener 引用，以便在 AppState dispose 时移除
VoidCallback? _contactIdListener;
VoidCallback? _quickReplyListener;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppDatabase.instance.initialize();

  // V2：单 AI 引擎（豆包）
  final visionService = VisionService();
  await visionService.init();

  final appState = AppState();
  await appState.init();

  // 核心流水线编排（V2 单引擎版：截图 → 豆包单次多任务 → 浮窗）
  final platformService = PlatformService(
    db: AppDatabase.instance,
    visionService: visionService,
  );
  platformService.setCurrentContactId(appState.currentContactId);
  platformService.setQuickReplyEnabled(appState.quickReplyEnabled);

  // 启动时恢复卡住的 processing 记录 + 清理过期截图（并行执行）
  await Future.wait([
    AppDatabase.instance.recoverStuckProcessingRecords(),
    AppDatabase.instance.cleanupOldScreenshots(),
  ]);

  // 注册状态同步 listener（保存引用以便后续移除）
  _contactIdListener =
      () => platformService.setCurrentContactId(appState.currentContactId);
  _quickReplyListener =
      () => platformService.setQuickReplyEnabled(appState.quickReplyEnabled);
  appState.addListener(_contactIdListener!);
  appState.addListener(_quickReplyListener!);

  // 协议版本协商：检查 Dart/Java 两端协议版本是否兼容
  try {
    final javaVersion =
        await _floatingBallChannel.invokeMethod<int>('getProtocolVersion');
    if (javaVersion != null && javaVersion != AppConstants.protocolVersion) {
      debugPrint(
          '[main] ⚠️ 协议版本不匹配: Dart=${AppConstants.protocolVersion}, Java=$javaVersion');
      // 不阻塞启动，但记录警告；后续可按版本号做优雅降级
    } else {
      debugPrint('[main] ✓ 协议版本一致: v$javaVersion');
    }
  } catch (e) {
    debugPrint('[main] ⚠️ 协议版本查询失败（可能是旧版 Java 端）: $e');
  }

  // Global keys for showing UI from platform callbacks
  final navKey = GlobalKey<NavigatorState>();
  final scaffoldKey = GlobalKey<ScaffoldMessengerState>();

  // V2 单次多任务完成后通知用户
  platformService.onUnifiedResult = (record, result) {
    if (result.hasError) {
      scaffoldKey.currentState?.showSnackBar(
        SnackBar(content: Text('对话识别失败: ${result.error?.message}')),
      );
      return;
    }
    if (result.isAllDuplicate) {
      scaffoldKey.currentState?.showSnackBar(
        const SnackBar(content: Text('未检测到新消息')),
      );
    } else {
      debugPrint(
          '[main] V2 完成: 新增 ${result.messages.length} 条, 建议 ${result.suggestions.length} 条');
    }

    // 显示原生 WindowManager 浮窗（PRD §5.3：不需要切回 Chat-Helper App）
    if (result.hasSuggestions) {
      platformService.showSuggestionOverlay(
        result: result,
        autoDismissSeconds: appState.autoDismissSeconds,
        contactId: record.contactId,
      );
    }
  };

  // 注册 Java 浮窗回调事件
  _floatingBallChannel.setMethodCallHandler((call) async {
    debugPrint('[main] 浮窗事件: ${call.method}');
    switch (call.method) {
      case 'onScreenshotReady':
        // Java 端已完成截图，传入路径 → 继续处理 AI + 落库 + 浮窗
        // 注意：不再显示 SnackBar，因为悬浮球已变为横条"识别中..."状态
        final path = call.arguments as String?;
        if (path != null && path.isNotEmpty) {
          await platformService.processScreenshotResult(path);
        } else {
          scaffoldKey.currentState?.showSnackBar(
            const SnackBar(content: Text('截图失败')),
          );
        }
        break;
      case 'onSuggestionRegenerate':
        // 换一批 → 用"产生本次浮窗的截图"绑定的联系人，而不是当前联系人
        final cid = platformService.lastOverlayContactId ??
            platformService.currentContactId;
        if (cid != null) {
          scaffoldKey.currentState?.showSnackBar(
            const SnackBar(content: Text('重新生成中...')),
          );
          await platformService.regenerateSuggestions(cid);
        } else {
          scaffoldKey.currentState?.showSnackBar(
            const SnackBar(content: Text('无法定位联系人')),
          );
        }
        break;
      case 'onSuggestionClosed':
      case 'onSuggestionCopied':
        // 浮窗已关闭或已复制，无需额外处理
        break;
      case 'onSaveDraft':
        // 存入草稿：将当前浮窗显示的建议保存到草稿箱
        scaffoldKey.currentState?.showSnackBar(
          const SnackBar(content: Text('已存入草稿')),
        );
        break;
      case 'getCurrentContactId':
        return platformService.currentContactId;
    }
  });

  platformService.onError = (msg) {
    scaffoldKey.currentState?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  };

  runApp(
    MultiProvider(
      providers: [
        Provider<VisionService>.value(value: visionService),
        Provider<PlatformService>.value(value: platformService),
        ChangeNotifierProvider<AppState>.value(value: appState),
      ],
      child: ChatHelperApp(
        navKey: navKey,
        scaffoldKey: scaffoldKey,
      ),
    ),
  );
}

/// 全局应用状态
class AppState extends ChangeNotifier {
  static const _prefsKeyCurrentContact = 'current_contact_id';
  static const _prefsKeyDarkMode = 'is_dark_mode';
  static const _prefsKeyAutoDismiss = 'auto_dismiss_seconds';
  static const _prefsKeyQuickReply = 'quick_reply_enabled';

  late SharedPreferences _prefs;

  String? _currentContactId;
  String? get currentContactId => _currentContactId;

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  int _autoDismissSeconds = 8;
  int get autoDismissSeconds => _autoDismissSeconds;

  bool _quickReplyEnabled = false;
  bool get quickReplyEnabled => _quickReplyEnabled;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _currentContactId = _prefs.getString(_prefsKeyCurrentContact);
    _isDarkMode = _prefs.getBool(_prefsKeyDarkMode) ?? false;
    _autoDismissSeconds = _prefs.getInt(_prefsKeyAutoDismiss) ?? 8;
    _quickReplyEnabled = _prefs.getBool(_prefsKeyQuickReply) ?? false;
    notifyListeners();
  }

  void setCurrentContact(String? id) {
    _currentContactId = id;
    if (id != null) {
      _prefs.setString(_prefsKeyCurrentContact, id);
    } else {
      _prefs.remove(_prefsKeyCurrentContact);
    }
    notifyListeners();
  }

  void toggleDarkMode() {
    _isDarkMode = !_isDarkMode;
    _prefs.setBool(_prefsKeyDarkMode, _isDarkMode);
    notifyListeners();
  }

  void setAutoDismissSeconds(int seconds) {
    _autoDismissSeconds = seconds;
    _prefs.setInt(_prefsKeyAutoDismiss, seconds);
    notifyListeners();
  }

  void setQuickReplyEnabled(bool enabled) {
    _quickReplyEnabled = enabled;
    _prefs.setBool(_prefsKeyQuickReply, enabled);
    notifyListeners();
  }

  @override
  void dispose() {
    // 移除 main() 中注册的 listener，避免悬空回调
    if (_contactIdListener != null) removeListener(_contactIdListener!);
    if (_quickReplyListener != null) removeListener(_quickReplyListener!);
    super.dispose();
  }
}
