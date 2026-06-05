import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../data/database.dart';
import '../../data/models/suggestion.dart' as model;
import '../../services/ai_service.dart';
import '../../services/clipboard_service.dart';
import 'draft_editor_screen.dart';

/// 建议卡片浮层 - 展示AI生成的回复建议
class SuggestionCard extends StatefulWidget {
  final List<SuggestionItem> suggestions;
  final String contactId;
  final String screenshotId;
  final VoidCallback onRegenerate;
  final VoidCallback onClose;

  const SuggestionCard({
    super.key,
    required this.suggestions,
    required this.contactId,
    required this.screenshotId,
    required this.onRegenerate,
    required this.onClose,
  });

  @override
  State<SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<SuggestionCard> {
  final _clipboard = ClipboardService();
  final List<int> _favorited = [];

  // 复制去重：同一条建议 2 秒内不重复入库
  int _lastCopiedIndex = -1;
  DateTime _lastCopiedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(maxHeight: 500),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖拽指示条
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),

          // 标题
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(Icons.auto_awesome,
                    color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('为你准备了 ${widget.suggestions.length} 条回复建议',
                    style: theme.textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '换一批',
                  onPressed: widget.onRegenerate,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // 建议列表
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: widget.suggestions.length,
              itemBuilder: (context, index) {
                final item = widget.suggestions[index];
                final isFav = _favorited.contains(index);
                return _SuggestionItemCard(
                  suggestion: item,
                  isFavorited: isFav,
                  onCopy: () async {
                    // 避免快速重复点击导致重复插入数据库
                    final lastCopied = _lastCopiedIndex;
                    final now = DateTime.now();
                    if (lastCopied == index &&
                        now.difference(_lastCopiedAt).inSeconds < 2) {
                      return;
                    }
                    _lastCopiedIndex = index;
                    _lastCopiedAt = now;

                    final messenger = ScaffoldMessenger.of(context);
                    await _clipboard.copy(item.content);
                    await _saveSuggestion(item, copied: true);
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('已复制到剪贴板'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  onEdit: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DraftEditorScreen(
                          initialContent: item.content,
                          contactId: widget.contactId,
                        ),
                      ),
                    );
                  },
                  onFavorite: () async {
                    setState(() {
                      if (isFav) {
                        _favorited.remove(index);
                      } else {
                        _favorited.add(index);
                      }
                    });
                    await _saveSuggestion(item, favorited: !isFav);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _saveSuggestion(SuggestionItem item,
      {bool copied = false, bool favorited = false}) async {
    final db = AppDatabase.instance;
    // 查重：同一截图 + 同一内容只保留一条记录，后续操作为 update
    final existing = await db.findSuggestionByContent(
        widget.screenshotId, item.content);
    final now = DateTime.now();
    final suggestion = model.Suggestion(
      id: existing?.id ?? const Uuid().v4(),
      contactId: widget.contactId,
      screenshotId: widget.screenshotId,
      style: item.style,
      content: item.content,
      reason: item.reason,
      isFavorited: favorited || (existing?.isFavorited ?? false),
      isCopied: copied || (existing?.isCopied ?? false),
      createdAt: existing?.createdAt ?? now,
    );
    if (existing == null) {
      await db.insertSuggestion(suggestion);
    } else {
      await db.updateSuggestion(suggestion);
    }
  }
}

class _SuggestionItemCard extends StatelessWidget {
  final SuggestionItem suggestion;
  final bool isFavorited;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onFavorite;

  const _SuggestionItemCard({
    required this.suggestion,
    required this.isFavorited,
    required this.onCopy,
    required this.onEdit,
    required this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 风格标签 + 操作按钮
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    suggestion.style,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                _ActionButton(
                    icon: Icons.copy, tooltip: '复制', onTap: onCopy),
                _ActionButton(
                    icon: Icons.edit, tooltip: '编辑', onTap: onEdit),
                _ActionButton(
                  icon: isFavorited ? Icons.star : Icons.star_border,
                  tooltip: '收藏',
                  onTap: onFavorite,
                  color: isFavorited ? Colors.amber : null,
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 话术正文
            GestureDetector(
              onTap: onCopy,
              child: Text(
                suggestion.content,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(height: 1.5),
              ),
            ),
            const SizedBox(height: 8),

            // 理由
            if (suggestion.reason != null && suggestion.reason!.isNotEmpty)
              Text(
                suggestion.reason!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}
