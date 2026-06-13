/// Chat-Helper 应用常量与枚举定义（统一配置中心）
class AppConstants {
  AppConstants._();

  // ==================== MethodChannel 协议版本 ====================
  /// Dart ↔ Java 通信协议版本号
  /// 任一端升级时需同步更新，不匹配时触发优雅降级
  static const int protocolVersion = 1;

  /// MethodChannel 名称（Dart/Java 两端必须一致）
  static const String channelName = 'com.chathelper/floating_ball';

  // ==================== 截图相关 ====================
  static const int screenshotQuality = 85;
  static const int screenshotMaxWidth = 1080;

  // ==================== AI 调用相关 ====================
  static const int visionTimeoutSeconds = 60;
  static const int maxSuggestions = 3;

  // ==================== 悬浮球状态恢复延迟 ====================
  /// onResume 时等待重建悬浮球的延迟（ms）
  static const int ballRestoreDelayMs = 500;

  // ==================== 联系人相关 ====================
  static const int contactNameMaxLength = 20;

  // ==================== 草稿相关 ====================
  /// 自动保存到草稿箱的最大条数
  static const int autoSaveDraftMaxCount = 10;

  // ==================== 浮窗自动关闭 ====================
  static const int overlayAutoDismissSeconds = 120;
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

/// AI 分析状态（v2.0 单引擎版）
enum AnalysisStatus {
  idle,
  capturing, // 截图中
  processing, // 豆包单次多任务处理中
  done,
  error,
}

/// 格式化时间为相对时间字符串（统一版本）
String formatRelativeTime(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  return '${(diff.inDays / 30).floor()} 个月前';
}
