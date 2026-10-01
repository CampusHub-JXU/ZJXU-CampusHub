import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/notice/notice_detail.dart';

/// 合成夹具：结构照抓包确认的博达 VSB 教务处详情模板（非真实公告内容）。
String _page({String body = '', String attachments = ''}) =>
    '''
<html><body><form name="_newscontent_fromname">
<div class="newsDetail newsDetailV2" newsid="346">
<div class="title" style=";text-align: center;">关于测试事项的通知</div>
<div class="newsInfoWrap"><div class="leftInfo">
<span class="newsInfo">发表时间：26-09-18 10:26:49</span>
<span class="newsInfo">来源：
    </span>
<span class="newsInfo">点击数：<script>_showDynClicks("wbnews", 1, 2)</script></span>
</div></div>
<div id='vsb_content' class="bg"><div class='v_news_content'>
$body
</div></div><div id="div_vote_id"></div>
<p><UL style="list-style-type:none;">$attachments</UL></p>
<p align=right>下一篇：<a href="content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=9">下一条</a></p>
</div></form></body></html>
''';

const _pageUrl =
    'https://jwc.zjxu.edu.cn/content.jsp?urltype=news.NewsContentUrl&wbtreeid=1046&wbnewsid=1';

NoticeDetail _parse(String html) =>
    parseNoticeDetailHtml(html, pageUrl: _pageUrl)!;

