# 保留规则简介
# https://developer.android.google.cn/topic/performance/app-optimization/keep-rules-overview?hl=zh-cn
#
# 这个 example 通过 cargokit 把 Rust 库以原生 so 形式打包进 APK；
# minify 只作用于 JVM/Dex 侧（应用与 Flutter 框架的 Java/Kotlin 代码），
# jniLibs 下的原生库不会被 R8 处理，因此无需为原生符号写 keep 规则。

# 防止构建因无法解析的可选依赖告警而失败。
-dontwarn com.android.org.conscrypt.**
-dontwarn org.conscrypt.**
