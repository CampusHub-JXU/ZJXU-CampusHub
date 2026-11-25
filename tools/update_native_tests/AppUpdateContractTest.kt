package edu.zjxu.jxucampushub.platform.update

/**
 * Production `AppUpdateContract.parseCanonicalAssetUrl` against the three trusted
 * URL shapes (GitHub / EdgeOne gh-proxy / R2 custom domain) and fail-closed rejects.
 *
 * `android.net.Uri` is the desktop stub (`stubs/Uri.kt`, backed by `java.net.URI`);
 * it is stricter than Android about illegal characters (backslash throws and is
 * mapped to null) and decodes `pathSegments`, which is what the contract relies on.
 */
internal fun runContractTests() {
    val gh = "https://github.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1.2.3/app-release.apk"
    val mirror = "https://edgeone.gh-proxy.org/$gh"
    val r2 = "https://download.fhfanshu.xyz/v1.2.3/app-release.apk"
    val parse: (String?) -> AppUpdateContract.CanonicalAsset? = { AppUpdateContract.parseCanonicalAssetUrl(it) }

    // Accepted shapes: url is the full original string, tag / fileName come from the path.
    parse(gh)!!.let {
        check(it.url == gh && it.tag == "v1.2.3" && it.fileName == "app-release.apk")
        check(it.source == AppUpdateContract.SOURCE_GITHUB)
    }
    parse(mirror)!!.let {
        check(it.url == mirror && it.tag == "v1.2.3" && it.fileName == "app-release.apk")
        check(it.source == AppUpdateContract.SOURCE_EDGEONE)
    }
    parse(r2)!!.let {
        check(it.url == r2 && it.tag == "v1.2.3" && it.fileName == "app-release.apk")
        check(it.source == AppUpdateContract.SOURCE_R2)
    }
    // Host compare stays case-insensitive for the plain shapes (existing behaviour).
    check(parse("https://GITHUB.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk") != null)
    check(parse("https://Download.FHFanshu.xyz/v1/a.apk") != null)
    // Surrounding whitespace is trimmed; url keeps the trimmed value.
    check(parse("  $r2 ")!!.url == r2)

    val rejects = listOf(
        "null/blank" to "",
        // wrong host / scheme
        "wrong host" to "https://example.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk",
        "http github" to gh.replaceFirst("https", "http"),
        "http r2" to r2.replaceFirst("https", "http"),
        "http mirror" to mirror.replaceFirst("https://edgeone", "http://edgeone"),
        "github lookalike suffix" to "https://github.com.evil.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk",
        "github lookalike prefix" to "https://evilgithub.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk",
        "r2 lookalike suffix" to "https://download.fhfanshu.xyz.evil.com/v1/a.apk",
        "r2 lookalike prefix" to "https://xdownload.fhfanshu.xyz/v1/a.apk",
        "r2 sibling subdomain" to "https://a.download.fhfanshu.xyz/v1/a.apk",
        "r2 apex" to "https://fhfanshu.xyz/v1/a.apk",
        "mirror other subdomain" to "https://gh-proxy.org/$gh",
        "mirror lookalike host" to "https://edgeone.gh-proxy.org.evil.com/$gh",
        // path shape
        "r2 extra segment" to "https://download.fhfanshu.xyz/extra/v1/a.apk",
        "r2 one segment" to "https://download.fhfanshu.xyz/a.apk",
        "r2 root" to "https://download.fhfanshu.xyz/",
        "r2 missing apk suffix" to "https://download.fhfanshu.xyz/v1/app-release",
        "r2 non-apk" to "https://download.fhfanshu.xyz/v1/app-release.zip",
        "github missing apk suffix" to gh.removeSuffix(".apk"),
        "github wrong owner" to gh.replace("FHfanshu", "someone"),
        "github wrong repo" to gh.replace("ZJXU-CampusHub", "Other"),
        "github extra segment" to gh.replace("/v1.2.3/", "/x/v1.2.3/"),
        "github not release download" to gh.replace("/releases/download/", "/archive/"),
        // encoded traversal / separators
        "encoded dotdot r2" to "https://download.fhfanshu.xyz/%2e%2e/app.apk",
        "encoded dotdot github" to gh.replace("v1.2.3", "%2e%2e"),
        "encoded dotdot mirror" to mirror.replace("v1.2.3", "%2e%2e"),
        "encoded slash r2" to "https://download.fhfanshu.xyz/v1%2fx/app.apk",
        "backslash r2" to "https://download.fhfanshu.xyz/v1\\x/app.apk",
        "backslash github" to gh.replace("v1.2.3", "v1\\x"),
        "backslash mirror" to mirror.replace("v1.2.3", "v1\\x"),
        // authority / query / fragment
        "port r2" to "https://download.fhfanshu.xyz:443/v1/app.apk",
        "port github" to gh.replace("github.com", "github.com:443"),
        "port mirror outer" to mirror.replace("gh-proxy.org/", "gh-proxy.org:443/"),
        "userinfo r2" to "https://user:pw@download.fhfanshu.xyz/v1/app.apk",
        "userinfo github" to gh.replace("https://", "https://user@"),
        "query r2" to "$r2?x=1",
        "query github" to "$gh?x=1",
        "query mirror" to "$mirror?x=1",
        "fragment r2" to "$r2#frag",
        "fragment github" to "$gh#frag",
        "fragment mirror" to "$mirror#frag",
        // mirror prefix is exact and case-sensitive, followed immediately by github shape
        "mirror prefix upper host" to "https://EDGEONE.gh-proxy.org/$gh",
        "mirror prefix mixed case" to "https://edgeone.GH-PROXY.org/$gh",
        "mirror prefix upper scheme" to "HTTPS://edgeone.gh-proxy.org/$gh",
        "mirror double prefix" to "https://edgeone.gh-proxy.org/$mirror",
        "mirror + r2 inner" to "https://edgeone.gh-proxy.org/$r2",
        "mirror + other inner" to "https://edgeone.gh-proxy.org/https://example.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk",
        "mirror + lookalike inner" to "https://edgeone.gh-proxy.org/https://github.com.evil.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk",
        "mirror + http inner" to "https://edgeone.gh-proxy.org/${gh.replaceFirst("https", "http")}",
        "mirror + no scheme inner" to "https://edgeone.gh-proxy.org/github.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk",
        "mirror + upper inner host" to "https://edgeone.gh-proxy.org/https://GITHUB.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/v1/a.apk",
        "mirror + extra path before inner" to "https://edgeone.gh-proxy.org/x/$gh",
        "mirror + inner missing apk" to mirror.removeSuffix(".apk"),
        "mirror no inner" to "https://edgeone.gh-proxy.org/",
        "mirror prefix without slash" to "https://edgeone.gh-proxy.org",
        "mirror + inner userinfo" to "https://edgeone.gh-proxy.org/${gh.replace("https://", "https://u@")}",
        "mirror + inner port" to "https://edgeone.gh-proxy.org/${gh.replace("github.com", "github.com:443")}",
    )
    for ((name, url) in rejects) {
        check(parse(url) == null) { "should reject ($name): $url" }
    }
    val local = "http://10.0.2.2:8000/v1/app.apk"
    for (port in listOf(1024, 8000, 65535)) {
        val url = local.replace(":8000", ":" + port)
        check(AppUpdateContract.parseCanonicalAssetUrl(url, true)?.source == "test")
        check(AppUpdateContract.parseCanonicalAssetUrl(url, false) == null)
    }
    val localRejects = listOf(
        local.replace(":8000", ""), local.replace(":8000", ":1023"), local.replace(":8000", ":65536"),
        local.replace("10.0.2.2", "localhost"), local.replace("10.0.2.2", "10.0.2.2.evil"),
        local.replace("10.0.2.2", "user@10.0.2.2"), local.replace("http:", "https:"),
        local + "?x=1", local + "#fragment", local + "/", local.replace("/v1/", "//v1/"),
        local.replace("/v1/", "/a/v1/"), local.replace("/v1/", "/%2e%2e/"),
        local.replace("app.apk", "app%2f.apk"), local.replace("app.apk", "app%252f.apk"),
        local.replace("app.apk", "app.txt"), local.replace("v1", "v%09x"),
    )
    for (url in localRejects) check(AppUpdateContract.parseCanonicalAssetUrl(url, true) == null) { url }
    check(parse(null) == null)
    check(parse("https://download.fhfanshu.xyz/" + "a".repeat(AppUpdateContract.MAX_URL_LENGTH)) == null)
    println("AppUpdate contract URL allow-list: 3 accepted shapes, ${rejects.size} rejects passed")
}
