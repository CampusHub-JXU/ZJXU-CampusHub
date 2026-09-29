# App-level R8 rules. Flutter's Gradle plugin picks this file up automatically
# for release builds (FlutterPlugin.kt adds <app>/proguard-rules.pro when it exists).

# flutter_local_notifications persists scheduled notifications with Gson and
# `new TypeToken<ArrayList<NotificationDetails>>() {}`. Without these rules R8
# strips the generic signature and every cancel()/schedule call fails with
# "TypeToken must be created with a type argument" (observed in the v0.8.2
# release bugreport). The plugin ships no consumer rules; these follow its
# README and Gson's official Android rules.
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
-keep class com.dexterous.** { *; }
