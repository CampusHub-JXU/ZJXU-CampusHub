// CI-only helper: fills the Gradle module cache with exactly the jars that
// tools/update_native_tests/run.py reads (run.py itself never downloads).
//
//   gradle -p tools/update_native_tests/ci --no-daemon resolveUpdateNativeTestDeps
//
// The Kotlin version is read from android/settings.gradle.kts (the same line
// run.py parses), so there is a single source of truth. -PkotlinVersion=<v>
// overrides it for experiments. The two fixed pins below must stay in
// lockstep with run.py (kotlin-reflect 1.6.10, kotlinx-coroutines 1.8.0).
import java.io.File

plugins {
    java
}

val kotlinVersion: String = (findProperty("kotlinVersion") as String?)
    ?: run {
        val settings = File(rootDir, "../../../android/settings.gradle.kts")
        check(settings.isFile) { "Missing ${settings.canonicalPath}" }
        Regex("""id\("org\.jetbrains\.kotlin\.android"\) version "([^"]+)"""")
            .find(settings.readText())
            ?.groupValues?.get(1)
            ?: error("Kotlin version not found in ${settings.canonicalPath}")
    }

repositories {
    mavenCentral()
}

dependencies {
    // Non-transitive on purpose: run.py needs these exact versions side by side
    // (e.g. kotlin-reflect 1.6.10 next to a 2.4.0 compiler), which a normal
    // dependency graph would conflict-resolve away.
    listOf(
        "kotlin-compiler-embeddable",
        "kotlin-build-tools-api",
        "kotlin-stdlib",
        "kotlin-script-runtime",
        "kotlin-daemon-embeddable",
    ).forEach { runtimeOnly("org.jetbrains.kotlin:$it:$kotlinVersion") { isTransitive = false } }
    runtimeOnly("org.jetbrains.kotlin:kotlin-reflect:1.6.10") { isTransitive = false }
    runtimeOnly("org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.8.0") { isTransitive = false }
    runtimeOnly("org.jetbrains:annotations:13.0") { isTransitive = false }
}

tasks.register("resolveUpdateNativeTestDeps") {
    val files = configurations.runtimeClasspath.map { it.files }
    doLast {
        val names = files.get().map { it.name }.sorted()
        println("Kotlin $kotlinVersion; resolved ${names.size} jars:")
        names.forEach { println("  $it") }
    }
}
