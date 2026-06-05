class Contact {
  final String id;
  String name;
  String? avatarUri;
  String? relationship;
  String? gender;
  String? notes;
  String tonePreference;
  String lengthPreference;
  double creativityPreference;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? lastActiveAt;

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
    );
  }
}
