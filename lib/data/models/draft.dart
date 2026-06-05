class Draft {
  final String id;
  final String? contactId;
  final String? suggestionId;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  Draft({
    required this.id,
    this.contactId,
    this.suggestionId,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'contact_id': contactId,
        'suggestion_id': suggestionId,
        'content': content,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory Draft.fromMap(Map<String, dynamic> map) => Draft(
        id: map['id'] as String,
        contactId: map['contact_id'] as String?,
        suggestionId: map['suggestion_id'] as String?,
        content: map['content'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
      );
}
