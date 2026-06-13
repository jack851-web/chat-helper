import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../main.dart';
import '../../data/database.dart';
import '../../services/vision_service.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // ---- V2 单 AI 引擎配置（豆包）----
  late final TextEditingController _doubaoApiKeyCtrl;
  bool _showDoubaoKey = false;
  bool _testingDoubao = false;
  bool _doubaoKeyLoaded = false;
  bool _dirtyDoubaoKey = false;

  @override
  void initState() {
    super.initState();
    _doubaoApiKeyCtrl = TextEditingController();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    if (!mounted) return;
    final visionService = context.read<VisionService>();

    final doubaoKey = await visionService.apiKey;

    if (!mounted) return;
    _doubaoApiKeyCtrl.text = doubaoKey ?? '';
    setState(() {
      _doubaoKeyLoaded = true;
    });
  }

  @override
  void dispose() {
    _doubaoApiKeyCtrl.dispose();
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

  // ==================== 豆包配置 ====================

  Future<void> _saveDoubaoApiKey(VisionService visionService) async {
    if (_dirtyDoubaoKey) {
      await visionService.setApiKey(_doubaoApiKeyCtrl.text.trim());
      setState(() => _dirtyDoubaoKey = false);
    }
    _showSnack('豆包 API Key 已保存');
  }

  Future<void> _testDoubaoConnection(VisionService visionService) async {
    await _saveDoubaoApiKey(visionService);
    setState(() => _testingDoubao = true);
    final ok = await visionService.testConnection();
    if (!mounted) return;
    setState(() => _testingDoubao = false);
    _showSnack(ok ? '豆包连接成功!' : '连接失败，请检查 API Key', success: ok);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = context.watch<AppState>();
    final visionService = context.read<VisionService>();

    if (!_doubaoKeyLoaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ===== 豆包 AI 引擎配置（V2 单引擎） =====
        _SectionHeader(title: '豆包 AI 引擎配置', theme: theme),
        Text(
          '用于截图对话提取 + 回复建议 + 联系人画像（单次多任务调用）',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 12),

        // 豆包 Base URL（只读）
        TextFormField(
          enabled: false,
          initialValue: VisionService.baseUrl,
          decoration: const InputDecoration(
            labelText: 'API Base URL',
            prefixIcon: Icon(Icons.link),
            helperText: '火山引擎豆包 API 地址',
          ),
        ),
        const SizedBox(height: 12),

        // 豆包模型选择（下拉框 + 自定义输入）
        DropdownButtonFormField<String>(
          initialValue: _isCustomModel(visionService.model)
              ? '_custom'
              : visionService.model,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '模型（Endpoint ID）',
            prefixIcon: Icon(Icons.visibility),
            helperText: '选择预设模型或输入自定义 Endpoint ID',
          ),
          items: [
            for (final entry in VisionService.presetModels.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Text(
                  '${entry.value['label']} — ${entry.value['desc']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const DropdownMenuItem(
              value: '_custom',
              child: Text('自定义模型 ID'),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            if (v != '_custom') {
              visionService.model = v;
              setState(() {});
            }
          },
        ),
        const SizedBox(height: 8),

        // 自定义模型输入（仅当选择自定义时显示）
        if (_isCustomModel(visionService.model))
          TextFormField(
            initialValue: visionService.model,
            decoration: const InputDecoration(
              labelText: '自定义模型 ID',
              hintText: '输入火山引擎控制台的 Endpoint ID',
              prefixIcon: Icon(Icons.keyboard),
            ),
            onChanged: (v) {
              visionService.model = v.trim();
              setState(() {});
            },
          ),
        if (_isCustomModel(visionService.model)) const SizedBox(height: 8),

        // 端点类型提示
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '当前端点：${_endpointLabel(visionService.model)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 豆包 API Key
        TextFormField(
          controller: _doubaoApiKeyCtrl,
          obscureText: !_showDoubaoKey,
          decoration: InputDecoration(
            labelText: '豆包 API Key',
            hintText: '从 console.volcengine.com 获取',
            prefixIcon: const Icon(Icons.key),
            suffixIcon: IconButton(
              icon: Icon(
                  _showDoubaoKey ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showDoubaoKey = !_showDoubaoKey),
            ),
            helperText: '用系统密钥库加密存储',
          ),
          onChanged: (_) {
            if (!_dirtyDoubaoKey) setState(() => _dirtyDoubaoKey = true);
          },
        ),
        const SizedBox(height: 8),

        // 豆包保存 + 测试按钮
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _dirtyDoubaoKey
                    ? () => _saveDoubaoApiKey(visionService)
                    : null,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testingDoubao
                    ? null
                    : () => _testDoubaoConnection(visionService),
                icon: _testingDoubao
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_find),
                label: Text(_testingDoubao ? '测试中...' : '测试连接'),
              ),
            ),
          ],
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
        SwitchListTile(
          title: const Text('快速回复模式'),
          subtitle: const Text('开启后 AI 会更快生成回复，适合需要快速回复的场景'),
          value: appState.quickReplyEnabled,
          onChanged: (v) => appState.setQuickReplyEnabled(v ?? false),
          dense: true,
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.flash_on),
        ),
        DropdownButtonFormField<int>(
          initialValue: appState.autoDismissSeconds,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '建议卡片显示时长',
            prefixIcon: Icon(Icons.timer_outlined),
            helperText: '浮窗建议卡片的自动消失时间',
          ),
          items: const [
            DropdownMenuItem(value: 5, child: Text('5 秒后自动消失')),
            DropdownMenuItem(value: 8, child: Text('8 秒后自动消失（推荐）')),
            DropdownMenuItem(value: 15, child: Text('15 秒后自动消失')),
            DropdownMenuItem(value: 0, child: Text('手动关闭（不会自动消失）')),
          ],
          onChanged: (v) {
            if (v == null) return;
            appState.setAutoDismissSeconds(v);
            setState(() {});
          },
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
          subtitle: Text('v2.5 · 单 AI 引擎多任务版'),
          leading: Icon(Icons.info_outline),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      ],
    );
  }

  void _showClearDataDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清除所有数据'),
        content: const Text('将物理删除所有截图文件，并清空联系人、对话记忆、建议记录和草稿。不可恢复！'),
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
            child: const Text('确认清除', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
  }

  static bool _isCustomModel(String modelId) {
    return !VisionService.presetModels.containsKey(modelId);
  }

  static String _endpointLabel(String modelId) {
    return VisionService.endpointTypeFor(modelId) == 'completions'
        ? '/chat/completions（OpenAI 兼容）'
        : '/responses（Seed 系列）';
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
