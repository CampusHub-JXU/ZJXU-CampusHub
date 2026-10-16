package edu.zjxu.jxucampushub.platform.update

/** 唯一宿主入口：生产逻辑 + 最小 Android IO 桩，不构建 APK、不接触设备。 */
fun main(args: Array<String>) {
    runContractTests()
    runVersionsTests(java.io.File(args[1]))
    runMachineTests()
    runStoreTests()
    runManagerTests(java.io.File(args[0]))
    println("AppUpdate native tests: ALL PASSED")
}
