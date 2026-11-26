plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.deckhand.helper"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.deckhand.helper"
        minSdk = 29
        targetSdk = 35
        versionCode = 3
        versionName = "1.1"
    }

    buildTypes {
        release {
            // signed with the debug key: the app is only ever installed over adb
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}
