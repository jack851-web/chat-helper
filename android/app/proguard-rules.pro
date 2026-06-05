# Flutter
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# ML Kit
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# MediaProjection / VirtualDisplay 反射调用
-keep class android.media.projection.** { *; }
-keep class android.hardware.display.** { *; }

# Kotlin 元数据 (与 ML Kit 协程/泛型配合)
-keep class kotlin.Metadata { *; }
-keep class kotlin.coroutines.Continuation
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
