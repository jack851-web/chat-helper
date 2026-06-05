import 'dart:async';
import 'package:flutter/material.dart';
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
      memories = await db.getMemories(widget.contactId, limit: 200);
    }
    setState(() {
      _memories = memories;
      _loading = false;
    });
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
                TextButton.icon(
                  icon: const Icon(Icons.delete_sweep, size: 16),
                  label: const Text('清空记录', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                      foregroundColor: AppTheme.error),
                  onPressed: () async {
                    final outerContext = context;
                    final confirm = await showDialog<bool>(
                      context: outerContext,
                      builder: (dialogCtx) => AlertDialog(
                        title: const Text('确认清空'),
                        content: const Text('将清空该联系人的所有对话记录，此操作不可恢复。'),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogCtx, false),
                              child: const Text('取消')),
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogCtx, true),
                              child: const Text('清空',
                                  style:
                                      TextStyle(color: AppTheme.error))),
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
                      itemCount: _memories.length,
                      itemBuilder: (context, index) {
                        final memory = _memories[index];
                        final isMe = memory.speaker == 'me';
                        return _MemoryBubble(
                          memory: memory,
                          isMe: isMe,
                          onDelete: () async {
                            // 改用级联删除 - 物理清理截图 PII
                            await AppDatabase.instance
                                .deleteMemoryCascade(memory.id);
                            if (mounted) {
                              _loadMemories(
                                  keyword: _searchCtrl.text.isNotEmpty
                                      ? _searchCtrl.text
                                      : null);
                            }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor:
                  theme.colorScheme.primary.withValues(alpha: 0.2),
              child: const Icon(Icons.person, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
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
                  Text(
                    memory.content,
                    style: theme.textTheme.bodyMedium,
                  ),
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
          if (isMe) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primary,
              child: const Icon(Icons.person, size: 16, color: Colors.white),
            ),
          ],
          // 删除按钮
          GestureDetector(
            onTap: onDelete,
            child: const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.close, size: 14, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
