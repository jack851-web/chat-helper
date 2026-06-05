import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'main.dart';
import 'services/platform_service.dart';
import 'services/ocr_service.dart';
import 'ui/theme/app_theme.dart';
import 'ui/screens/home_screen.dart';

class ChatHelperApp extends StatefulWidget {
  final GlobalKey<NavigatorState> navKey;
  final GlobalKey<ScaffoldMessengerState> scaffoldKey;

  const ChatHelperApp({
    super.key,
    required this.navKey,
    required this.scaffoldKey,
  });

  @override
  State<ChatHelperApp> createState() => _ChatHelperAppState();
}

class _ChatHelperAppState extends State<ChatHelperApp>
    with WidgetsBindingObserver {

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startup();
    });
  }

  Future<void> _startup() async {
    try {
      final platform = context.read<PlatformService>();
      await platform.startService();
      await platform.showFloatingBall();
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Activity 恢复后重建悬浮球（系统对话框可能已将其移除）
      _startup();
    }
    if (state == AppLifecycleState.detached) {
      try {
        context.read<PlatformService>().dispose();
        context.read<OcrService>().dispose();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return MaterialApp(
          navigatorKey: widget.navKey,
          scaffoldMessengerKey: widget.scaffoldKey,
          title: 'Chat-Helper',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: appState.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          home: const HomeScreen(),
        );
      },
    );
  }
}
