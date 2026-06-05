import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../main.dart';
import '../../data/database.dart';
import '../../services/ai_service.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _apiKeyCtrl;
  bool _showApiKey = false;
  bool _testing = false;
  bool _keyLoaded = false;
  bool _dirtyApiKey = false;

  @override
  void initState() {
    super.initState();
    _apiKeyCtrl = TextEditingController();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    if (!mounted) return;
    final aiService = context.read<AiService>();
    final key = await aiService.getCachedApiKey();
    if (!mounted) return;
    _apiKeyCtrl.text = key ?? '';
    setState(() => _keyLoaded = true);
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String text, {bool success = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success ? AppTheme.success : AppTheme.error,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveApiKey(AiService aiService) async {
    if (_dirtyApiKey) {
      await aiService.setApiKey(_apiKeyCtrl.text.trim());
      setState(() => _dirtyApiKey = false);
    }
    _showSnack('已保存');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = context.watch<AppState>();
    final aiService = context.read<AiService>();

    if (!_keyLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionHeader(title: 'DeepSeek AI 配置', theme: theme),
        const SizedBox(height: 4),
        Text(
          'AI-1（本地提取）使用 ML Kit OCR，无需额外配置',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppTheme.success),
        ),
        const SizedBox(height: 12),

        // API Base URL（只读显示）
        TextFormField(
          enabled: false,
          initialValue: 'https://api.deepseek.com',
          decoration: const InputDecoration(
            labelText: 'API Base URL',
            prefixIcon: Icon(Icons.link),
            helperText: '固定在 api.deepseek.com',
          ),
        ),
        const SizedBox(height: 12),

        // 模型选择
        DropdownButtonFormField<String>(
          // ignore: deprecated_member_use
          value: aiService.model,
          decoration: const InputDecoration(
            labelText: 'AI-2 建议模型',
            prefixIcon: Icon(Icons.psychology),
            helperText: '仅用于回复建议生成',
          ),
          items: const [
            DropdownMenuItem(value: 'deepseek-chat', child: Text('deepseek-chat（推荐）')),
            DropdownMenuItem(value: 'deepseek-reasoner', child: Text('deepseek-reasoner')),
          ],
          onChanged: (v) {
            if (v == null) return;
            aiService.model = v;
            setState(() {});
          },
        ),
        const SizedBox(height: 12),

        // API Key
        TextFormField(
          controller: _apiKeyCtrl,
          obscureText: !_showApiKey,
          decoration: InputDecoration(
            labelText: 'DeepSeek API Key',
            hintText: 'sk-...',
            prefixIcon: const Icon(Icons.key),
            suffixIcon: IconButton(
              icon: Icon(
                  _showApiKey ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showApiKey = !_showApiKey),
            ),
            helperText: '从 platform.deepseek.com 获取；Key 用系统密钥库加密存储',
          ),
          onChanged: (_) {
            if (!_dirtyApiKey) setState(() => _dirtyApiKey = true);
          },
        ),
        const SizedBox(height: 12),

        // 保存按钮
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _dirtyApiKey
                ? () => _saveApiKey(aiService)
                : null,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
        ),
        const SizedBox(height: 8),

        // 测试连接
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _testing ? null : () => _testConnection(aiService),
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_find),
            label: Text(_testing ? '测试中...' : '测试 DeepSeek 连接'),
          ),
        ),
        const SizedBox(height: 8),

        // 云端兜底
        SwitchListTile(
          title: const Text('低置信云端兜底'),
          subtitle: const Text('AI-1解析失败时自动发送纯文本到 DeepSeek 云端解析'),
          value: aiService.cloudFallbackEnabled,
          onChanged: (v) {
            aiService.cloudFallbackEnabled = v;
            setState(() {});
          },
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 32),

        // 外观
        _SectionHeader(title: '外观设置', theme: theme),
        SwitchListTile(
          title: const Text('深色模式'),
          value: appState.isDarkMode,
          onChanged: (_) => appState.toggleDarkMode(),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 32),

        // 隐私
        _SectionHeader(title: '隐私与安全', theme: theme),
        ListTile(
          title: const Text('清除所有数据'),
          subtitle: const Text('包括联系人、记忆库、草稿、截图文件'),
          leading: const Icon(Icons.delete_forever, color: AppTheme.error),
          onTap: () => _showClearDataDialog(context),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 32),

        // 关于
        _SectionHeader(title: '关于', theme: theme),
        const ListTile(
          title: Text('Chat-Helper'),
          subtitle: Text('v1.2 · DeepSeek AI 聊天辅助'),
          leading: Icon(Icons.info_outline),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Future<void> _testConnection(AiService aiService) async {
    await _saveApiKey(aiService);
    setState(() => _testing = true);
    final ok = await aiService.testConnection();
    if (!mounted) return;
    setState(() => _testing = false);
    _showSnack(ok ? 'DeepSeek 连接成功!' : '连接失败，请检查 API Key', success: ok);
  }

  void _showClearDataDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清除所有数据'),
        content: const Text(
            '将物理删除所有截图文件，并清空联系人、对话记忆、建议记录和草稿。不可恢复！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogCtx);
              final appState = context.read<AppState>();
              try {
                await AppDatabase.instance.clearAll();
                if (!mounted) return;
                _showSnack('所有数据已清除');
                appState.setCurrentContact(null);
              } catch (e) {
                if (!mounted) return;
                _showSnack('清除失败: ${e.runtimeType}', success: false);
              }
            },
            child: const Text('确认清除',
                style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final ThemeData theme;

  const _SectionHeader({required this.title, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.primary,
      ),
    );
  }
}
