import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")

if (localPropertiesFile.exists()) {
    FileInputStream(localPropertiesFile).use {
        localProperties.load(it)
    }
}

val flutterVersionCode =
    localProperties.getProperty("flutter.versionCode")?.toInt() ?: 1

val flutterVersionName =
    localProperties.getProperty("flutter.versionName") ?: "1.0"

val pubspecVersionLine = rootProject.file("../pubspec.yaml")
    .readLines()
    .firstOrNull { it.startsWith("version:") }
    ?.removePrefix("version:")
    ?.trim()

val pubspecVersionParts = pubspecVersionLine?.split("+") ?: emptyList()
val pubspecVersionName = pubspecVersionParts.getOrNull(0)
val pubspecVersionCode = pubspecVersionParts.getOrNull(1)?.toIntOrNull()

fun signingProperty(envName: String, propertyName: String): String? {
    return System.getenv(envName) ?: localProperties.getProperty(propertyName)
}

android {
    namespace = "com.alicejump.danbooru_viewer"

    // 如果后面提示 compileSdk 过低，改成 34 或 35
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.alicejump.danbooru_viewer"

        minSdk = flutter.minSdkVersion
        targetSdk = 36

        versionCode = pubspecVersionCode ?: flutterVersionCode
        versionName = pubspecVersionName ?: flutterVersionName
    }

    signingConfigs {
        create("release") {
            val storeFilePath = signingProperty(
                "SIGNING_KEY_STORE_PATH",
                "signing.keystore.path"
            )
            val storePasswordValue = signingProperty(
                "SIGNING_STORE_PASSWORD",
                "signing.store.password"
            )
            val keyAliasValue = signingProperty(
                "SIGNING_KEY_ALIAS",
                "signing.key.alias"
            )
            val keyPasswordValue = signingProperty(
                "SIGNING_KEY_PASSWORD",
                "signing.key.password"
            )

            if (storeFilePath != null &&
                storePasswordValue != null &&
                keyAliasValue != null &&
                keyPasswordValue != null
            ) {
                storeFile = file(storeFilePath)
                storePassword = storePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.findByName("release")
                ?.takeIf { it.storeFile != null }
                ?: signingConfigs.getByName("debug")
        }

        release {
            signingConfig = signingConfigs.findByName("release")
                ?.takeIf { it.storeFile != null }
                ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("io.coil-kt:coil:2.4.0")
}
