class ScreenshotRecord {
  final String id;
  final String? contactId;
  final String filePath;
  final String? thumbnailPath;
  final String? ai1ResultJson;
  final String ai1Status; // pending | processing | done | error | no_new
  final String? ai1Error;
  final String parseConfidence; // high | low
  final DateTime createdAt;

  // ---- V2 字段（豆包单次多任务调用结果）----
  final String? scene;              // A | B | C
  final String? sceneDescription;
  final String? contactInsight;     // 联系人画像摘要
  final String? direction;          // 对话方向
  final int? durationMs;            // AI 调用耗时

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
    this.scene,
    this.sceneDescription,
    this.contactInsight,
    this.direction,
    this.durationMs,
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
        'scene': scene,
        'scene_description': sceneDescription,
        'contact_insight': contactInsight,
        'direction': direction,
        'duration_ms': durationMs,
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
        scene: map['scene'] as String?,
        sceneDescription: map['scene_description'] as String?,
        contactInsight: map['contact_insight'] as String?,
        direction: map['direction'] as String?,
        durationMs: map['duration_ms'] as int?,
      );

  ScreenshotRecord copyWith({
    String? ai1Status,
    String? ai1Error,
    String? ai1ResultJson,
    String? parseConfidence,
    String? scene,
    String? sceneDescription,
    String? contactInsight,
    String? direction,
    int? durationMs,
  }) {
    return ScreenshotRecord(
      id: id,
      contactId: contactId,
      filePath: filePath,
      thumbnailPath: thumbnailPath,
      ai1ResultJson: ai1ResultJson ?? this.ai1ResultJson,
      ai1Status: ai1Status ?? this.ai1Status,
      ai1Error: ai1Error ?? this.ai1Error,
      parseConfidence: parseConfidence ?? this.parseConfidence,
      createdAt: createdAt,
      scene: scene ?? this.scene,
      sceneDescription: sceneDescription ?? this.sceneDescription,
      contactInsight: contactInsight ?? this.contactInsight,
      direction: direction ?? this.direction,
      durationMs: durationMs ?? this.durationMs,
    );
  }
}
