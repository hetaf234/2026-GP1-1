import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services") apply false
}

// Only the explicit, separate UI preview skips Firebase configuration.
val misbarDefines = providers.gradleProperty("dart-defines").orNull
    ?.split(",")
    ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    .orEmpty()
val dishUiPreview = "MISBAR_DISH_PREVIEW=true" in misbarDefines
val secondCopy = "MISBAR_SECOND_COPY=true" in misbarDefines

if (dishUiPreview && secondCopy) {
    error("Choose either the design preview or the Firebase-connected second copy.")
}

if ((dishUiPreview || secondCopy) && gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }) {
    error("Local preview and second-copy applications are debug builds only.")
}
if (!dishUiPreview) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.example.flutter_application_1"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.flutter_application_1"
        if (dishUiPreview) {
            applicationIdSuffix = ".dishpreview"
        }
        manifestPlaceholders["appLabel"] = when {
            dishUiPreview -> "Misbar Preview"
            secondCopy -> "مسبار ٢"
            else -> "misbar"
        }
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Opt-in flavor only: ordinary team builds retain their existing package,
    // commands and Firebase file. This copy uses src/misbar2/google-services.json.
    if (secondCopy) {
        flavorDimensions += "localCopy"
        productFlavors {
            create("misbar2") {
                dimension = "localCopy"
                applicationIdSuffix = ".misbar2"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
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
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.activity:activity:1.8.2")
}
