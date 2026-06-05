package com.chathelper.app;

import android.content.Context;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.ImageView;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;

/**
 * MainActivity - 悬浮球 + AccessibilityService 截图。
 * takeScreenshot() 不依赖 MediaProjection，不弹"录制"对话框。
 */
public class MainActivity extends FlutterActivity {

    private static final String CHANNEL = "com.chathelper/floating_ball";
    private static final String SCREENSHOT_CHANNEL = "com.chathelper/screenshot";
    private static final String SCREENSHOT_DIR = "screenshots";

    private View floatingView;
    private WindowManager windowManager;

    private volatile boolean screenshotBusy;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        AppEventBus.floatingBallRequest = this::showFloatingBall;
        AppEventBus.floatingBallHideRequest = this::hideFloatingBall;

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "showFloatingBall": showFloatingBall(); result.success(true); break;
                        case "hideFloatingBall": hideFloatingBall(); result.success(true); break;
                        case "startService": startFloatingService(); result.success(true); break;
                        default: result.notImplemented();
                    }
                });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SCREENSHOT_CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "captureScreenshot": captureScreenshot(result); break;
                        case "openAccessibilitySettings":
                            startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
                            result.success(true);
                            break;
                        default: result.notImplemented();
                    }
                });
    }

    // ==================== 悬浮球 ====================

    private void showFloatingBall() {
        if (!Settings.canDrawOverlays(this)) {
            startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName())));
            return;
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
        ImageView ballIcon = ballView.findViewById(R.id.ball_icon);

        ballIcon.setOnTouchListener(new View.OnTouchListener() {
            boolean isMoving; int initialX, initialY;
            float initialTouchX, initialTouchY; long clickTime;
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        isMoving = false; initialX = params.x; initialY = params.y;
                        initialTouchX = event.getRawX(); initialTouchY = event.getRawY();
                        clickTime = System.currentTimeMillis(); return true;
                    case MotionEvent.ACTION_MOVE:
                        if (Math.abs(event.getRawX() - initialTouchX) > 5
                                || Math.abs(event.getRawY() - initialTouchY) > 5) isMoving = true;
                        params.x = initialX + (int)(event.getRawX() - initialTouchX);
                        params.y = initialY + (int)(event.getRawY() - initialTouchY);
                        if (windowManager != null) windowManager.updateViewLayout(ballView, params);
                        return true;
                    case MotionEvent.ACTION_UP:
                        int sw = getResources().getDisplayMetrics().widthPixels;
                        int bw = ballView.getWidth();
                        params.x = (params.x < sw/2) ? 32 : sw - bw - 32;
                        if (windowManager != null) windowManager.updateViewLayout(ballView, params);
                        if (!isMoving && System.currentTimeMillis() - clickTime < 300) triggerScreenshot();
                        return true;
                    default: return false;
                }
            }
        });

        floatingView = ballView;
        if (windowManager != null) windowManager.addView(ballView, params);
    }

    private void hideFloatingBall() {
        if (floatingView != null && windowManager != null) {
            try { windowManager.removeView(floatingView); }
            catch (IllegalArgumentException ignored) {}
        }
        floatingView = null;
    }

    private void startFloatingService() {
        Intent intent = new Intent(this, FloatingBallService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
    }

    private void triggerScreenshot() {
        if (getFlutterEngine() != null) {
            new MethodChannel(getFlutterEngine().getDartExecutor().getBinaryMessenger(), CHANNEL)
                    .invokeMethod("onFloatingBallClick", null);
        }
    }

    // ==================== 截图 ====================

    private void captureScreenshot(MethodChannel.Result result) {
        if (screenshotBusy) {
            result.error("BUSY", "上一次截图尚未完成", null);
            return;
        }
        if (!ScreenshotAccessibilityService.isAvailable()) {
            result.error("A11Y_SERVICE_OFF",
                    "请先在 设置→无障碍→已安装的服务 中开启 Chat-Helper", null);
            return;
        }
        screenshotBusy = true;

        File dir = new File(getFilesDir(), SCREENSHOT_DIR);
        dir.mkdirs();
        File outFile = new File(dir, "screenshot_" + System.currentTimeMillis() + ".png");

        ScreenshotAccessibilityService.capture(outFile,
                new ScreenshotAccessibilityService.ScreenshotCallback() {
                    @Override public void onSuccess(String path) {
                        screenshotBusy = false;
                        result.success(path);
                    }
                    @Override public void onError(String code, String msg) {
                        screenshotBusy = false;
                        result.error(code, msg, null);
                    }
                });
    }

    @Override
    protected void onDestroy() {
        hideFloatingBall();
        AppEventBus.clear();
        super.onDestroy();
    }
}

class AppEventBus {
    static volatile Runnable floatingBallRequest;
    static volatile Runnable floatingBallHideRequest;
    static void requestShowFloatingBall() { if (floatingBallRequest != null) floatingBallRequest.run(); }
    static void requestHideFloatingBall() { if (floatingBallHideRequest != null) floatingBallHideRequest.run(); }
    static void clear() { floatingBallRequest = null; floatingBallHideRequest = null; }
}
