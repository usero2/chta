plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val playBuild = providers.environmentVariable("CHTA_PLAY_BUILD").orNull == "1"

android {
    namespace = "app.cht.cht"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.14904198"

    androidResources {
        if (playBuild) additionalParameters.add("--exclude-sources")
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        val isQa = providers.gradleProperty("chtQa").orNull == "true"
        require(!playBuild || !isQa) { "The QA app cannot be signed for Google Play." }
        applicationId = if (isQa) "app.cht.cht.qa" else "app.cht.cht"
        manifestPlaceholders["chtAppLabel"] = if (isQa) "chta QA" else "chta"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (playBuild) {
            // Only this ABI has the Rust core in the Android bundle.
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
        }
    }

    signingConfigs {
        if (playBuild) {
            create("playUpload") {
                val path = providers.environmentVariable("CHTA_PLAY_UPLOAD_KEYSTORE").orNull
                val password = providers.environmentVariable("CHTA_PLAY_UPLOAD_PASSWORD").orNull
                require(!path.isNullOrBlank() && !password.isNullOrBlank()) {
                    "The Play upload keystore and password are required."
                }
                storeFile = file(path)
                require(storeFile?.isFile == true) { "The Play upload keystore is missing." }
                storeType = "PKCS12"
                storePassword = password
                keyAlias = "upload"
                keyPassword = password
            }
        }
    }

    buildTypes {
        release {
            // Local sideload builds retain their existing test signature.
            signingConfig = signingConfigs.getByName(if (playBuild) "playUpload" else "debug")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
