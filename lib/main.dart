import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'data/database.dart';
import 'services/ai_service.dart';
import 'services/clipboard_service.dart';
import 'services/ocr_service.dart';
import 'services/platform_service.dart';
import 'ui/screens/suggestion_card.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppDatabase.instance.initialize();

  final aiService = AiService();
  await aiService.init();

  final ocrService = OcrService();
  final appState = AppState();
  await appState.init();

  final platformService = PlatformService(
    db: AppDatabase.instance,
    ocrService: ocrService,
  );
  platformService.setCurrentContactId(appState.currentContactId);
  appState.addListener(
    () => platformService.setCurrentContactId(appState.currentContactId),
  );

  // Global keys for showing suggestion cards from platform callbacks
  final navKey = GlobalKey<NavigatorState>();
  final scaffoldKey = GlobalKey<ScaffoldMessengerState>();

  // OCR 完成后触发 AI-2 DeepSeek 建议生成
  platformService.onScreenshotReady = (record, ocr) async {
    final contactId = platformService.currentContactId;
    if (contactId == null) return;

    // 从数据库加载该联系人最近 50 轮历史对话
    List<Map<String, String>> historyMessages;
    try {
      final dbMemories = await AppDatabase.instance.getMemories(
        contactId,
        limit: 50,
      );
      historyMessages = AiService.buildMessages(
        dbMemories.map((m) => {'speaker': m.speaker, 'content': m.content}).toList(),
      );
    } catch (_) {
      historyMessages = [];
    }

    // 从联系人档案读取个性化参数
    String tone = '自然中性';
    String length = '两三句';
    double creativity = 0.5;
    try {
      final contact = await AppDatabase.instance.getContact(contactId);
      if (contact != null) {
        tone = contact.tonePreference;
        length = contact.lengthPreference;
        creativity = contact.creativityPreference;
      }
    } catch (_) {}

    Future<void> callAi2() async {
      final result = await aiService.generateSuggestions(
        historyMessages: historyMessages,
        tone: tone,
        length: length,
        creativity: creativity,
      );

      if (result.userErrorMessage != null) {
        scaffoldKey.currentState?.showSnackBar(
          SnackBar(content: Text(result.userErrorMessage!)),
        );
        return;
      }

      if (result.suggestions.isNotEmpty && navKey.currentContext != null) {
        showModalBottomSheet(
          context: navKey.currentContext!,
          isScrollControlled: true,
          builder: (_) => SuggestionCard(
            suggestions: result.suggestions,
            contactId: contactId,
            screenshotId: record.id,
            onRegenerate: callAi2,
            onClose: () => Navigator.of(navKey.currentContext!).pop(),
          ),
        );
      }
    }

    await callAi2();
  };

  platformService.onError = (msg) {
    scaffoldKey.currentState?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  };

  runApp(
    MultiProvider(
      providers: [
        Provider<OcrService>(create: (_) => ocrService),
        Provider<AiService>.value(value: aiService),
        Provider<ClipboardService>(create: (_) => ClipboardService()),
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

  late SharedPreferences _prefs;

  String? _currentContactId;
  String? get currentContactId => _currentContactId;

  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _currentContactId = _prefs.getString(_prefsKeyCurrentContact);
    _isDarkMode = _prefs.getBool(_prefsKeyDarkMode) ?? false;
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
}
