import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mstrdialup.strait"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // One signing key for every build (CI and local), so a new APK can
    // update the installed app. The keystore is git-ignored: CI restores it
    // from repository secrets, locally it lives in keystore/ at the repo root. Without
    // it, builds fall back to the machine's own debug key.
    val sharedKeystore = rootProject.file("../../keystore/ci-debug.jks")
    val keystoreProps = Properties().apply {
        val f = rootProject.file("../../keystore/keystore.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    fun keystoreValue(name: String, env: String): String? =
        System.getenv(env) ?: keystoreProps.getProperty(name)
    val hasSharedKey = sharedKeystore.exists() &&
        keystoreValue("storePassword", "CI_KEYSTORE_PASSWORD") != null

    signingConfigs {
        if (hasSharedKey) {
            create("shared") {
                storeFile = sharedKeystore
                storePassword = keystoreValue("storePassword", "CI_KEYSTORE_PASSWORD")
                keyAlias = keystoreValue("keyAlias", "CI_KEY_ALIAS") ?: "oceanabrp"
                keyPassword = keystoreValue("keyPassword", "CI_KEYSTORE_PASSWORD")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mstrdialup.strait"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            if (hasSharedKey) signingConfig = signingConfigs.getByName("shared")
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName(if (hasSharedKey) "shared" else "debug")
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
