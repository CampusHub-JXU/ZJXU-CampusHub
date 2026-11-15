package edu.zjxu.jxucampushub.platform.wechat

import android.content.ActivityNotFoundException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 本地 JVM 单测：用 fake [WeChatLaunchGateway] 覆盖 [WeChatLaunchPlanner]
 * 的全部分支。gradle testOptions.returnDefaultValues 使 android.jar 里的
 * ActivityNotFoundException 可以在 JVM 上实例化。
 */
class WeChatLaunchPlannerTest {

    private class FakeGateway(
        var installed: Boolean = true,
        var handler: Any? = Any(),
        var appLaunchTarget: Any? = Any(),
        var launchError: Exception? = null,
    ) : WeChatLaunchGateway {
        val launchedTargets = mutableListOf<Any>()
        var resolveCalls = 0
        var resolveAppCalls = 0

        override fun isWeChatInstalled(): Boolean = installed

        override fun resolveHandler(url: String): Any? {
            resolveCalls += 1
            return handler
        }

        override fun resolveWeChatAppLaunch(): Any? {
            resolveAppCalls += 1
            return appLaunchTarget
        }

        override fun launch(resolved: Any) {
            launchError?.let { throw it }
            launchedTargets += resolved
        }
    }

    private class TestException(message: String) : Exception(message)

    private fun plannerWith(gateway: FakeGateway) = WeChatLaunchPlanner(gateway)

    // ---------- unsupported_url ----------

