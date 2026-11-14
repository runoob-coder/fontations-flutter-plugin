// The Android Gradle Plugin builds the native code with the Android NDK.

group = "com.flutter_rust_bridge.fontations"
version = "1.0"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        // The Android Gradle Plugin knows how to build native code with the NDK.
        classpath("com.android.tools.build:gradle:9.3.1")
        // Flutter applies the Kotlin Android plugin to library modules when
        // `android.builtInKotlin=false`, so its plugin must be on this classpath.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.flutter_rust_bridge.fontations"

    // Bumping the plugin compileSdk version requires all clients of this plugin
    // to bump the version in their app.
    compileSdk = 36

    // Use the NDK version declared in /android/app/build.gradle.kts of the
    // Flutter project. CargoKit reads it from the app module, so leave
    // `ndkVersion` unset here. Replace it with a version number if this plugin
    // requires a specific NDK version (e.g. ndkVersion = "23.1.7779620").

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 19
    }
}

// CargoKit ships a Groovy script whose extension is declared inside that
// script, so Kotlin DSL has no typed `cargokit {}` accessor. Configure the
// extension through the underlying Groovy object after applying the script.
apply(from = "../cargokit/gradle/plugin.gradle")

val cargokit = extensions.getByName("cargokit") as groovy.lang.GroovyObject
cargokit.setProperty("manifestDir", "../rust")
cargokit.setProperty("libname", "fontations")
