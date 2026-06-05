import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:collection/collection.dart';
import '../../main.dart';
import '../../data/database.dart';
import '../../data/models/contact.dart';
import '../../data/models/draft.dart';
import '../../ui/theme/app_theme.dart';
import '../../services/platform_service.dart';
import 'contacts_screen.dart';
import 'memory_timeline_screen.dart';
import 'draft_editor_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentTab = 0;

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final db = AppDatabase.instance;

    return Scaffold(
      body: IndexedStack(
        index: _currentTab,
        children: [
          _ContactsTab(db: db),
          _MemoriesTab(db: db),
          _DraftsTab(db: db),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (i) => setState(() => _currentTab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people), label: '联系人'),
          NavigationDestination(
              icon: Icon(Icons.history), label: '记录'),
          NavigationDestination(
              icon: Icon(Icons.edit_note), label: '草稿'),
          NavigationDestination(
              icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

// ---- 联系人Tab ----
class _ContactsTab extends StatefulWidget {
  final AppDatabase db;
  const _ContactsTab({required this.db});

  @override
  State<_ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<_ContactsTab> {
  List<Contact> _contacts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() => _loading = true);
    final contacts = await widget.db.getContacts();
    setState(() {
      _contacts = contacts;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final theme = Theme.of(context);
    final currentContactName = appState.currentContactId != null
        ? _contacts
            .where((c) => c.id == appState.currentContactId)
            .map((c) => c.name)
            .firstOrNull ?? '未选择'
        : '未选择';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat-Helper'),
        actions: [
          // 开启无障碍截图
          IconButton(
            icon: const Icon(Icons.accessibility_new),
            tooltip: '开启截图服务',
            onPressed: () async {
              await context.read<PlatformService>().openAccessibilitySettings();
            },
          ),
          // 悬浮球开关
          IconButton(
            icon: const Icon(Icons.touch_app),
            tooltip: '显示悬浮球',
            onPressed: () async {
              final platform = context.read<PlatformService>();
              await platform.startService();
              await platform.showFloatingBall();
            },
          ),
          if (appState.currentContactId != null)
            Chip(
              avatar: const Icon(Icons.person, size: 18),
              label: Text(currentContactName,
                  style: const TextStyle(fontSize: 12)),
              backgroundColor:
                  theme.colorScheme.primary.withValues(alpha: 0.12),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? _EmptyState(
                  icon: Icons.person_add_alt,
                  title: '还没有联系人',
                  subtitle: '创建联系人档案，开始记录对话',
                  actionLabel: '创建第一个联系人',
                  onAction: () => _addContact(context),
                )
              : RefreshIndicator(
                  onRefresh: _loadContacts,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    itemCount: _contacts.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '当前沟通对象: $currentContactName',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.primary),
                          ),
                        );
                      }
                      final contact = _contacts[index - 1];
                      final isActive =
                          contact.id == appState.currentContactId;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isActive
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
                            child: Text(
                              contact.name.isNotEmpty ? contact.name[0] : '?',
                              style: TextStyle(
                                color: isActive
                                    ? Colors.white
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          title: Row(
                            children: [
                              Text(contact.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              if (isActive) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.check_circle,
                                    size: 18,
                                    color: theme.colorScheme.primary),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            contact.relationship ?? '未分类',
                            style: theme.textTheme.bodySmall,
                          ),
                          trailing: contact.lastActiveAt != null
                              ? Text(
                                  formatRelativeTime(contact.lastActiveAt!),
                                  style: theme.textTheme.bodySmall,
                                )
                              : null,
                          onTap: () {
                            appState.setCurrentContact(contact.id);
                            widget.db.touchContact(contact.id);
                            _loadContacts();
                          },
                          onLongPress: () => _showContactActions(
                              context, contact),
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addContact(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _addContact(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddEditContactScreen(
          onSaved: _loadContacts,
        ),
      ),
    );
  }

  void _showContactActions(BuildContext context, Contact contact) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AddEditContactScreen(
                      contact: contact,
                      onSaved: _loadContacts,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('查看对话记录'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        MemoryTimelineScreen(contactId: contact.id),
                  ),
                );
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete, color: AppTheme.error),
              title: const Text('删除联系人',
                  style: TextStyle(color: AppTheme.error)),
              onTap: () async {
                // 同步使用 BuildContext 必须先于 await
                final outerContext = context;
                Navigator.pop(outerContext);
                final appState = outerContext.read<AppState>();

                final confirm = await showDialog<bool>(
                  context: outerContext,
                  builder: (dialogCtx) => AlertDialog(
                    title: const Text('确认删除'),
                    content: Text(
                        '将删除"${contact.name}"及其所有对话记录，此操作不可恢复。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, true),
                          child: const Text('删除',
                              style: TextStyle(color: AppTheme.error))),
                    ],
                  ),
                );
                if (confirm == true) {
                  await widget.db.deleteContact(contact.id);
                  if (appState.currentContactId == contact.id) {
                    appState.setCurrentContact(null);
                  }
                  if (mounted) {
                    _loadContacts();
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---- 对话记录Tab ----
class _MemoriesTab extends StatelessWidget {
  final AppDatabase db;
  const _MemoriesTab({required this.db});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('对话记录')),
      body: appState.currentContactId == null
          ? const _EmptyState(
              icon: Icons.history,
              title: '未选择联系人',
              subtitle: '请先在"联系人"中创建并选择一个联系人',
            )
          : MemoryTimelineScreen(contactId: appState.currentContactId!),
    );
  }
}

// ---- 草稿Tab ----
class _DraftsTab extends StatefulWidget {
  final AppDatabase db;
  const _DraftsTab({required this.db});

  @override
  State<_DraftsTab> createState() => _DraftsTabState();
}

class _DraftsTabState extends State<_DraftsTab> {
  List<Draft> _drafts = [];
  bool _loading = true;
  List<Contact> _contacts = [];

  @override
  void initState() {
    super.initState();
    _loadDrafts();
  }

  Future<void> _loadDrafts() async {
    setState(() => _loading = true);
    final drafts = await widget.db.getDrafts();
    final contacts = await widget.db.getContacts();
    setState(() {
      _drafts = drafts;
      _contacts = contacts;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('话术草稿')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _drafts.isEmpty
              ? const _EmptyState(
                  icon: Icons.edit_note,
                  title: '暂无草稿',
                  subtitle: '编辑AI建议时会自动保存为草稿',
                )
              : RefreshIndicator(
                  onRefresh: _loadDrafts,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _drafts.length,
                    itemBuilder: (context, index) {
                      final draft = _drafts[index];
                      final contact = _contacts
                          .where((c) => c.id == draft.contactId)
                          .firstOrNull;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text(
                            draft.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            contact != null
                                ? '与 ${contact.name} · ${formatRelativeTime(draft.updatedAt)}'
                                : formatRelativeTime(draft.updatedAt),
                            style: theme.textTheme.bodySmall,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () async {
                              await widget.db.deleteDraft(draft.id);
                              _loadDrafts();
                            },
                          ),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DraftEditorScreen(
                                  initialContent: draft.content,
                                  contactId: draft.contactId,
                                  draftId: draft.id,
                                ),
                              ),
                            );
                            _loadDrafts();
                          },
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

// ---- 空状态组件 ----
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 64,
                color: theme.colorScheme.primary.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.6)),
                textAlign: TextAlign.center),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 公共工具：格式化为相对时间
String formatRelativeTime(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays < 1) return '${diff.inHours}小时前';
  return '${diff.inDays}天前';
}
