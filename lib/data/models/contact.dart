class Contact {
  final String id;
  final String name;
  final String? avatarUri;
  final String? relationship;
  final String? gender;
  final String? notes;
  final String tonePreference;
  final String lengthPreference;
  final double creativityPreference;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastActiveAt;

  // ---- V2 字段：联系人画像 ----
  /// 豆包最近一次生成的画像摘要（覆盖式更新）
  final String? latestInsight;
  /// 画像更新时间
  final DateTime? insightUpdatedAt;

  Contact({
    required this.id,
    required this.name,
    this.avatarUri,
    this.relationship,
    this.gender,
    this.notes,
    this.tonePreference = 'neutral',
    this.lengthPreference = 'medium',
    this.creativityPreference = 0.5,
    required this.createdAt,
    required this.updatedAt,
    this.lastActiveAt,
    this.latestInsight,
    this.insightUpdatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'avatar_uri': avatarUri,
        'relationship': relationship,
        'gender': gender,
        'notes': notes,
        'tone_preference': tonePreference,
        'length_preference': lengthPreference,
        'creativity_preference': creativityPreference,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'last_active_at': lastActiveAt?.millisecondsSinceEpoch,
        'latest_insight': latestInsight,
        'insight_updated_at': insightUpdatedAt?.millisecondsSinceEpoch,
      };

  factory Contact.fromMap(Map<String, dynamic> map) {
    String? safeStr(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    int safeInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    return Contact(
      id: safeStr(map['id']) ?? '',
      name: safeStr(map['name']) ?? '',
      avatarUri: safeStr(map['avatar_uri']),
      relationship: safeStr(map['relationship']),
      gender: safeStr(map['gender']),
      notes: safeStr(map['notes']),
      tonePreference: safeStr(map['tone_preference']) ?? 'neutral',
      lengthPreference: safeStr(map['length_preference']) ?? 'medium',
      creativityPreference:
          (map['creativity_preference'] as num?)?.toDouble() ?? 0.5,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(safeInt(map['created_at'])),
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(safeInt(map['updated_at'])),
      lastActiveAt: map['last_active_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(safeInt(map['last_active_at']))
          : null,
      latestInsight: safeStr(map['latest_insight']),
      insightUpdatedAt: map['insight_updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(safeInt(map['insight_updated_at']))
          : null,
    );
  }

  Contact copyWith({
    String? name,
    String? avatarUri,
    String? relationship,
    String? gender,
    String? notes,
    String? tonePreference,
    String? lengthPreference,
    double? creativityPreference,
    DateTime? lastActiveAt,
    String? latestInsight,
    DateTime? insightUpdatedAt,
  }) {
    return Contact(
      id: id,
      name: name ?? this.name,
      avatarUri: avatarUri ?? this.avatarUri,
      relationship: relationship ?? this.relationship,
      gender: gender ?? this.gender,
      notes: notes ?? this.notes,
      tonePreference: tonePreference ?? this.tonePreference,
      lengthPreference: lengthPreference ?? this.lengthPreference,
      creativityPreference: creativityPreference ?? this.creativityPreference,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      latestInsight: latestInsight ?? this.latestInsight,
      insightUpdatedAt: insightUpdatedAt ?? this.insightUpdatedAt,
    );
  }
}
