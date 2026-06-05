package com.chathelper.app;

import android.graphics.Bitmap;
import android.graphics.ColorSpace;
import android.hardware.HardwareBuffer;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;
import androidx.annotation.NonNull;
import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.Executor;

/**
 * AccessibilityService — Android 11+ takeScreenshot()，不依赖 MediaProjection。
 * XML 配置中已有所有所需标志。不要在代码中覆盖它们。
 */
public class ScreenshotAccessibilityService extends android.accessibilityservice.AccessibilityService {

    private static volatile ScreenshotAccessibilityService instance;

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
    }

    @Override
    public void onDestroy() {
        instance = null;
        super.onDestroy();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {}

    @Override
    public void onInterrupt() {}

    // 不要重写 onServiceConnected 并调用 setServiceInfo() ——
    // 那会覆盖 XML 中声明的标志，导致 takeScreenshot 能力丢失。
    // 所有配置由 res/xml/accessibility_service_config.xml 提供。

    public static boolean isAvailable() {
        return instance != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R;
    }

    public static void capture(File outFile, ScreenshotCallback callback) {
        if (instance == null) {
            callback.onError("SERVICE_UNAVAILABLE", "无障碍服务未启用");
            return;
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            callback.onError("SDK_TOO_OLD", "需要 Android 11+");
            return;
        }

        instance.takeScreenshot(
                Display.DEFAULT_DISPLAY,
                new MainThreadExecutor(),
                new TakeScreenshotCallback() {
                    @Override
                    public void onSuccess(@NonNull ScreenshotResult result) {
                        try {
                            Bitmap bitmap = hardwareBufferToBitmap(result.getHardwareBuffer());
                            if (bitmap == null) {
                                result.getHardwareBuffer().close();
                                callback.onError("CONVERT_FAILED", "无法转换截图数据");
                                return;
                            }
                            try {
                                outFile.getParentFile().mkdirs();
                                FileOutputStream fos = new FileOutputStream(outFile);
                                bitmap.compress(Bitmap.CompressFormat.PNG, 85, fos);
                                fos.close();
                                callback.onSuccess(outFile.getAbsolutePath());
                            } finally {
                                bitmap.recycle();
                                result.getHardwareBuffer().close();
                            }
                        } catch (Exception e) {
                            callback.onError("SAVE_ERROR", "保存: " + e.getMessage());
                        }
                    }

                    @Override
                    public void onFailure(int code) {
                        String msg;
                        switch (code) {
                            case ERROR_TAKE_SCREENSHOT_INTERNAL_ERROR: msg = "系统内部错误"; break;
                            case ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT: msg = "过于频繁"; break;
                            case ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS: msg = "未授权"; break;
                            case ERROR_TAKE_SCREENSHOT_SECURE_WINDOW: msg = "安全窗口"; break;
                            default: msg = "错误码 " + code; break;
                        }
                        callback.onError("CAPTURE_FAILED", msg);
                    }
                });
    }

    private static Bitmap hardwareBufferToBitmap(HardwareBuffer buffer) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ColorSpace srgb = ColorSpace.get(ColorSpace.Named.SRGB);
            Bitmap wrapped = Bitmap.wrapHardwareBuffer(buffer, srgb);
            if (wrapped != null) {
                Bitmap copy = wrapped.copy(Bitmap.Config.ARGB_8888, false);
                wrapped.recycle();
                return copy;
            }
        }
        return null;
    }

    public interface ScreenshotCallback {
        void onSuccess(String filePath);
        void onError(String errorCode, String message);
    }
}

class MainThreadExecutor implements Executor {
    private final Handler handler = new Handler(Looper.getMainLooper());
    @Override public void execute(Runnable r) { handler.post(r); }
}
