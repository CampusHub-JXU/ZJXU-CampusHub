allprojects {
    repositories {
        // Aliyun mirrors for China — FIRST so google()/mavenCentral() are only
        // fallbacks; skipped in CI (set CI=true in workflow).
        if (System.getenv("CI") != "true") {
            maven(url = "https://maven.aliyun.com/repository/google")
            maven(url = "https://maven.aliyun.com/repository/public")
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Flutter 3.50's PluginHandler copies :app's `profile` buildType onto library
    // plugins via `initWith(appBuildType)`, which leaks `applicationIdSuffix = ".dev"`
    // and fails AGP 9.3.1 validation on library modules. Pre-creating `profile` on
    // library modules from their own `debug` buildType avoids that copy.
    pluginManager.withPlugin("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> {
            buildTypes {
                maybeCreate("profile").apply {
                    initWith(getByName("debug"))
                }
            }
        }
    }

    // workmanager_android 0.9.3 skips `kotlin-android` on AGP 9 because it
    // assumes built-in Kotlin, but this build keeps android.builtInKotlin=false
    // (other plugins still apply KGP themselves). Without this its Kotlin
    // sources are never compiled and GeneratedPluginRegistrant cannot find
    // WorkmanagerPlugin. Its Java side targets 1.8, so Kotlin must match.
    // Drop together with the builtInKotlin opt-out.
    if (name == "workmanager_android") {
        pluginManager.withPlugin("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
            }
        }
    }
}

// Must stay a separate, later block: it forces :app to evaluate, and every
// subproject needs the shim above registered before that can happen.
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
