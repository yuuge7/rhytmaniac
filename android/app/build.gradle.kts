import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives in <project root>/key.properties (gitignored) and points
// at a keystore, by default <project root>/rhytmaniac-release.jks. CI writes
// both files from repository secrets. Without them, release builds fall back to
// the debug key so contributors can still run `flutter run --release`.
val projectRoot: File = rootProject.projectDir.parentFile
val keystorePropertiesFile = File(projectRoot, "key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) FileInputStream(keystorePropertiesFile).use { load(it) }
}
val hasReleaseKey = keystorePropertiesFile.exists()

android {
    namespace = "com.rhytmaniac.rhytmaniac"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.rhytmaniac.rhytmaniac"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Set from pubspec.yaml, or from --build-name / --build-number in CI.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                val store = keystoreProperties.getProperty("storeFile")
                storeFile = File(store).let { if (it.isAbsolute) it else File(projectRoot, store) }
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("key.properties not found: signing the release build with the debug key.")
                signingConfigs.getByName("debug")
            }
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
