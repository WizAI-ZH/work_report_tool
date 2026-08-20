plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.work_report_generator"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.work_report_generator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 显式配置签名 keystore 路径，不依赖 Android Gradle Plugin 的默认
            // debug.keystore 路径查找（CI 环境 ANDROID_SDK_HOME/HOME 不一致会导致
            // 查找路径不同，每次构建用临时生成的 keystore，签名不一致无法覆盖安装）。
            // android/app/debug.keystore 由 CI 从 GitHub Secret 恢复（内容与本地
            // ~/.android/debug.keystore 相同），本地开发时文件不存在则 fallback
            // 到默认 debug 签名（与本地 ~/.android/debug.keystore 一致）。
            val storeFile = file("debug.keystore")
            signingConfig = if (storeFile.exists()) {
                signingConfigs.create("releaseKeystore") {
                    this.storeFile = storeFile
                    storePassword = "android"
                    keyAlias = "androiddebugkey"
                    keyPassword = "android"
                }
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
