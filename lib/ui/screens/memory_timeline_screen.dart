import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/clipboard_service.dart';
import '../../data/database.dart';
import '../../data/models/chat_memory.dart';
import '../theme/app_theme.dart';

class MemoryTimelineScreen extends StatefulWidget {
  final String contactId;

  const MemoryTimelineScreen({super.key, required this.contactId});

  @override
  State<MemoryTimelineScreen> createState() => _MemoryTimelineScreenState();
}

class _MemoryTimelineScreenState extends State<MemoryTimelineScreen> {
  final _searchCtrl = TextEditingController();
  List<ChatMemory> _memories = [];
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadMemories();
  }

  @override
  void didUpdateWidget(MemoryTimelineScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换联系人时自动重新加载
    if (oldWidget.contactId != widget.contactId) {
      _searchCtrl.clear();
      _loadMemories();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMemories({String? keyword}) async {
    setState(() => _loading = true);
    final db = AppDatabase.instance;
    List<ChatMemory> memories;
    if (keyword != null && keyword.isNotEmpty) {
      memories = await db.searchMemories(
          keyword: keyword, contactId: widget.contactId);
    } else {
      memories = await db.getAllMemories(widget.contactId);
    }
    setState(() {
      _memories = memories;
      _loading = false;
    });
  }

  /// 判断两个时间是否同一天
  static bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// 生成日期分组标签
  static String _dateGroupLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(date.year, date.month, date.day);

    if (dateDay == today) return '今天';
    if (dateDay == today.subtract(const Duration(days: 1))) return '昨天';

    // 更早的日期显示 "MM月dd日"
    return '${date.month}月${date.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // 搜索栏
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: '搜索对话内容...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        _loadMemories();
                      },
                    )
                  : null,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (v) {
              setState(() {});
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () {
                _loadMemories(keyword: v);
              });
            },
          ),
        ),

        // 清除按钮
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text('共 ${_memories.length} 条记录',
                  style: theme.textTheme.bodySmall),
              const Spacer(),
              if (_memories.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.warning_amber_rounded, size: 16),
                  label: const Text('清空全部记录', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                    side: const BorderSide(color: AppTheme.error),
                  ),
                  onPressed: () async {
                    final outerContext = context;
                    final confirm = await showDialog<bool>(
                      context: outerContext,
                      builder: (dialogCtx) => AlertDialog(
                        title: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: AppTheme.error),
                            const SizedBox(width: 8),
                            const Text('危险操作确认'),
                          ],
                        ),
                        content: Text(
                          '即将永久删除该联系人的所有对话记录（共 ${_memories.length} 条），此操作不可恢复！',
                        ),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(dialogCtx, false),
                              child: const Text('取消')),
                          FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: AppTheme.error),
                              onPressed: () => Navigator.pop(dialogCtx, true),
                              child: const Text('确认删除')),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await AppDatabase.instance
                          .clearContactMemories(widget.contactId);
                      if (mounted) {
                        _loadMemories(
                            keyword: _searchCtrl.text.isNotEmpty
                                ? _searchCtrl.text
                                : null);
                      }
                    }
                  },
                ),
            ],
          ),
        ),

        // 列表
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _memories.isEmpty
                  ? Center(
                      child: Text(
                        _searchCtrl.text.isNotEmpty
                            ? '未搜索到匹配的记录'
                            : '暂无对话记录\n截图开始聊天后自动保存',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.5)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _memories.length * 2, // 每条记忆 + 可能的日期标题
                      itemBuilder: (context, index) {
                        final memIndex = index ~/ 2;
                        if (index.isOdd) {
                          // 奇数位：日期分组标题
                          if (memIndex >= _memories.length)
                            return const SizedBox.shrink();
                          final memory = _memories[memIndex];
                          final dateLabel = _dateGroupLabel(memory.createdAt);
                          // 如果和上一条是同一天，不显示标题
                          if (memIndex > 0 &&
                              _isSameDay(_memories[memIndex - 1].createdAt,
                                  memory.createdAt)) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: theme
                                      .colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(dateLabel,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.outline)),
                              ),
                            ),
                          );
                        }
                        // 偶数位：气泡内容
                        if (memIndex >= _memories.length)
                          return const SizedBox.shrink();
                        final memory = _memories[memIndex];
                        final isMe = memory.speaker == 'me';
                        return _MemoryBubble(
                          memory: memory,
                          isMe: isMe,
                          onDelete: () async {
                            // 先从本地列表移除（即时视觉反馈）
                            final removed = memory;
                            setState(() {
                              _memories.removeWhere((m) => m.id == removed.id);
                            });
                            // 显示 SnackBar + 撤回按钮
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: const Text('已删除该条记录'),
                              duration: const Duration(seconds: 3),
                              action: SnackBarAction(
                                label: '撤回',
                                textColor: theme.colorScheme.inversePrimary,
                                onPressed: () {
                                  // 撤回：重新加回列表
                                  if (!mounted) return;
                                  setState(() {
                                    _memories.insert(memIndex, removed);
                                    // 按时间排序保持正确顺序
                                    _memories.sort((a, b) =>
                                        b.createdAt.compareTo(a.createdAt));
                                  });
                                },
                              ),
                            ));
                            // 3秒后真正执行数据库删除（SnackBar 自动消失时）
                            await Future.delayed(const Duration(seconds: 3));
                            if (!mounted) return;
                            // 级联删除 - 物理清理截图 PII
                            await AppDatabase.instance
                                .deleteMemoryCascade(removed.id);
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _MemoryBubble extends StatelessWidget {
  final ChatMemory memory;
  final bool isMe;
  final VoidCallback onDelete;

  const _MemoryBubble({
    required this.memory,
    required this.isMe,
    required this.onDelete,
  });

  /// 长按弹出操作菜单
  void _showContextMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制内容'),
              onTap: () {
                ClipboardService().copy(memory.content);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete,
                  color: Theme.of(context).colorScheme.error),
              title: Text('删除',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
              child: const Icon(Icons.person, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () => _showContextMenu(context),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 280),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isMe
                      ? theme.colorScheme.primary.withValues(alpha: 0.12)
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(memory.content, style: theme.textTheme.bodyMedium),
                    if (memory.timestampEstimate != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${memory.timestampEstimate!.hour.toString().padLeft(2, '0')}:${memory.timestampEstimate!.minute.toString().padLeft(2, '0')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.4),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primary,
              child: const Icon(Icons.person, size: 16, color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }
}
