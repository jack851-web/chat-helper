# Chat-Helper

智能聊天辅助工具 — 悬浮球截图 + AI 话术建议。

> **当前版本**：v2.5（UI深度优化版）
>
> **PRD 版本**：v2.5（见 [PRD.md](PRD.md) §15 UI优化路线图）

---

## 一句话定位

常驻桌面悬浮球，一键截图识别聊天内容，AI 生成回复建议，帮你快速想好怎么回。**全程无需切回 App，浮窗直接浮在聊天界面上方。**

## 核心功能

| 功能 | 状态 | 说明 |
|------|------|------|
| 无感截图 (AccessibilityService) | ✅ 已实现 | Android 11+，不弹录制对话框 |
| 悬浮球拖拽 + 点击触发 + 状态动画 | ✅ 已实现 | 四状态动画(空闲/处理中/成功/失败) + 进度阶段提示 |
| **状态同步修复** (v2.5) | ✅ 已实现 | 返回App后球不再错误变空闲，onResume自动恢复处理状态 |
| **进度阶段提示** (v2.5) | ✅ 已实现 | 三阶段动态文字: 识别中→识别对话中→生成建议中 |
| **联系人标签** (v2.5) | ✅ 已实现 | 悬浮球旁显示当前选中联系人名字 |
| **草稿入口增强** (v2.5) | ✅ 已实现 | 建议浮窗新增"存入草稿"按钮 |
| **悬浮球保活/自恢复** (v2.5) | ✅ 已实现 | App被杀重启后自动重建悬浮球 |
| AI 对话提取 + 回复建议 (豆包 Seed Vision) | ✅ 已实现 | 单次调用完成对话提取+建议生成 |
| 增量去重 (防重复入库) | ✅ 已实现 | 基于最近6条记忆比对 |
| 全局原生浮窗卡片 (WindowManager) | ✅ 已实现 | 聊天App上方弹出，含换一批/存入草稿/复制功能 |
| 三大场景自动判断 (A/B/C) | ✅ 已实现 | 待回复/主动发起/延续追加 |
| 联系人档案管理 | ✅ 已实现 | CRUD + 语气/长度/创意度偏好 |
| 话术草稿编辑器 | ✅ 已实现 | 预填AI建议，自由修改，自动保存 |
| 历史对话记录 | ✅ 已实现 | 时间线视图 + 搜索 + 删除 |
| 设置页 (API Key / 模型 / 浮窗时间 / 快速回复) | ✅ 已实现 | 豆包配置完整 |
| 网络预检 + 异常分类 | ✅ 已实现 | 无网立即提示 / 四类异常精准提示 |
| **JSON修复性解析** (v2.5) | ✅ 已实现 | 6级容错: Markdown提取→边界定位→尾逗号→截断补全→部分提取兜底 |
| **常量统一配置中心** (v2.5) | ✅ 已实现 | AppConstants 统一管理 Dart/Java 关键常量 |
| **MethodChannel协议版本协商** (v2.5) | ✅ 已实现 | 启动时检测两端兼容性 |
| 深色模式 | ✅ 已实现 | 浅色/深色主题切换 |

## 技术栈

| 层 | 技术 |
|----|------|
| **跨端框架** | Flutter (Dart) |
| **平台** | Android（依赖 AccessibilityService / WindowManager） |
| **云端 AI** | 火山引擎 豆包 Seed Vision (`ark.cn-beijing.volces.com`) |
| **本地存储** | SQLite (sqflite) |
| **安全存储** | flutter_secure_storage (API Key) |
| **状态管理** | Provider |

## 项目结构

```
chat-helper/
├── android/                          # Android 原生层
│   └── app/src/main/java/com/chathelper/app/
│       ├── MainActivity.java          # Flutter↔Native通信桥接 + 悬浮球管理
│       ├── FloatingBallService.java   # 悬浮球服务(WindowManager)
│       └── ScreenshotAccessibilityService.java  # 无感截图服务
├── lib/
│   ├── main.dart                      # 入口 + 路由 + 协议版本检查
│   ├── app.dart                       # Provider状态初始化
│   ├── data/
│   │   ├── database.dart              # SQLite数据库管理
│   │   └── models/                    # 数据模型(Contact/Screenshot/Suggestion/Memory/Draft)
│   ├── services/
│   │   ├── platform_service.dart      # 核心业务流程编排(截图→AI→落库)
│   │   ├── vision_service.dart        # 豆包AI单次多任务调用 + 提示词构建
│   │   └── clipboard_service.dart     # 剪贴板操作
│   ├── utils/
│   │   ├── constants.dart             # 统一配置中心(AppConstants)
│   │   └── json_utils.dart            # JSON修复性解析(6级容错)
│   └── ui/
│       ├── screens/                   # 页面(首页/设置/联系人/历史/草稿)
│       │   ├── home_screen.dart       # Tab导航(IndexedStack)
│       │   ├── contacts_screen.dart   # 联系人CRUD列表
│       │   ├── memory_timeline_screen.dart  # 对话记录时间线
│       │   ├── draft_editor_screen.dart    # 草稿编辑器
│       │   └── settings_screen.dart   # 设置页
│       └── theme/
│           └── app_theme.dart         # 主题定义(浅色/深色)
├── android/app/src/main/res/layout/
│   ├── floating_ball.xml              # 悬浮球布局(圆形+横条+联系人标签)
│   └── suggestion_overlay.xml         # 建议浮窗布局(含存入草稿按钮)
├── assets/images/                     # 图片资源
├── test/                              # 测试
├── PRD.md                             # 产品需求文档(v2.5)
└── pubspec.yaml                       # Flutter项目配置
```

