import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../data/database.dart';
import '../../data/models/contact.dart';
import '../../utils/constants.dart';

class AddEditContactScreen extends StatefulWidget {
  final Contact? contact;
  final VoidCallback? onSaved;

  const AddEditContactScreen({super.key, this.contact, this.onSaved});

  @override
  State<AddEditContactScreen> createState() => _AddEditContactScreenState();
}

class _AddEditContactScreenState extends State<AddEditContactScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _notesCtrl;
  String? _relationship;
  String? _gender;
  String _tone = 'neutral';
  String _lengthPref = 'medium';
  double _creativity = 0.5;

  bool get _isEditing => widget.contact != null;

  @override
  void initState() {
    super.initState();
    final c = widget.contact;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _notesCtrl = TextEditingController(text: c?.notes ?? '');
    // 安全兜底：确保 dropdown value 一定在 items 集合中
    _relationship = _safeDropdownValue(c?.relationship, ContactRelationship.values, null);
    _gender = _safeDropdownValue(c?.gender, ['male', 'female', 'other'], null);
    _tone = _safeDropdownValue(c?.tonePreference, TonePreference.values, 'neutral')!;
    _lengthPref = _safeDropdownValue(c?.lengthPreference, LengthPreference.values, 'medium')!;
    _creativity = c?.creativityPreference ?? 0.5;
  }

  /// 如果 value 在 validValues 中则返回原值，否则返回 fallback
  String? _safeDropdownValue(String? value, Iterable<dynamic> validValues, String? fallback) {
    if (value == null) return fallback;
    for (final v in validValues) {
      final name = v is Enum ? v.name : v.toString();
      if (name == value) return value;
    }
    return fallback;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑联系人' : '新建联系人'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 头像
              Center(
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor:
                          theme.colorScheme.primary.withValues(alpha: 0.16),
                      child: Text(
                        _nameCtrl.text.isNotEmpty
                            ? _nameCtrl.text[0]
                            : '?',
                        style: TextStyle(
                            fontSize: 32,
                            color: theme.colorScheme.primary),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: theme.colorScheme.primary,
                        child: const Icon(Icons.camera_alt,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 姓名
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '姓名/昵称 *',
                  hintText: '输入联系人的名称',
                  prefixIcon: Icon(Icons.person),
                ),
                maxLength: AppConstants.contactNameMaxLength,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入姓名' : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              // 关系分类
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: _relationship,
                decoration: const InputDecoration(
                  labelText: '关系分类',
                  prefixIcon: Icon(Icons.label),
                ),
                items: ContactRelationship.values.map((r) {
                  return DropdownMenuItem(
                    value: r.name,
                    child: Text(r.label),
                  );
                }).toList(),
                onChanged: (v) => setState(() => _relationship = v),
              ),
              const SizedBox(height: 16),

              // 性别
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: _gender,
                decoration: const InputDecoration(
                  labelText: '性别（可选）',
                  prefixIcon: Icon(Icons.wc),
                ),
                items: const [
                  DropdownMenuItem(value: 'male', child: Text('男')),
                  DropdownMenuItem(value: 'female', child: Text('女')),
                  DropdownMenuItem(value: 'other', child: Text('其他')),
                ],
                onChanged: (v) => setState(() => _gender = v),
              ),
              const SizedBox(height: 16),

              // 备注
              TextFormField(
                controller: _notesCtrl,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '性格特点、话题偏好等...',
                  prefixIcon: Icon(Icons.notes),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 24),

              // AI参数
              Text('AI 对话偏好',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),

              // 语气
              _buildPreferenceRow(
                label: '默认语气',
                value: _tone,
                options: TonePreference.values
                    .map((t) => (t.name, t.label))
                    .toList(),
                onChanged: (v) => setState(() => _tone = v),
                theme: theme,
              ),
              const SizedBox(height: 8),

              // 长度
              _buildPreferenceRow(
                label: '回复长度',
                value: _lengthPref,
                options: LengthPreference.values
                    .map((l) => (l.name, l.label))
                    .toList(),
                onChanged: (v) => setState(() => _lengthPref = v),
                theme: theme,
              ),
              const SizedBox(height: 8),

              // 创意度
              Row(
                children: [
                  SizedBox(
                    width: 80,
                    child: Text('创意度', style: theme.textTheme.bodyMedium),
                  ),
                  Expanded(
                    child: Slider(
                      value: _creativity,
                      min: 0,
                      max: 1,
                      divisions: 10,
                      label: (_creativity * 10).round().toString(),
                      onChanged: (v) =>
                          setState(() => _creativity = v),
                    ),
                  ),
                  SizedBox(
                    width: 50,
                    child: Text(
                      _creativity < 0.33
                          ? '保守'
                          : _creativity < 0.66
                              ? '均衡'
                              : '大胆',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreferenceRow({
    required String label,
    required String value,
    required List<(String, String)> options,
    required ValueChanged<String> onChanged,
    required ThemeData theme,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            children: options.map((opt) {
              final selected = value == opt.$1;
              return ChoiceChip(
                label: Text(opt.$2, style: const TextStyle(fontSize: 13)),
                selected: selected,
                onSelected: (_) => onChanged(opt.$1),
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final db = AppDatabase.instance;
    final now = DateTime.now();

    if (_isEditing) {
      final updated = widget.contact!.copyWith(
        name: _nameCtrl.text.trim(),
        notes: _notesCtrl.text.trim(),
        relationship: _relationship,
        gender: _gender,
        tonePreference: _tone,
        lengthPreference: _lengthPref,
        creativityPreference: _creativity,
      );
      await db.updateContact(updated);
    } else {
      final contact = Contact(
        id: const Uuid().v4(),
        name: _nameCtrl.text.trim(),
        relationship: _relationship,
        gender: _gender,
        notes: _notesCtrl.text.trim(),
        tonePreference: _tone,
        lengthPreference: _lengthPref,
        creativityPreference: _creativity,
        createdAt: now,
        updatedAt: now,
      );
      await db.insertContact(contact);
    }

    widget.onSaved?.call();
    if (mounted) Navigator.pop(context);
  }
}