void main() {
  group('isJwcNoticeDetailUrl', () {
    test('accepts content.jsp and static info pages on jwc', () {
      expect(isJwcNoticeDetailUrl(_pageUrl), isTrue);
      expect(
        isJwcNoticeDetailUrl('https://jwc.zjxu.edu.cn/info/1048/10917.htm'),
        isTrue,
      );
    });

    test('rejects other hosts and non-detail pages', () {
      expect(isJwcNoticeDetailUrl('https://jwc.zjxu.edu.cn/list.jsp'), isFalse);
      expect(
        isJwcNoticeDetailUrl('https://sjjx.zjxu.edu.cn/content.jsp?id=1'),
        isFalse,
      );
      expect(isJwcNoticeDetailUrl('not a url ::'), isFalse);
    });
  });

  group('parseNoticeDetailHtml', () {
    test('returns null when the template structure is missing', () {
      expect(
        parseNoticeDetailHtml(
          '<html><body><p>登录</p></body></html>',
          pageUrl: _pageUrl,
        ),
        isNull,
      );
    });

    test(
      'extracts title and normalizes publish time, empty source is null',
      () {
        final detail = _parse(_page(body: '<p>正文</p>'));
        expect(detail.title, '关于测试事项的通知');
        expect(detail.publishedAt, '2026-09-18 10:26');
        expect(detail.source, isNull);
      },
    );

    test('paragraphs keep indent, bold, red emphasis and absolute links', () {
      final detail = _parse(
        _page(
          body: '''
<p style="line-height:37px"><span style="font-family: 仿宋;">各学院：</span></p>
<p style="line-height: 150%; text-indent: 2em;"><span><strong><span>一、报名条件</span></strong></span></p>
<p style="text-indent: 2em;">请于<strong><span style="color: rgb(192, 0, 0);">10月8日前</span></strong>登录
<a href="http://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html">教务系统</a>报名。</p>
<p><br></p>
''',
        ),
      );
      final paragraphs = detail.blocks.cast<NoticeParagraph>();
      expect(paragraphs, hasLength(3), reason: '空段落被丢弃');
      expect(paragraphs[0].plainText, '各学院：');
      expect(paragraphs[0].indent, isFalse);
      expect(paragraphs[1].indent, isTrue);
      expect(paragraphs[1].spans.single.bold, isTrue);

      final spans = paragraphs[2].spans;
      final deadline = spans.firstWhere((s) => s.text == '10月8日前');
      expect(deadline.bold, isTrue);
      expect(deadline.emphasis, isTrue);
      final link = spans.firstWhere((s) => s.link != null);
      expect(link.text, '教务系统');
      expect(
        link.link,
        'http://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html',
      );
      expect(paragraphs[2].plainText, '请于10月8日前登录 教务系统报名。');
    });

    test('images resolve against the page URL with declared size', () {
      final detail = _parse(
        _page(
          body:
              '<p><img src="/__local/6/E7/a.jpg" width="368" height="521"></p>',
        ),
      );
      final image = detail.blocks.single as NoticeImage;
      expect(image.url, 'https://jwc.zjxu.edu.cn/__local/6/E7/a.jpg');
      expect(image.width, 368);
      expect(image.height, 521);
    });

    test('simple tables become rows; merged cells are flagged', () {
      final detail = _parse(
        _page(
          body: '''
<table><tbody>
<tr><td><p>学院</p></td><td><p>联系人</p></td></tr>
<tr><td><p>外国语学院</p></td><td><p>张老师</p><p>分机 1</p></td></tr>
</tbody></table>
<table><tr><td rowspan="2">合并</td><td>a</td></tr><tr><td>b</td></tr></table>
''',
        ),
      );
      final simple = detail.blocks[0] as NoticeTable;
      expect(simple.hasMergedCells, isFalse);
      expect(simple.rows, [
        ['学院', '联系人'],
        ['外国语学院', '张老师\n分机 1'],
      ]);
      expect((detail.blocks[1] as NoticeTable).hasMergedCells, isTrue);
    });

    test('collects attachments only from DownloadAttachUrl links', () {
      final detail = _parse(
        _page(
          body: '<p>见附件</p>',
          attachments: '''
<li>附件【<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&owner=1&wbfileid=7">附件1：申请表.docx</a>】已下载<span><script>getClickTimes(7)</script></span>次</li>
<li>附件【<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&owner=1&wbfileid=8">附件2：名单.xlsx</a>】</li>
''',
        ),
      );
      expect(detail.attachments.map((a) => a.name), [
        '附件1：申请表.docx',
        '附件2：名单.xlsx',
      ]);
      expect(
        detail.attachments.first.url,
        'https://jwc.zjxu.edu.cn/system/_content/download.jsp?urltype=news.DownloadAttachUrl&owner=1&wbfileid=7',
      );
    });

    test(
      'ignores DownloadAttachUrl links on other hosts or insecure schemes',
      () {
        final detail = _parse(
          _page(
            body: '<p>见附件</p>',
            attachments: '''
<li><a href="https://evil.example.com/download.jsp?urltype=news.DownloadAttachUrl&wbfileid=1">外站.docx</a></li>
<li><a href="http://jwc.zjxu.edu.cn/system/_content/download.jsp?urltype=news.DownloadAttachUrl&wbfileid=2">明文.docx</a></li>
<li><a href="https://jwc.zjxu.edu.cn.evil.example.com/d.jsp?urltype=news.DownloadAttachUrl&wbfileid=3">仿冒.docx</a></li>
<li><a href="https://jwc.zjxu.edu.cn/system/_content/download.jsp?urltype=news.DownloadAttachUrl&wbfileid=4">正常.docx</a></li>
''',
          ),
        );
        expect(detail.attachments.map((a) => a.name), ['正常.docx']);
      },
    );
  });

  group('isJwcAttachmentUrl', () {
    test('accepts only https jwc DownloadAttachUrl links', () {
      const ok =
          'https://jwc.zjxu.edu.cn/system/_content/download.jsp?urltype=news.DownloadAttachUrl&wbfileid=7';
      expect(isJwcAttachmentUrl(ok), isTrue);
      expect(isJwcAttachmentUrl(ok.replaceFirst('https', 'http')), isFalse);
      expect(
        isJwcAttachmentUrl(ok.replaceFirst('jwc.zjxu.edu.cn', 'example.com')),
        isFalse,
      );
      expect(
        isJwcAttachmentUrl(
          ok.replaceFirst('jwc.zjxu.edu.cn', 'jwc.zjxu.edu.cn@evil.com'),
        ),
        isFalse,
      );
      expect(
        isJwcAttachmentUrl(
          ok.replaceFirst('jwc.zjxu.edu.cn', 'jwc.zjxu.edu.cn:8443'),
        ),
        isFalse,
      );
      expect(
        isJwcAttachmentUrl('https://jwc.zjxu.edu.cn/content.jsp?wbnewsid=1'),
        isFalse,
      );
      expect(isJwcAttachmentUrl('not a url'), isFalse);
    });
  });
}
