import java.util.Properties

plugins {
    id("com.android.application")
    // AGP 9: do not apply the Kotlin Gradle plugin here. The Flutter Gradle
    // plugin applies it (android.builtInKotlin=false); it must come after AGP.
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
            // 与 release 包名隔离，便于在真机上与正式版共存并测试微信跳转。
            applicationIdSuffix = ".dev"
            val ksFilePath = envOrProp("KEYSTORE_FILE", "storeFile")
            if (ksFilePath.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }

        // 真机微信跳转联调：AOT 构建，体积远小于 debug，debug 签名可直接安装。
        val profileBuildType = maybeCreate("profile")
        profileBuildType.initWith(getByName("debug"))
        profileBuildType.applicationIdSuffix = ".dev"

        release {
            if (releaseKeystorePath.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    sourceSets {
        // debug 与 profile 均带 .dev 后缀，共用同一套 dev 图标覆盖（蓝色背景）。
        getByName("debug").res.srcDir("src/dev/res")
        maybeCreate("profile").res.srcDir("src/dev/res")
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
    implementation(platform("com.google.firebase:firebase-bom:33.12.0"))
    implementation("com.google.firebase:firebase-messaging")
}
