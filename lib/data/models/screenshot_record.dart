class ScreenshotRecord {
  final String id;
  final String? contactId;
  final String filePath;
  final String? thumbnailPath;
  final String? ai1ResultJson;
  final String ai1Status; // pending | processing | done | error
  final String? ai1Error;
  final String parseConfidence; // high | low
  final DateTime createdAt;

  ScreenshotRecord({
    required this.id,
    this.contactId,
    required this.filePath,
    this.thumbnailPath,
    this.ai1ResultJson,
    this.ai1Status = 'pending',
    this.ai1Error,
    this.parseConfidence = 'high',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'contact_id': contactId,
        'file_path': filePath,
        'thumbnail_path': thumbnailPath,
        'ai1_result_json': ai1ResultJson,
        'ai1_status': ai1Status,
        'ai1_error': ai1Error,
        'parse_confidence': parseConfidence,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory ScreenshotRecord.fromMap(Map<String, dynamic> map) => ScreenshotRecord(
        id: map['id'] as String,
        contactId: map['contact_id'] as String?,
        filePath: map['file_path'] as String,
        thumbnailPath: map['thumbnail_path'] as String?,
        ai1ResultJson: map['ai1_result_json'] as String?,
        ai1Status: map['ai1_status'] as String? ?? 'pending',
        ai1Error: map['ai1_error'] as String?,
        parseConfidence: map['parse_confidence'] as String? ?? 'high',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      );
}
