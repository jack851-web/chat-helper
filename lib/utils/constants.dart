/// Chat-Helper 应用常量与枚举定义
class AppConstants {
  AppConstants._();

  // 悬浮球
  static const double floatingBallDefaultSize = 48.0;
  static const double floatingBallMinSize = 40.0;
  static const double floatingBallMaxSize = 56.0;
  static const double floatingBallEdgeMargin = 16.0;
  static const double floatingBallSemiTransparentAlpha = 0.6;
  static const int floatingBallIdleTransparentDelayMs = 3000;

  // 截图
  static const int screenshotQuality = 85;
  static const int screenshotMaxWidth = 1080;

  // AI-1 规则引擎
  static const double midlineThreshold = 0.5;
  static const int maxExtractMessages = 20;
  static const double dedupSimilarityThreshold = 0.3;
  static const int dedupTimeWindowMinutes = 2;

  // AI-2 建议引擎
  static const int defaultHistoryRounds = 50;
  static const int maxSuggestions = 3;
  static const int apiTimeoutSeconds = 30;

  // 记忆库
  static const int recentFullRounds = 10;
  static const int summaryRounds = 20;

  // 联系人
  static const int contactNameMaxLength = 20;
}

/// 关系分类
enum ContactRelationship {
  friend('朋友'),
  colleague('同事'),
  family('家人'),
  crush('暧昧对象'),
  classmate('同学'),
  custom('自定义');

  final String label;
  const ContactRelationship(this.label);
}

/// AI 语气偏好
enum TonePreference {
  casual('轻松随意'),
  formal('正式得体'),
  humorous('幽默风趣'),
  gentle('温柔体贴'),
  neutral('自然中性');

  final String label;
  const TonePreference(this.label);
}

/// 回复长度偏好
enum LengthPreference {
  short('一句话'),
  medium('两三句'),
  long('详细展开');

  final String label;
  const LengthPreference(this.label);
}

/// AI分析状态
enum AnalysisStatus {
  idle,
  capturing,
  ocrProcessing,
  parsing,
  aiProcessing,
  done,
  error,
}
