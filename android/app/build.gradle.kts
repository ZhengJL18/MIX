plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mix.app"
    // permission_handler_android 要求 compileSdk 37+。
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    // 固定签名：CI 与本地构建共用 android/app/jailer-release.jks，
    // 保证所有构建产物签名一致，更新时可覆盖安装不丢数据。
    // 「所有文件访问」权限（MANAGE_EXTERNAL_STORAGE）在 debug 签名下受限，
    // 必须用固定签名构建 release 包才能正常授予。
    signingConfigs {
        create("release") {
            storeFile = file("../app/jailer-release.jks")
            storePassword = "jailer2026"
            keyAlias = "jailer"
            keyPassword = "jailer2026"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.mix.app"
        // serious_python 要求 minSdk 23+（CPython 运行时 modern packaging 从
        // APK 内存映射加载 native libs）。Flutter 默认值可能低于 23，显式指定。
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只打 arm64：MIX 瘦身策略（放弃 32 位老机型）。
        // serious_python 的 android wheel 也是 arm64_v8a，与之一致。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("release")
        }
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
