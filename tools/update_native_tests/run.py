"""Compile and run production update lifecycle logic with cached Kotlin/JDK.

Run from any directory: python tools/update_native_tests/run.py
Requires the repository Kotlin compiler in the Gradle cache (an Android build
populates it). Never downloads tools, installs an APK, or touches a device.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gradle-home", type=Path)
    parser.add_argument("--java", default=shutil.which("java"))
    args = parser.parse_args()
    if not args.java:
        parser.error("Java not found; add the JDK bin directory to PATH")
    repo = Path(__file__).resolve().parents[2]
    settings = (repo / "android/settings.gradle.kts").read_text(encoding="utf-8")
    version = re.search(r'id\("org.jetbrains.kotlin.android"\) version "([^"]+)"',
                        settings).group(1)
    home = args.gradle_home or Path(os.environ.get("GRADLE_USER_HOME",
                                                 Path.home() / ".gradle"))
    cache = home / "caches/modules-2/files-2.1"

    def jar(group, artifact, release):
        matches = sorted((cache / group / artifact / release).glob("*/*.jar"))
        if not matches:
            parser.error(f"Missing cached {artifact}:{release}; run an Android build first")
        return matches[0]

    stdlib = jar("org.jetbrains.kotlin", "kotlin-stdlib", version)
    classpath = [
        jar("org.jetbrains.kotlin", name, version)
        for name in ("kotlin-compiler-embeddable", "kotlin-build-tools-api",
                     "kotlin-stdlib", "kotlin-script-runtime", "kotlin-daemon-embeddable")
    ]
    classpath += [
        jar("org.jetbrains.kotlin", "kotlin-reflect", "1.6.10"),
        jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.0"),
    ]
    # Code generation needs JetBrains annotations; use one cached version.
    annotations = sorted((cache / "org.jetbrains/annotations").glob("*/*/*.jar"))
    if not annotations:
        parser.error("Missing cached JetBrains annotations; run an Android build first")
    classpath.append(annotations[-1])
    source_dir = repo / "android/app/src/main/kotlin/edu/zjxu/jxucampushub/platform/update"
    production = [source_dir / f"{name}.kt" for name in (
        "AppUpdateOwnership", "AppUpdateContract", "AppUpdateStore", "AppUpdateManager",
        "AppUpdateDownloadReceiver", "AppUpdateMachine", "AppUpdateVersions",
    )]
    tests = Path(__file__).parent
    sources = production + sorted(tests.glob("*.kt")) + sorted((tests / "stubs").glob("*.kt"))
    temp_root = repo / "output/update_native_tests"
    temp_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jxu_update_native_", dir=temp_root) as temp:
        output = Path(temp) / "tests.jar"
        subprocess.run([
            args.java, "-cp", os.pathsep.join(map(str, classpath)),
            "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib",
            "-no-reflect", "-nowarn", "-classpath", str(stdlib), "-d", str(output),
            *map(str, sources),
        ], check=True)
        subprocess.run([
            args.java, "-cp", os.pathsep.join(map(str, (output, stdlib))),
            "edu.zjxu.jxucampushub.platform.update.AppUpdateLifecycleTestKt", temp, str(tests / "version_cases.tsv"),
        ], check=True)


if __name__ == "__main__":
    main()
