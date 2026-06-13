package com.chathelper.app;

import android.content.Context;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.net.Uri;
import android.util.Log;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Vibrator;
import android.provider.Settings;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;
import android.content.ClipboardManager;
import android.content.ClipData;
import android.view.WindowManager;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.lang.ref.WeakReference;
import java.util.UUID;
import java.util.Map;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * MainActivity - Floating ball + AccessibilityService screenshot.
 */
public class MainActivity extends FlutterActivity {

    // ==================== 协议版本 ====================
    /** Dart ↔ Java 通信协议版本（需与 AppConstants.protocolVersion 同步） */
    private static final int PROTOCOL_VERSION = 1;

    private static final String CHANNEL = "com.chathelper/floating_ball";
    private static final String SCREENSHOT_CHANNEL = "com.chathelper/screenshot";
    private static final String SCREENSHOT_DIR = "screenshots";

    // State enum
    private static final int STATE_IDLE = 0;
    private static final int STATE_PROCESSING = 1;
    private static final int STATE_SUCCESS = 2;
    private static final int STATE_ERROR = 3;

    // Icon resources
    private static final int ICON_IDLE = R.drawable.ic_chat_ball;
    private static final int ICON_PROCESSING = R.drawable.anim_ball_processing;
    private static final int ICON_SUCCESS = R.drawable.ic_ball_success;
    private static final int ICON_ERROR = R.drawable.ic_ball_error;

    // Auto-reset delay (ms)
    private static final long RESET_DELAY_SUCCESS = 3000L;
    private static final long RESET_DELAY_ERROR = 2000L;

    private View floatingView;
    private WindowManager windowManager;
    private ImageView ballIcon;
    private View ballLoadingBar;      // 横向加载条容器
    private TextView ballLoadingText; // 加载文字
    // 记录变形前的球心 X 坐标，用于横条展开后居中对齐
    private int ballCenterX = -1;
    private Handler uiHandler = new Handler(Looper.getMainLooper());
    // ballState 仅在主线程通过 Handler 回调写入，volatile 保证可见性即可（无需 AtomicInteger）
    private volatile int ballState = STATE_IDLE;
    // screenshotBusy 可能从 AccessibilityService 回调线程写入，需原子操作
    private final AtomicBoolean screenshotBusy = new AtomicBoolean(false);
    private Runnable pendingResetRunnable;
    private MethodChannel dartChannel; // 缓存：避免 notifyDart/triggerScreenshot 重复创建

    // Drag throttling: limit updateViewLayout to ~60fps max
    private long lastDragUpdateTime = 0;
    private static final long DRAG_THROTTLE_MS = 16; // ~60fps

    // Screenshot cooldown: prevent rapid repeated clicks (waste API calls)
    private long lastScreenshotTime = 0;
    private static final long SCREENSHOT_COOLDOWN_MS = 3000L; // 3 seconds

    // 联系人标签（悬浮球旁显示当前选中联系人名字）
    private String currentContactName = null;

    // Dart 端是否正在处理任务（用于 onResume 恢复球状态）
    private boolean dartIsProcessing = false;

    // Suggestion overlay window
    private View suggestionOverlay;
    private WindowManager overlayManager;
    private int remainingSeconds;
    private int countdownTotalSeconds;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        AppEventBus.floatingBallRequest = this::showFloatingBall;

        dartChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL);
        dartChannel.setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "getProtocolVersion":
                            // 协议版本协商：Dart 端可据此判断兼容性
                            result.success(PROTOCOL_VERSION);
                            break;
                        case "showFloatingBall":
                            showFloatingBall();
                            result.success(true);
                            break;
                        case "hideFloatingBall":
                            hideFloatingBall();
                            result.success(true);
                            break;
                        case "startService":
                            startFloatingService();
                            result.success(true);
                            break;
                        case "updateBallStatus":
                            String status = call.argument("status");
                            // 记录 Dart 处理状态（用于 onResume 恢复）
                            if ("processing".equals(status)) {
                                dartIsProcessing = true;
                            } else if ("success".equals(status) || "error".equals(status) || "idle".equals(status)) {
                                dartIsProcessing = false;
                            }
                            updateBallStatus(status);
                            result.success(true);
                            break;
                        case "showSuggestionOverlay":
                            showSuggestionOverlay(call.arguments());
                            result.success(true);
                            break;
                        case "hideSuggestionOverlay":
                            hideSuggestionOverlay();
                            result.success(true);
                            break;
                        case "updateContactLabel":
                            // 更新悬浮球旁的联系人标签
                            currentContactName = call.argument("name");
                            updateContactLabelView();
                            result.success(true);
                            break;
                        case "isProcessing":
                            // 查询当前是否正在处理任务（onResume 时恢复球状态用）
                            result.success(dartIsProcessing);
                            break;
                        case "saveDraft":
                            // 从浮窗存入草稿
                            String draftContent = call.argument("content");
                            String draftContactId = call.argument("contactId");
                            notifyDart("onSaveDraft", null);
                            result.success(true);
                            break;
                        default:
                            result.notImplemented();
                    }
                });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SCREENSHOT_CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "openAccessibilitySettings":
                            startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
                            result.success(true);
                            break;
                        default:
                            result.notImplemented();
                    }
                });
    }

    // ==================== Ball Status ====================

    private void updateBallStatus(String status) {
        if (status == null) return;
        switch (status.toLowerCase()) {
            case "processing":
            case "analyzing":
                // processing=初始处理中, analyzing=正在识别对话（保持横条，更新文字）
                setBallState(STATE_PROCESSING);
                if (ballLoadingText != null) {
                    ballLoadingText.setText("analyzing".equals(status) ? "识别对话中..." : "识别中...");
                }
                break;
            case "generating":
                // 正在生成建议（保持横条，更新文字）
                setBallState(STATE_PROCESSING);
                if (ballLoadingText != null) {
                    ballLoadingText.setText("生成建议中...");
                }
                break;
            case "success":
                setBallState(STATE_SUCCESS);
                scheduleReset(RESET_DELAY_SUCCESS);
                break;
            case "error":
                setBallState(STATE_ERROR);
                vibrateError();
                scheduleReset(RESET_DELAY_ERROR);
                break;
            case "idle":
                setBallState(STATE_IDLE);
                break;
        }
    }

    private void setBallState(int newState) {
        this.ballState = newState;
        if (floatingView == null || windowManager == null) return;

        Log.d("BallState", "setBallState: " + newState + " (IDLE=0,PROC=1,OK=2,ERR=3)");

        switch (newState) {
            case STATE_IDLE:
                _showCircleState();
                ballIcon.setImageResource(ICON_IDLE);
                floatingView.setEnabled(true);
                break;
            case STATE_PROCESSING:
                _showLoadingBarState();
                floatingView.setEnabled(false);
                break;
            case STATE_SUCCESS:
                _showCircleState();
                ballIcon.setImageResource(ICON_SUCCESS);
                floatingView.setEnabled(false);
                break;
            case STATE_ERROR:
                _showCircleState();
                ballIcon.setImageResource(ICON_ERROR);
                floatingView.setEnabled(false);
                break;
        }
    }

    /** 切换到圆形状态（空闲/成功/失败） */
    private void _showCircleState() {
        if (ballIcon == null || ballLoadingBar == null) return;

        // 停止横条动画
        ballLoadingBar.setVisibility(View.GONE);

        // 恢复圆形
        ballIcon.setVisibility(View.VISIBLE);
        ballIcon.clearAnimation();

        // 如果之前记录了球心，恢复位置
        if (ballCenterX >= 0 && floatingView != null && windowManager != null) {
            WindowManager.LayoutParams lp = (WindowManager.LayoutParams) floatingView.getLayoutParams();
            if (lp != null) {
                int ballWidth = 48; // dp → px 近似，实际由布局决定
                float density = getResources().getDisplayMetrics().density;
                int ballWidthPx = (int)(48 * density);
                lp.x = ballCenterX - ballWidthPx / 2;
                try { windowManager.updateViewLayout(floatingView, lp); }
                catch (Exception ignored) {}
            }
            ballCenterX = -1;
        }

        // 缩放回圆形的弹性动画
        ballIcon.setScaleX(0.6f);
        ballIcon.setScaleY(0.6f);
        ballIcon.animate()
                .scaleX(1f).scaleY(1f)
                .setDuration(250)
                .setInterpolator(new android.view.animation.OvershootInterpolator(2.5f))
                .start();
    }

    /** 切换到横向加载条状态（处理中） */
    private void _showLoadingBarState() {
        if (ballIcon == null || ballLoadingBar == null) return;

        // 记录当前球心 X 坐标（用于横条居中）
        if (floatingView != null) {
            WindowManager.LayoutParams lp = (WindowManager.LayoutParams) floatingView.getLayoutParams();
            if (lp != null) {
                float density = getResources().getDisplayMetrics().density;
                int ballWidthPx = (int)(48 * density);
                ballCenterX = lp.x + ballWidthPx / 2;
            }
        }

        // 隐藏圆形
        ballIcon.clearAnimation();
        ballIcon.setVisibility(View.GONE);

        // 显示横条加载栏
        ballLoadingBar.setVisibility(View.VISIBLE);

        // 更新位置：横条以原球心为中心
        if (ballCenterX >= 0 && floatingView != null && windowManager != null) {
            WindowManager.LayoutParams lp = (WindowManager.LayoutParams) floatingView.getLayoutParams();
            if (lp != null) {
                float density = getResources().getDisplayMetrics().density;
                int barWidthPx = (int)(160 * density); // 对应 XML 中 160dp
                lp.x = ballCenterX - barWidthPx / 2;
                try { windowManager.updateViewLayout(floatingView, lp); }
                catch (Exception ignored) {}
            }
        }

        // 横条从圆心弹出的缩放入场动画
        ballLoadingBar.setScaleX(0.3f);
        ballLoadingBar.setAlpha(0f);
        ballLoadingBar.animate()
                .scaleX(1f).alpha(1f)
                .setDuration(280)
                .setInterpolator(new android.view.animation.DecelerateInterpolator())
                .start();

        // 文字脉冲效果
        if (ballLoadingText != null) {
            ballLoadingText.setText("识别中...");
        }
    }

    private void scheduleReset(long delayMs) {
        cancelPendingReset();
        Log.d("BallState", "scheduleReset: " + delayMs + "ms later");
        pendingResetRunnable = () -> {
            Log.d("BallState", "resetRunnable fired → STATE_IDLE");
            setBallState(STATE_IDLE);
        };
        uiHandler.postDelayed(pendingResetRunnable, delayMs);
    }

    private void cancelPendingReset() {
        if (pendingResetRunnable != null) {
            uiHandler.removeCallbacks(pendingResetRunnable);
            pendingResetRunnable = null;
        }
    }

    private void vibrateError() {
        try {
            Vibrator vib = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
            if (vib != null && vib.hasVibrator()) {
                vib.vibrate(
                    android.os.VibrationEffect.createOneShot(200,
                        android.os.VibrationEffect.DEFAULT_AMPLITUDE));
            }
        } catch (Exception e) {
            Log.w("MainActivity", "vibrateError failed", e);
        }
    }

    // ==================== Suggestion Overlay (WindowManager) ====================

    @SuppressWarnings("unchecked")
    private void showSuggestionOverlay(Object rawData) {
        hideSuggestionOverlay();

        if (!(rawData instanceof Map)) return;
        Map<String, Object> data = (Map<String, Object>) rawData;

        overlayManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        int overlayType = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;

        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT, overlayType,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;

        suggestionOverlay = LayoutInflater.from(this).inflate(R.layout.suggestion_overlay, null);

        // Title
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> suggestions =
            (List<Map<String, Object>>) data.get("suggestions");
        int count = (suggestions != null) ? suggestions.size() : 0;
        TextView tvTitle = suggestionOverlay.findViewById(R.id.tv_title);
        tvTitle.setText("为您准备了 " + count + " 条回复建议");

        // Countdown
        int autoDismiss = data.get("autoDismissSeconds") != null
            ? ((Number) data.get("autoDismissSeconds")).intValue() : 8;
        if (autoDismiss > 0) {
            remainingSeconds = autoDismiss;
            startCountdownTimer(autoDismiss);
        } else {
            ProgressBar pbCountdown = suggestionOverlay.findViewById(R.id.progress_countdown);
            TextView tvCd = suggestionOverlay.findViewById(R.id.tv_countdown);
            pbCountdown.setVisibility(View.GONE);
            tvCd.setVisibility(View.GONE);
        }

        // Scene + Direction
        String scene = (String) data.get("scene");
        String sceneDesc = (String) data.get("sceneDescription");
        String direction = (String) data.get("direction");
        if (scene != null || direction != null) {
            LinearLayout layoutScene = suggestionOverlay.findViewById(R.id.layout_scene);
            layoutScene.setVisibility(View.VISIBLE);

            if (scene != null) {
                LinearLayout tagScene = suggestionOverlay.findViewById(R.id.tag_scene);
                tagScene.setVisibility(View.VISIBLE);
                ImageView ivIcon = suggestionOverlay.findViewById(R.id.iv_scene_icon);
                switch (scene) {
                    case "A": ivIcon.setImageResource(R.drawable.ic_auto_awesome); break;
                    case "B": ivIcon.setImageResource(android.R.drawable.ic_dialog_email); break;
                    case "C": ivIcon.setImageResource(android.R.drawable.ic_dialog_info); break;
                    default:  ivIcon.setImageResource(R.drawable.ic_auto_awesome); break;
                }
                TextView tvSceneLabel = suggestionOverlay.findViewById(R.id.tv_scene_label);
                tvSceneLabel.setText("Scene " + scene + " - " + getSceneLabel(scene));
            }

            if (direction != null && !direction.isEmpty()) {
                TextView tvDir = suggestionOverlay.findViewById(R.id.tv_direction);
                tvDir.setText(direction);
            }
            if (sceneDesc != null && !sceneDesc.isEmpty()) {
                TextView tvDesc = suggestionOverlay.findViewById(R.id.tv_scene_desc);
                tvDesc.setText(sceneDesc);
                tvDesc.setVisibility(View.VISIBLE);
            }
        }

        // V2 联系人画像摘要（contact_insight）
        String contactInsight = (String) data.get("contactInsight");
        if (contactInsight != null && !contactInsight.isEmpty()
                && !"暂无足够信息".equals(contactInsight)) {
            LinearLayout layoutInsight = suggestionOverlay.findViewById(R.id.layout_insight);
            TextView tvInsight = suggestionOverlay.findViewById(R.id.tv_insight);
            if (layoutInsight != null && tvInsight != null) {
                layoutInsight.setVisibility(View.VISIBLE);
                tvInsight.setText(contactInsight);
            }
        }

        // Suggestion list
        LinearLayout container = suggestionOverlay.findViewById(R.id.container_suggestions);
        if (suggestions != null) {
            for (int i = 0; i < suggestions.size(); i++) {
                Map<String, Object> item = suggestions.get(i);
                View itemView = LayoutInflater.from(this)
                    .inflate(R.layout.suggestion_item, container, false);

                String style = (String) item.getOrDefault("style", "");
                String content = (String) item.getOrDefault("content", "");
                String reason = (String) item.get("reason");

                ((TextView) itemView.findViewById(R.id.tv_style_tag)).setText(style);
                ((TextView) itemView.findViewById(R.id.tv_suggestion_text)).setText(content);
                if (reason != null && !reason.isEmpty()) {
                    TextView tvReason = itemView.findViewById(R.id.tv_reason);
                    tvReason.setText(reason);
                    tvReason.setVisibility(View.VISIBLE);
                }

                final String copyText = content;
                itemView.findViewById(R.id.btn_copy).setOnClickListener(v -> {
                    copyToClipboard(copyText);
                    notifyDart("onSuggestionCopied", null);
                    pauseCountdown();
                });

                container.addView(itemView);
            }
        }

        // Close button
        suggestionOverlay.findViewById(R.id.btn_close).setOnClickListener(v -> {
            hideSuggestionOverlay();
            notifyDart("onSuggestionClosed", null);
        });

        // Refresh button → 显示加载状态后通知Dart（不立即关闭浮窗）
        suggestionOverlay.findViewById(R.id.btn_refresh).setOnClickListener(v -> {
            // 禁用刷新按钮防止重复点击
            v.setEnabled(false);
            v.setAlpha(0.5f);
            // 标题改为"重新生成中..."
            TextView titleView = suggestionOverlay.findViewById(R.id.tv_title);
            if (titleView != null) titleView.setText("正在重新生成...");
            notifyDart("onSuggestionRegenerate", null);
        });

        // Save draft button → 通知Dart保存当前建议到草稿箱
        suggestionOverlay.findViewById(R.id.btn_save_draft).setOnClickListener(v -> {
            notifyDart("onSaveDraft", null);
        });

        if (overlayManager != null) {
            try {
                // 限制浮窗最大高度为屏幕的 80%，防止内容过多时顶部被截断
                // XML 中 Scene+Insight+Suggestions 已统一包裹在 ScrollView(maxHeight=400dp) 中
                // 此处再做一层保险：限制 WindowManager 层高度不超过屏幕 80%
                int screenHeight = getResources().getDisplayMetrics().heightPixels;
                params.height = (int)(screenHeight * 0.8f);

                // 初始位置：向下偏移整个高度（不可见）
                suggestionOverlay.setTranslationY(suggestionOverlay.getHeight() > 0
                        ? (float) suggestionOverlay.getHeight() : 1000f);
                overlayManager.addView(suggestionOverlay, params);
                // 从底部滑入动画（300ms，PRD §5.3.3）
                suggestionOverlay.animate()
                        .translationY(0f)
                        .setDuration(300)
                        .setInterpolator(new android.view.animation.DecelerateInterpolator())
                        .start();
            } catch (Exception e) {
                Log.e("MainActivity", "showSuggestionOverlay addView failed", e);
                suggestionOverlay = null;
            }
        }
    }

    private void hideSuggestionOverlay() {
        stopCountdownTimer();
        if (suggestionOverlay != null && overlayManager != null) {
            try { overlayManager.removeView(suggestionOverlay); }
            catch (IllegalArgumentException ignored) {}
        }
        suggestionOverlay = null;
    }

    private void copyToClipboard(String text) {
        ClipboardManager clipboard =
            (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            Log.w("MainActivity", "ClipboardManager unavailable");
            return;
        }
        ClipData clip = ClipData.newPlainText("suggestion", text);
        clipboard.setPrimaryClip(clip);
        Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show();
    }

    private void notifyDart(String method, Object args) {
        if (dartChannel != null) {
            dartChannel.invokeMethod(method, args);
        }
    }

    private String getSceneLabel(String scene) {
        switch (scene) {
            case "A": return "待回复";
            case "B": return "开启话题";
            case "C": return "继续推进";
            default: return "未知";
        }
    }

    // ---- Countdown timer (lightweight postDelayed chain) ----

    private Runnable countdownRunnable;
    private static final int COUNTDOWN_INTERVAL_MS = 1000;

    private void startCountdownTimer(int totalSeconds) {
        stopCountdownTimer();
        countdownTotalSeconds = totalSeconds;
        remainingSeconds = totalSeconds;
        updateCountdownUI();

        countdownRunnable = () -> {
            if (suggestionOverlay == null) { return; }
            remainingSeconds--;
            updateCountdownUI();
            if (remainingSeconds <= 0) {
                hideSuggestionOverlay();
                notifyDart("onSuggestionClosed", null);
            } else {
                uiHandler.postDelayed(countdownRunnable, COUNTDOWN_INTERVAL_MS);
            }
        };
        uiHandler.postDelayed(countdownRunnable, COUNTDOWN_INTERVAL_MS);
    }

    private void stopCountdownTimer() {
        if (countdownRunnable != null) {
            uiHandler.removeCallbacks(countdownRunnable);
            countdownRunnable = null;
        }
        if (countdownResumeRunnable != null) {
            uiHandler.removeCallbacks(countdownResumeRunnable);
            countdownResumeRunnable = null;
        }
    }

    /**
     * 暂停倒计时（用户复制某条建议时调用）。
     * 停止 tick，UI 保持当前 remainingSeconds 不变。
     * 10秒后自动恢复倒计时，防止 Overlay 永久不关闭。
     */
    private static final long COUNTDOWN_PAUSE_AUTO_RESUME_MS = 10_000L;
    private Runnable countdownResumeRunnable;

    private void pauseCountdown() {
        if (countdownRunnable != null) {
            uiHandler.removeCallbacks(countdownRunnable);
            countdownRunnable = null;
        }
        // 取消之前的自动恢复（防重复调度）
        if (countdownResumeRunnable != null) {
            uiHandler.removeCallbacks(countdownResumeRunnable);
        }
        // 延迟自动恢复
        countdownResumeRunnable = () -> {
            countdownResumeRunnable = null;
            resumeCountdownInternal();
        };
        uiHandler.postDelayed(countdownResumeRunnable, COUNTDOWN_PAUSE_AUTO_RESUME_MS);
    }

    /** 内部恢复方法：从当前 remainingSeconds 继续倒计时 */
    private void resumeCountdownInternal() {
        if (suggestionOverlay == null) return;
        if (countdownRunnable != null) return;
        if (remainingSeconds <= 0) {
            hideSuggestionOverlay();
            notifyDart("onSuggestionClosed", null);
            return;
        }
        countdownRunnable = () -> {
            if (suggestionOverlay == null) { return; }
            remainingSeconds--;
            updateCountdownUI();
            if (remainingSeconds <= 0) {
                hideSuggestionOverlay();
                notifyDart("onSuggestionClosed", null);
            } else {
                uiHandler.postDelayed(countdownRunnable, COUNTDOWN_INTERVAL_MS);
            }
        };
        uiHandler.postDelayed(countdownRunnable, COUNTDOWN_INTERVAL_MS);
    }

    private void updateCountdownUI() {
        if (suggestionOverlay == null) return;
        ProgressBar progress = suggestionOverlay.findViewById(R.id.progress_countdown);
        TextView tvCountdown = suggestionOverlay.findViewById(R.id.tv_countdown);
        int total = countdownTotalSeconds;
        if (total > 0) {
            int pct = Math.max(0, (int)(100.0 * remainingSeconds / total));
            progress.setProgress(pct);
            tvCountdown.setText(remainingSeconds + "s");
            tvCountdown.setTextColor(remainingSeconds <= 3 ? 0xFFF44336 : 0xFF999999);
        }
    }

    // ==================== Floating Ball ====================

    /**
     * 真正尝试弹出悬浮球。无权限时直接打开系统设置并返回 false。
     * @return true = 悬浮球已成功挂载，false = 缺少权限/启动失败
     */
    private boolean showFloatingBall() {
        if (!Settings.canDrawOverlays(this)) {
            startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName())));
            return false;
        }
        hideFloatingBall();
        windowManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);

        int overlayType = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;

        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT, overlayType,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.TOP | Gravity.START;
        params.x = getResources().getDisplayMetrics().widthPixels / 2;
        params.y = getResources().getDisplayMetrics().heightPixels / 3;

        View ballView = LayoutInflater.from(this).inflate(R.layout.floating_ball, null);
        ballIcon = ballView.findViewById(R.id.ball_icon);
        ballLoadingBar = ballView.findViewById(R.id.ball_loading_bar);
        ballLoadingText = ballView.findViewById(R.id.ball_loading_text);

        // 触摸监听挂在根容器上，确保横条状态也能响应
        ballView.setOnTouchListener(new BallTouchListener(this, params, ballView));

        floatingView = ballView;
        if (windowManager != null) {
            try {
                windowManager.addView(ballView, params);
                return true;
            } catch (Exception e) {
                Log.e("MainActivity", "showFloatingBall addView failed", e);
                floatingView = null;
                ballIcon = null;
            }
        }
        return false;
    }

    /**
     * 静态内部类触摸监听器 — 使用 WeakReference 避免持有 Activity 强引用导致内存泄漏。
     */
    private static class BallTouchListener implements View.OnTouchListener {
        private final WeakReference<MainActivity> activityRef;
        private final WindowManager.LayoutParams params;
        private final WeakReference<View> ballViewRef;

        boolean isMoving; int initialX, initialY;
        float initialTouchX, initialTouchY; long clickTime;

        BallTouchListener(MainActivity activity, WindowManager.LayoutParams params, View ballView) {
            this.activityRef = new WeakReference<>(activity);
            this.params = params;
            this.ballViewRef = new WeakReference<>(ballView);
        }

        @Override
        public boolean onTouch(View v, MotionEvent event) {
            MainActivity activity = activityRef.get();
            if (activity == null) return false;
            if (activity.ballState == STATE_PROCESSING) return true;

            switch (event.getAction()) {
                case MotionEvent.ACTION_DOWN:
                    isMoving = false; initialX = params.x; initialY = params.y;
                    initialTouchX = event.getRawX(); initialTouchY = event.getRawY();
                    clickTime = System.currentTimeMillis(); return true;
                case MotionEvent.ACTION_MOVE:
                    float dx = event.getRawX() - initialTouchX;
                    float dy = event.getRawY() - initialTouchY;
                    if (Math.abs(dx) > 5 || Math.abs(dy) > 5) isMoving = true;
                    params.x = initialX + (int)dx;
                    params.y = initialY + (int)dy;
                    long now = System.currentTimeMillis();
                    if (now - activity.lastDragUpdateTime >= DRAG_THROTTLE_MS) {
                        activity.lastDragUpdateTime = now;
                        if (activity.windowManager != null && ballViewRef.get() != null) {
                            activity.windowManager.updateViewLayout(ballViewRef.get(), params);
                        }
                    }
                    return true;
                case MotionEvent.ACTION_UP:
                    int sw = activity.getResources().getDisplayMetrics().widthPixels;
                    View bv = ballViewRef.get();
                    int bw = (bv != null) ? bv.getWidth() : 0;
                    params.x = (params.x < sw/2) ? 32 : sw - bw - 32;
                    if (activity.windowManager != null && bv != null) {
                        activity.windowManager.updateViewLayout(bv, params);
                    }
                    if (!isMoving && System.currentTimeMillis() - clickTime < 300) {
                        activity.triggerScreenshot();
                    }
                    return true;
                default: return false;
            }
        }
    }

    private void hideFloatingBall() {
        cancelPendingReset();
        if (floatingView != null && windowManager != null) {
            try { windowManager.removeView(floatingView); }
            catch (IllegalArgumentException ignored) {}
        }
        floatingView = null;
        ballIcon = null;
        ballLoadingBar = null;
        ballLoadingText = null;
        ballCenterX = -1;
        ballState = STATE_IDLE;
    }

    /** 更新悬浮球旁的联系人标签显示 */
    private void updateContactLabelView() {
        if (floatingView == null) return;
        View labelView = floatingView.findViewById(R.id.ball_contact_label);
        if (labelView != null) {
            if (currentContactName != null && !currentContactName.isEmpty()) {
                labelView.setVisibility(View.VISIBLE);
                ((TextView) labelView).setText(currentContactName);
            } else {
                labelView.setVisibility(View.GONE);
            }
        }
    }

    /**
     * 启动悬浮球前台服务（用于在 App 被杀时保活）。
     * @return true = 成功派发启动意图
     */
    private boolean startFloatingService() {
        try {
            Intent intent = new Intent(this, FloatingBallService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent);
            } else {
                startService(intent);
            }
            return true;
        } catch (Exception e) {
            Log.e("MainActivity", "startFloatingService failed", e);
            return false;
        }
    }

    /** Click ball -> cooldown check -> contact validate -> processing state -> screenshot (Java-side) -> notify Dart */
    private void triggerScreenshot() {
        if (ballState != STATE_IDLE) return;

        // 冷却检查：3秒内不允许多次截图（防止快速连点浪费 API 调用）
        long now = System.currentTimeMillis();
        if (now - lastScreenshotTime < SCREENSHOT_COOLDOWN_MS) {
            long remaining = (SCREENSHOT_COOLDOWN_MS - (now - lastScreenshotTime)) / 1000;
            Toast.makeText(this, "操作太频繁，请" + remaining + "秒后再试", Toast.LENGTH_SHORT).show();
            return;
        }

        // 前置校验：通过 Dart 查询是否已选中联系人
        if (dartChannel != null) {
            dartChannel.invokeMethod("getCurrentContactId", null, new MethodChannel.Result() {
                @Override public void success(Object contactId) {
                    String cid = (contactId == null || "null".equals(contactId.toString())
                            || ((String)contactId).isEmpty()) ? null : (String)contactId;
                    if (cid == null) {
                        Toast.makeText(MainActivity.this, "请先选择联系人", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    doStartScreenshot();
                }
                @Override public void error(String errorCode, String errorMessage, Object errorDetails) {
                    // Dart 端异常时仍允许截图，由 Dart 侧再次校验
                    doStartScreenshot();
                }
                @Override public void notImplemented() {
                    doStartScreenshot();
                }
            });
        } else {
            doStartScreenshot();
        }
    }

    /** 实际执行截图的内部方法 */
    private void doStartScreenshot() {
        lastScreenshotTime = System.currentTimeMillis();
        setBallState(STATE_PROCESSING);
        captureScreenshotForBall();
    }

    /**
     * 为悬浮球点击触发截图：Java 端截完图后通过 dartChannel 通知 Dart 处理。
     * 相比旧方案（Dart 调 Java 截图再返回），消除了 Activity 后台时的跨层往返延迟。
     */
    private void captureScreenshotForBall() {
        if (!screenshotBusy.compareAndSet(false, true)) {
            updateBallStatus("error");
            vibrateError();
            return;
        }
        if (!ScreenshotAccessibilityService.isAvailable()) {
            screenshotBusy.set(false);
            updateBallStatus("error");
            vibrateError();
            return;
        }

        File dir = new File(getFilesDir(), SCREENSHOT_DIR);
        if (!dir.exists() && !dir.mkdirs()) {
            Toast.makeText(this, "无法创建截图目录", Toast.LENGTH_SHORT).show();
            setBallState(STATE_ERROR);
            return;
        }
        File outFile = new File(dir, "screenshot_" + UUID.randomUUID().toString().substring(0, 8) + "_" + System.currentTimeMillis() + ".png");

        ScreenshotAccessibilityService.capture(outFile,
                new ScreenshotAccessibilityService.ScreenshotCallback() {
                    @Override public void onSuccess(String path) {
                        screenshotBusy.set(false);
                        // 截图成功 → 通知 Dart 继续处理（AI + 落库 + 浮窗）
                        if (dartChannel != null) {
                            dartChannel.invokeMethod("onScreenshotReady", path);
                        } else {
                            updateBallStatus("error");
                        }
                    }
                    @Override public void onError(String code, String msg) {
                        screenshotBusy.set(false);
                        Log.w("MainActivity", "captureScreenshotForBall failed: " + code + " " + msg);
                        updateBallStatus("error");
                        vibrateError();
                    }
                });
    }

    // ==================== Screenshot ====================

    @Override
    protected void onResume() {
        super.onResume();
        // App 恢复前台时：
        // 1. 如果悬浮球不存在，自动重建（App 被杀重启或系统回收后）
        if (floatingView == null && Settings.canDrawOverlays(this)) {
            showFloatingBall();
            // 恢复联系人标签
            updateContactLabelView();
        }
        // 2. 如果 Dart 正在处理任务，恢复球的 processing 视觉状态
        //    （解决"返回App后球变空闲但任务还在跑"的问题）
        if (dartIsProcessing && ballState != STATE_PROCESSING) {
            Log.d("BallState", "onResume: Dart is processing, restoring STATE_PROCESSING visual");
            setBallState(STATE_PROCESSING);
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        // App 进入后台时不重置球状态（保留当前视觉状态）
        // ballState 和 dartIsProcessing 保持不变，onResume 时用于恢复
    }

    @Override
    protected void onDestroy() {
        hideFloatingBall();
        hideSuggestionOverlay();
        AppEventBus.clear();
        super.onDestroy();
    }
}

class AppEventBus {
    static volatile Runnable floatingBallRequest;
    static void requestShowFloatingBall() { if (floatingBallRequest != null) floatingBallRequest.run(); }
    static void clear() { floatingBallRequest = null; }
}