## 快速开始

### 环境要求

- Flutter SDK >= 3.22.0
- Android SDK (API 30+, Android 11+)
- 豆包 API Key（[火山引擎控制台获取](https://console.volcengine.com/ark)）

### 安装运行

```bash
# 1. 克隆仓库
git clone <repo-url>
cd chat-helper

# 2. 安装依赖
flutter pub get

# 3. 连接设备或启动模拟器
flutter devices

# 4. 运行
flutter run
```

### 首次使用步骤

1. **开启无障碍服务**：系统设置 → 无障碍 → 已安装的服务 → 开启 **Chat-Helper**
2. **配置 API Key**：打开 App → 设置 → 填入 **豆包 API Key**
3. **创建联系人**：首页 → 联系人 Tab → 新建联系人并选中
4. **开启悬浮球**：AppBar 左上角菜单 → 开启悬浮球
5. **使用**：在任意聊天 App 中点击悬浮球即可触发截图 + AI 建议

## 使用流程（当前版本 v2.5）

```
聊天App中点击悬浮球
    ↓
Java端前置校验(已选联系人? 冷却?)
    ↓
无感截图 (AccessibilityService)
    ↓
Dart端网络预检(DNS查询, 3s超时)
    ↓
豆包单次多任务调用(一次HTTP请求)
    ├─ 任务A: 视觉对话提取(与最近6条比对→增量落库)
    ├─ 任务B: 场景判断(A/B/C) + 方向分析
    └─ 任务C: 生成3条具体话术建议
    ↓
全局原生浮窗弹出(聊天App上方, WindowManager)
    ├─ 场景标签 + 💡对话思路 + 联系人画像
    ├─ 3条话术(风格+内容+理由) + [复制]
    ├─ [📋存入草稿] (v2.5新增)
    └─ [换一批] / [关闭]
```

## 版本历史

| 版本 | 核心变更 |
|------|----------|
| **v2.5** | 状态同步修复 + 进度阶段提示 + 联系人标签 + 存入草稿按钮 + 悬浮球保活 + JSON 6级容错解析 + 常量统一 + 协议版本协商 + UI全面优化（搜索栏/动画/气泡长按/日期分组/头像着色）+ 全面代码审查清理 |
| **v2.4** | 网络预检 + 异常分类处理 + 死代码清除 + 换一批加载反馈 + 清空防误触升级 + IO并行化 + db封装增强 |
| **v2.3** | 双重截断消除 + UI全量中文化 + Prompt缓存 + 死代码清除 + UUID防碰撞 + 磁盘清理 + 记录恢复 + 前置冷却 |
| **v2.2** | 横向加载条动画 + 3秒自动回退 + 截图前置校验 + 联系人隔离 + 提示词去AI味 + 批量查重 |
| **v2.1** | 模型精简为Seed系列 + 快速回复模式 + Java端直接截图链路 |
| **v2.0** | 双AI(豆包+DeepSeek) → **单AI(豆包)** 架构重构，延时缩短50% |

## 开发计划

详见 [PRD.md](PRD.md) §15 UI体验优化路线图：

- **Phase 1 (P0)**：~~联系人搜索栏~~ / ~~记忆删除Undo~~ — **已完成**
- **Phase 2 (P1)**：~~Tab切换动画~~ / ~~头像差异化着色~~ / ~~气泡长按菜单~~ / ~~日期分组~~ / 浮窗动画 / 下拉刷新 / 选中反馈 — **大部分已完成**
- **Phase 3 (P2)**：设置页折叠 / FAB扩展 / Badge徽标 / 骨架屏 / 首次引导

## License

MIT
