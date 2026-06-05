import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../data/database.dart';
import '../../data/models/draft.dart';
import '../../services/clipboard_service.dart';

class DraftEditorScreen extends StatefulWidget {
  final String initialContent;
  final String? contactId;
  final String? draftId;
  final String? suggestionId;

  const DraftEditorScreen({
    super.key,
    required this.initialContent,
    this.contactId,
    this.draftId,
    this.suggestionId,
  });

  @override
  State<DraftEditorScreen> createState() => _DraftEditorScreenState();
}

class _DraftEditorScreenState extends State<DraftEditorScreen> {
  late final TextEditingController _ctrl;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    if (!_saved) _autoSave();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _autoSave() async {
    final content = _ctrl.text.trim();
    if (content.isEmpty) return;

    final db = AppDatabase.instance;
    final now = DateTime.now();

    if (widget.draftId != null) {
      final draft = Draft(
        id: widget.draftId!,
        contactId: widget.contactId,
        suggestionId: widget.suggestionId,
        content: content,
        createdAt: now,
        updatedAt: now,
      );
      await db.updateDraft(draft);
    } else {
      final draft = Draft(
        id: const Uuid().v4(),
        contactId: widget.contactId,
        suggestionId: widget.suggestionId,
        content: content,
        createdAt: now,
        updatedAt: now,
      );
      await db.insertDraft(draft);
    }
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await ClipboardService().copy(_ctrl.text);
    if (mounted) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑话术'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制',
            onPressed: _copy,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存草稿',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final navigator = Navigator.of(context);
              await _autoSave();
              _saved = true;
              if (mounted) {
                messenger.showSnackBar(
                  const SnackBar(
                      content: Text('草稿已保存'),
                      duration: Duration(seconds: 1)),
                );
                navigator.pop();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(height: 1.6),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: '编辑你的话术...',
                ),
              ),
            ),
          ),
          // 底部工具栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.2)),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '${_ctrl.text.length} 字',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await _autoSave();
                    _saved = true;
                    if (mounted) navigator.pop();
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('完成'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
