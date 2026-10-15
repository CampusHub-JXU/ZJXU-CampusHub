"""Compile the production calendar channel handler and run host JVM tests."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    java = shutil.which("java")
    if not java:
        raise SystemExit("Java not found; add the JDK bin directory to PATH")
    repo = Path(__file__).resolve().parents[2]
    settings = (repo / "android/settings.gradle.kts").read_text(encoding="utf-8")
    version = re.search(r'id\("org.jetbrains.kotlin.android"\) version "([^\"]+)"', settings).group(1)
    gradle_home = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle"))
    cache = gradle_home / "caches/modules-2/files-2.1"

    def jar(group, artifact, release):
        matches = sorted((cache / group / artifact / release).glob("*/*.jar"))
        if not matches:
            raise SystemExit(f"Missing cached {artifact}:{release}; run an Android build first")
        return matches[0]

    stdlib = jar("org.jetbrains.kotlin", "kotlin-stdlib", version)
    classpath = [jar("org.jetbrains.kotlin", name, version) for name in (
        "kotlin-compiler-embeddable", "kotlin-build-tools-api", "kotlin-stdlib",
        "kotlin-script-runtime", "kotlin-daemon-embeddable")]
    classpath += [jar("org.jetbrains.kotlin", "kotlin-reflect", "1.6.10"),
                  jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.0")]
    annotations = sorted((cache / "org.jetbrains/annotations").glob("*/*/*.jar"))
    if not annotations:
        raise SystemExit("Missing cached JetBrains annotations; run an Android build first")
    classpath.append(annotations[-1])
    source = repo / "android/app/src/main/kotlin/edu/zjxu/jxucampushub/platform/calendar"
    harness = Path(__file__).parent
    sources = [source / "CalendarSyncChannelHandler.kt", source / "CalendarSyncContract.kt"]
    sources += sorted(harness.glob("*.kt")) + sorted((harness / "stubs").glob("*.kt"))
    output_dir = repo / "output/calendar_native_tests"
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jxuc_calendar_native_", dir=output_dir) as temp:
        jar_path = Path(temp) / "tests.jar"
        subprocess.run([java, "-cp", os.pathsep.join(map(str, classpath)),
                        "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib",
                        "-no-reflect", "-nowarn", "-classpath", str(stdlib), "-d",
                        str(jar_path), *map(str, sources)], check=True)
        subprocess.run([java, "-cp", os.pathsep.join(map(str, (jar_path, stdlib))),
                        "edu.zjxu.jxucampushub.platform.calendar.CalendarSyncChannelHandlerTestKt"],
                       check=True)


if __name__ == "__main__":
    main()