    @Test
    fun `blank url returns unsupported_url`() {
        val gateway = FakeGateway()
        val result = plannerWith(gateway).openUrlInWeChat("   ")
        assertEquals(WeChatLaunchPlanner.STATUS_UNSUPPORTED_URL, result.status)
        assertEquals(0, gateway.resolveCalls)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    @Test
    fun `url without allowed scheme returns unsupported_url`() {
        for (url in listOf(
            "example.com/page",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "wechat://pay",
            "foo://bar",
        )) {
            val gateway = FakeGateway()
            val result = plannerWith(gateway).openUrlInWeChat(url)
            assertEquals("url: $url", WeChatLaunchPlanner.STATUS_UNSUPPORTED_URL, result.status)
            assertEquals(0, gateway.resolveCalls)
        }
    }

    @Test
    fun `allowed schemes are http https and weixin`() {
        for (url in listOf(
            "https://example.com/a?b=1",
            "http://example.com",
            "weixin://dl/business/?ticket=abc",
            "HTTPS://EXAMPLE.COM/",
        )) {
            val gateway = FakeGateway()
            val result = plannerWith(gateway).openUrlInWeChat(url)
            assertEquals("url: $url", WeChatLaunchPlanner.STATUS_LAUNCHED, result.status)
        }
    }

    // ---------- not_installed ----------

    @Test
    fun `wechat not installed returns not_installed without resolving`() {
        val gateway = FakeGateway(installed = false)
        val result = plannerWith(gateway).openUrlInWeChat("https://example.com")
        assertEquals(WeChatLaunchPlanner.STATUS_NOT_INSTALLED, result.status)
        assertEquals(0, gateway.resolveCalls)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    // ---------- no_handler ----------

    @Test
    fun `unresolvable intent returns no_handler`() {
        // gateway 返回 null 对应 resolveActivity 无匹配，
        // 或匹配组件未导出（activityInfo.exported == false）被过滤。
        val gateway = FakeGateway(handler = null)
        val result = plannerWith(gateway).openUrlInWeChat("https://example.com")
        assertEquals(WeChatLaunchPlanner.STATUS_NO_HANDLER, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_ACTION_VIEW_WECHAT, result.route)
        assertEquals(1, gateway.resolveCalls)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    @Test
    fun `non exported match is filtered to no_handler`() {
        // 语义上等同于 resolveActivity 命中但 activityInfo.exported == false：
        // gateway 必须将其过滤（返回 null），planner 绝不 fallback 到
        // 拉起微信首页。
        val gateway = FakeGateway(handler = null)
        val result = plannerWith(gateway).openUrlInWeChat("weixin://dl/business/?ticket=x")
        assertEquals(WeChatLaunchPlanner.STATUS_NO_HANDLER, result.status)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    // ---------- launched ----------

    @Test
    fun `exported handler launches and returns launched`() {
        val target = Any()
        val gateway = FakeGateway(handler = target)
        val result = plannerWith(gateway).openUrlInWeChat(" https://example.com/page ")
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCHED, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_ACTION_VIEW_WECHAT, result.route)
        assertEquals(listOf(target), gateway.launchedTargets)
    }

    // ---------- launch_failed ----------

    @Test
    fun `activity not found returns launch_failed`() {
        val gateway = FakeGateway(launchError = ActivityNotFoundException())
        val result = plannerWith(gateway).openUrlInWeChat("https://example.com")
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCH_FAILED, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_ACTION_VIEW_WECHAT, result.route)
        assertEquals("ActivityNotFoundException", result.detail)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    @Test
    fun `security exception returns launch_failed`() {
        val gateway = FakeGateway(launchError = SecurityException("not exported"))
        val result = plannerWith(gateway).openUrlInWeChat("https://example.com")
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCH_FAILED, result.status)
        assertEquals("SecurityException", result.detail)
    }

    @Test
    fun `generic exception returns launch_failed`() {
        val gateway = FakeGateway(launchError = TestException("boom"))
        val result = plannerWith(gateway).openUrlInWeChat("https://example.com")
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCH_FAILED, result.status)
        assertEquals("TestException", result.detail)
    }

    // ---------- openWeChatApp ----------

    @Test
    fun `openWeChatApp not installed returns not_installed without resolving`() {
        val gateway = FakeGateway(installed = false)
        val result = plannerWith(gateway).openWeChatApp()
        assertEquals(WeChatLaunchPlanner.STATUS_NOT_INSTALLED, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_WECHAT_APP_SCHEME, result.route)
        assertEquals(0, gateway.resolveAppCalls)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    @Test
    fun `openWeChatApp no launchable entry returns no_handler`() {
        // scheme 解析不到导出组件且 launch intent 不存在时 gateway 返回 null。
        val gateway = FakeGateway(appLaunchTarget = null)
        val result = plannerWith(gateway).openWeChatApp()
        assertEquals(WeChatLaunchPlanner.STATUS_NO_HANDLER, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_WECHAT_APP_SCHEME, result.route)
        assertEquals(1, gateway.resolveAppCalls)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    @Test
    fun `openWeChatApp launches and returns launched`() {
        val target = Any()
        val gateway = FakeGateway(appLaunchTarget = target)
        val result = plannerWith(gateway).openWeChatApp()
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCHED, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_WECHAT_APP_SCHEME, result.route)
        assertEquals(listOf(target), gateway.launchedTargets)
    }

    @Test
    fun `openWeChatApp activity not found returns launch_failed`() {
        val gateway = FakeGateway(launchError = ActivityNotFoundException())
        val result = plannerWith(gateway).openWeChatApp()
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCH_FAILED, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_WECHAT_APP_SCHEME, result.route)
        assertEquals("ActivityNotFoundException", result.detail)
        assertTrue(gateway.launchedTargets.isEmpty())
    }

    @Test
    fun `openWeChatApp security exception returns launch_failed`() {
        val gateway = FakeGateway(launchError = SecurityException("not exported"))
        val result = plannerWith(gateway).openWeChatApp()
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCH_FAILED, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_WECHAT_APP_SCHEME, result.route)
        assertEquals("SecurityException", result.detail)
    }

    @Test
    fun `openWeChatApp generic exception returns launch_failed`() {
        val gateway = FakeGateway(launchError = TestException("boom"))
        val result = plannerWith(gateway).openWeChatApp()
        assertEquals(WeChatLaunchPlanner.STATUS_LAUNCH_FAILED, result.status)
        assertEquals(WeChatLaunchPlanner.ROUTE_WECHAT_APP_SCHEME, result.route)
        assertEquals("TestException", result.detail)
    }

    // ---------- channel map shape ----------

    @Test
    fun `result serializes to status route detail map`() {
        val map = WeChatLaunchResult(
            status = WeChatLaunchPlanner.STATUS_LAUNCHED,
            route = WeChatLaunchPlanner.ROUTE_ACTION_VIEW_WECHAT,
        ).toChannelMap()
        assertEquals("launched", map["status"])
        assertEquals("action_view_wechat", map["route"])
        assertTrue(map.containsKey("detail"))
    }
}
