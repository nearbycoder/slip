# kotlinx.serialization keeps generated serializers via its own consumer rules.
# BouncyCastle is reached through JCA reflection.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
