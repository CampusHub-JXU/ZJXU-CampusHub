import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties()
if (keystorePropsFile.exists()) {
    keystoreProps.load(keystorePropsFile.inputStream())
}

fun envOrProp(envKey: String, propKey: String): String {
    return System.getenv(envKey)?.takeIf { it.isNotEmpty() }
        ?: keystoreProps.getProperty(propKey, "")
}

android {
    namespace = "edu.zjxu.jxucampushub"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "edu.zjxu.jxucampushub"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val ksFilePath = envOrProp("KEYSTORE_FILE", "storeFile")
            if (ksFilePath.isNotEmpty()) {
                storeFile = file(ksFilePath)
                storePassword = envOrProp("KEYSTORE_PASSWORD", "storePassword")
                keyAlias = envOrProp("KEY_ALIAS", "keyAlias")
                keyPassword = envOrProp("KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            val ksFilePath = envOrProp("KEYSTORE_FILE", "storeFile")
            if (ksFilePath.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }

        release {
            val ksFilePath = envOrProp("KEYSTORE_FILE", "storeFile")
            if (ksFilePath.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(platform("com.google.firebase:firebase-bom:33.12.0"))
    implementation("com.google.firebase:firebase-messaging")
}
