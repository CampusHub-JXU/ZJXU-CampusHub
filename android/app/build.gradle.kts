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

val releaseKeystorePath = envOrProp("KEYSTORE_FILE", "storeFile")
val releaseSigningInputs = mapOf(
    "KEYSTORE_FILE/storeFile" to releaseKeystorePath,
    "KEYSTORE_PASSWORD/storePassword" to envOrProp("KEYSTORE_PASSWORD", "storePassword"),
    "KEY_ALIAS/keyAlias" to envOrProp("KEY_ALIAS", "keyAlias"),
    "KEY_PASSWORD/keyPassword" to envOrProp("KEY_PASSWORD", "keyPassword"),
)

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
            if (releaseKeystorePath.isNotEmpty()) {
                storeFile = file(releaseKeystorePath)
                storePassword = releaseSigningInputs.getValue("KEYSTORE_PASSWORD/storePassword")
                keyAlias = releaseSigningInputs.getValue("KEY_ALIAS/keyAlias")
                keyPassword = releaseSigningInputs.getValue("KEY_PASSWORD/keyPassword")
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
            if (releaseKeystorePath.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// Keep debug builds usable without private signing material, but fail closed as
// soon as a release task is actually requested. An unsigned or debug-signed APK
// cannot replace an installed production build and must never be published.
gradle.taskGraph.whenReady {
    val requestsReleaseBuild = allTasks.any { task ->
        task.project == project && task.name.contains("Release", ignoreCase = true)
    }
    if (requestsReleaseBuild) {
        val missingInputs = releaseSigningInputs
            .filterValues { it.isBlank() }
            .keys
            .sorted()
        if (missingInputs.isNotEmpty()) {
            throw GradleException(
                "Release signing is required; missing: ${missingInputs.joinToString()}",
            )
        }
        val keystoreFile = file(releaseKeystorePath)
        if (!keystoreFile.isFile) {
            throw GradleException("Release signing keystore does not exist: ${keystoreFile.path}")
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
