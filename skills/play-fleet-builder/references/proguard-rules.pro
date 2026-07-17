# TEMPLATE — copied from nullnet-app/encore's android/proguard-rules.pro,
# where it is proven against a live minified build.
#
# CHANGE: every `com.chrischall.encore.shared` below -> your shared module's
# package. If the keep rules stop matching your models, the build still
# succeeds and the app throws SerializationException on its first API
# response — which is exactly what verify-minified-serializers.sh catches.

# R8 rules for the release build.
#
# The risk this file exists to manage: the shared KMP core decodes every API
# response with kotlinx.serialization, whose generated $$serializer classes are
# reached reflectively via the Companion. R8 sees no call site and strips them,
# so a minified build compiles clean and then fails at runtime the first time it
# parses JSON. Unit tests run un-minified and never catch it — the release build
# is smoke-tested on a device instead.

# --- kotlinx.serialization ---
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**

# Keep every @Serializable model in the shared core together with the synthetic
# serializer R8 can't see being used.
-keep,includedescriptorclasses class com.chrischall.encore.shared.**$$serializer { *; }
-keepclassmembers class com.chrischall.encore.shared.** {
    *** Companion;
}
-keepclasseswithmembers class com.chrischall.encore.shared.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keepclassmembers @kotlinx.serialization.Serializable class ** {
    static <1>$Companion Companion;
    *** Companion;
}
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# --- Ktor + coroutines ---
# Both use atomicfu-generated volatile fields updated reflectively.
-keepclassmembers class io.ktor.** { volatile <fields>; }
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }
-dontwarn kotlinx.atomicfu.**
-dontwarn io.ktor.**
-dontwarn kotlinx.coroutines.**

# Ktor resolves engines through a ServiceLoader.
-keep class io.ktor.client.engine.okhttp.OkHttpEngineContainer { *; }

# --- OkHttp / Okio (the Ktor engine on Android) ---
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-keepnames class okhttp3.internal.publicsuffix.PublicSuffixDatabase

# --- Misc ---
# Ktor pulls slf4j in transitively but the app never configures a logger.
-dontwarn org.slf4j.**
