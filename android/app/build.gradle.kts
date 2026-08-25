import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import org.jetbrains.kotlin.konan.properties.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── OCR/ASR 编译开关（--dart-define）──
// 默认关闭：不编入 OCR(fast_paddle/NCNN) 与 ASR(sherpa-onnx/onnxruntime) 的 native 库，减小 APK。
// 开启：flutter build apk --release --dart-define=ENABLE_OCR=true --dart-define=ENABLE_ASR=true
val dartDefinesProp = project.findProperty("dart-defines") as String?
val dartDefines: List<String> = if (dartDefinesProp != null) {
    try {
        val json = String(Base64.getDecoder().decode(dartDefinesProp))
        Regex("\"([^\"]*)\"").findAll(json).map { it.groupValues[1] }.toList()
    } catch (_: Exception) {
        emptyList()
    }
} else {
    emptyList()
}
val enableOcr = dartDefines.any { it == "ENABLE_OCR=true" }
val enableAsr = dartDefines.any { it == "ENABLE_ASR=true" }
println("PiliPlus build flags: enableOcr=$enableOcr enableAsr=$enableAsr dartDefines=$dartDefinesProp")

// fast_paddle_ocr 引入 ucrop 2.2.9，与项目既有 ucrop 2.2.11 冲突 → 强制统一版本
configurations.all {
    resolutionStrategy {
        force("com.github.yalantis:ucrop:2.2.11")
    }
}

android {
    namespace = "com.example.piliplus"
    compileSdk = flutter.compileSdkVersion

    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.piliplus"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        // 版本名：U + 主版本号（3.0.0 → U3；之前 U2.1 是 U+主.次）
        versionName = "U${flutter.versionName.substringBefore('.')}"
    }

    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
            // OCR 引擎（fast_paddle_ocr/NCNN）仅编入 arm64 包：
            // 从 armv7 包中排除其原生库，保持 arm32 包体积不变。
            excludes += "lib/armeabi-v7a/libppocrv5ncnn.so"
            // 开关关闭时排除 OCR/ASR native 库（瘦包）。
            // fast_paddle_ocr 的 PPOCRv5Ncnn 已改为启动加载失败静默，可安全排除。
            if (!enableOcr) {
                excludes += "lib/arm64-v8a/libppocrv5ncnn.so"
                excludes += "lib/x86_64/libppocrv5ncnn.so"
            }
            if (!enableAsr) {
                excludes += "lib/arm64-v8a/libsherpa-onnx-c-api.so"
                excludes += "lib/arm64-v8a/libsherpa-onnx-cxx-api.so"
                excludes += "lib/arm64-v8a/libonnxruntime.so"
                excludes += "lib/armeabi-v7a/libsherpa-onnx-c-api.so"
                excludes += "lib/armeabi-v7a/libsherpa-onnx-cxx-api.so"
                excludes += "lib/armeabi-v7a/libonnxruntime.so"
                excludes += "lib/x86_64/libsherpa-onnx-c-api.so"
                excludes += "lib/x86_64/libsherpa-onnx-cxx-api.so"
                excludes += "lib/x86_64/libonnxruntime.so"
            }
        }
    }

    val keyProperties = Properties().also {
        val properties = rootProject.file("key.properties")
        if (properties.exists())
            it.load(properties.inputStream())
    }

    val config = keyProperties.getProperty("storeFile")?.let {
        signingConfigs.create("release") {
            storeFile = file(it)
            storePassword = keyProperties.getProperty("storePassword")
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    buildFeatures {
        if (project.hasProperty("dev")) {
            resValues = true
        }
    }

    buildTypes {
        all {
            signingConfig = config ?: signingConfigs["debug"]
        }
        release {
            if (project.hasProperty("dev")) {
                applicationIdSuffix = ".dev"
                resValue(
                    type = "string",
                    name = "app_name",
                    value = "PiliPlus dev",
                )
            }
//            proguardFiles(
//                getDefaultProguardFile("proguard-android-optimize.txt"),
//                "proguard-rules.pro"
//            )
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    applicationVariants.all {
        val variant = this
        variant.outputs.forEach { output ->
            (output as ApkVariantOutputImpl).versionCodeOverride = flutter.versionCode
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Android 16 Live Updates（实时更新）需要 NotificationCompat.setRequestPromotedOngoing /
    // NotificationCompat.ProgressStyle，androidx.core >= 1.16（audio_service 仅引入 1.13.1，此处提升）
    implementation("androidx.core:core:1.17.0")
}

flutter {
    source = "../.."
}
