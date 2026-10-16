package edu.zjxu.jxucampushub.platform.update

internal fun runVersionsTests(file: java.io.File) {
    var count = 0
    for (line in file.readLines()) {
        if (line.isBlank() || line.startsWith("#")) continue
        val parts = line.split('\t')
        check(parts.size == 3) { "bad version fixture: " + line }
        check(AppUpdateVersions.isVersionNewer(parts[0], parts[1]) == parts[2].toBooleanStrict()) { line }
        count++
    }
    println("AppUpdateVersions: " + count + " shared cases passed")
}
