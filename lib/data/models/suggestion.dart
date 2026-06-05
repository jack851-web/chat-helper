class Suggestion {
  final String id;
  final String contactId;
  final String? screenshotId;
  final String style;
  final String content;
  final String? reason;
  final bool isFavorited;
  final bool isCopied;
  final DateTime createdAt;

  Suggestion({
    required this.id,
    required this.contactId,
    this.screenshotId,
    required this.style,
    required this.content,
    this.reason,
    this.isFavorited = false,
    this.isCopied = false,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'contact_id': contactId,
        'screenshot_id': screenshotId,
        'style': style,
        'content': content,
        'reason': reason,
        'is_favorited': isFavorited ? 1 : 0,
        'is_copied': isCopied ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory Suggestion.fromMap(Map<String, dynamic> map) => Suggestion(
        id: map['id'] as String,
        contactId: map['contact_id'] as String,
        screenshotId: map['screenshot_id'] as String?,
        style: map['style'] as String,
        content: map['content'] as String,
        reason: map['reason'] as String?,
        isFavorited: (map['is_favorited'] as int?) == 1,
        isCopied: (map['is_copied'] as int?) == 1,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      );

  Suggestion copyWith({
    bool? isFavorited,
    bool? isCopied,
  }) {
    return Suggestion(
      id: id,
      contactId: contactId,
      screenshotId: screenshotId,
      style: style,
      content: content,
      reason: reason,
      isFavorited: isFavorited ?? this.isFavorited,
      isCopied: isCopied ?? this.isCopied,
      createdAt: createdAt,
    );
  }
}
