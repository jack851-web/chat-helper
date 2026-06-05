class ChatMemory {
  final String id;
  final String contactId;
  final String? screenshotId;
  final String speaker; // 'me' | 'partner'
  final String content;
  final DateTime? timestampEstimate;
  final String? platform;
  final DateTime createdAt;
  final bool isDeleted;

  ChatMemory({
    required this.id,
    required this.contactId,
    this.screenshotId,
    required this.speaker,
    required this.content,
    this.timestampEstimate,
    this.platform,
    required this.createdAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'contact_id': contactId,
        'screenshot_id': screenshotId,
        'speaker': speaker,
        'content': content,
        'timestamp_estimate': timestampEstimate?.millisecondsSinceEpoch,
        'platform': platform,
        'created_at': createdAt.millisecondsSinceEpoch,
        'is_deleted': isDeleted ? 1 : 0,
      };

  factory ChatMemory.fromMap(Map<String, dynamic> map) => ChatMemory(
        id: map['id'] as String,
        contactId: map['contact_id'] as String,
        screenshotId: map['screenshot_id'] as String?,
        speaker: map['speaker'] as String,
        content: map['content'] as String,
        timestampEstimate: map['timestamp_estimate'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                map['timestamp_estimate'] as int)
            : null,
        platform: map['platform'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
        isDeleted: (map['is_deleted'] as int?) == 1,
      );
}
