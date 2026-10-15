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

NoticeTable _tableBlock(String tableHtml) =>
    _parse(_page(body: tableHtml)).blocks.whereType<NoticeTable>().single;

NoticeTableCell _cellAt(NoticeTable table, int row, int column) =>
    table.cells.firstWhere((c) => c.row == row && c.column == column);

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

  group('notice tables', () {
    test(
      'rectangular table keeps coordinates, order, headers and newlines',
      () {
        final table = _tableBlock('''
<table><tbody>
<tr><th>学院</th><th>联系人</th></tr>
<tr><td>外国语学院</td><td><p>张老师</p><p>分机 1</p></td></tr>
</tbody></table>''');
        expect(table.supported, isTrue);
        expect(table.rowCount, 2);
        expect(table.columnCount, 2);
        expect(table.cells, hasLength(4));
        expect(table.hasHeaderCells, isTrue);
        expect(table.cells.map((c) => c.plainText).toList(), [
          '学院',
          '联系人',
          '外国语学院',
          '张老师\n分机 1',
        ]);
        expect(table.cells[0].header, isTrue);
        expect(table.cells[2].header, isFalse);
        expect(_cellAt(table, 0, 1).rowSpan, 1);
        expect(_cellAt(table, 0, 1).columnSpan, 1);
      },
    );

    test('rowspan reserves the cell below and keeps later cells aligned', () {
      final table = _tableBlock(
        '<table><tr><td rowspan="2">类别</td><td>a</td></tr>'
        '<tr><td>b</td></tr></table>',
      );
      expect(table.supported, isTrue);
      expect(table.rowCount, 2);
      expect(table.columnCount, 2);
      final span = _cellAt(table, 0, 0);
      expect(span.rowSpan, 2);
      expect(span.columnSpan, 1);
      expect(_cellAt(table, 1, 1).plainText, 'b');
      expect(table.cells.any((c) => c.row == 1 && c.column == 0), isFalse);
    });

    test('rowspan past the last row is clamped like a browser', () {
      final table = _tableBlock(
        '<table><tr><td rowspan="5">A</td><td>b</td></tr>'
        '<tr><td>c</td></tr></table>',
      );
      expect(table.supported, isTrue);
      expect(table.rowCount, 2);
      expect(_cellAt(table, 0, 0).rowSpan, 2);
      expect(_cellAt(table, 1, 1).plainText, 'c');
    });

    test('colspan spans the following columns', () {
      final table = _tableBlock(
        '<table><tr><td colspan="2">标题</td></tr>'
        '<tr><td>a</td><td>b</td></tr></table>',
      );
      expect(table.supported, isTrue);
      expect(table.columnCount, 2);
      final head = _cellAt(table, 0, 0);
      expect(head.columnSpan, 2);
      expect(head.plainText, '标题');
      expect(_cellAt(table, 1, 0).plainText, 'a');
      expect(_cellAt(table, 1, 1).plainText, 'b');
    });

    test('mixed rowspan/colspan lay out on the occupancy matrix', () {
      final table = _tableBlock('''
<table>
<tr><td rowspan="2">A</td><td colspan="2">B</td></tr>
<tr><td>C</td><td>D</td></tr>
<tr><td>E</td><td>F</td><td>G</td></tr>
</table>''');
      expect(table.supported, isTrue);
      expect(table.rowCount, 3);
      expect(table.columnCount, 3);
      expect(_cellAt(table, 0, 0).rowSpan, 2);
      expect(_cellAt(table, 0, 1).columnSpan, 2);
      expect(_cellAt(table, 1, 1).plainText, 'C');
      expect(_cellAt(table, 1, 2).plainText, 'D');
      expect(_cellAt(table, 2, 0).plainText, 'E');
      expect(_cellAt(table, 2, 2).plainText, 'G');
    });

    test('ragged rows keep implicit empty columns without inventing cells', () {
      final table = _tableBlock(
        '<table><tr><td>a</td><td>b</td><td>c</td></tr>'
        '<tr><td>d</td></tr></table>',
      );
      expect(table.supported, isTrue);
      expect(table.rowCount, 2);
      expect(table.columnCount, 3);
      expect(_cellAt(table, 1, 0).plainText, 'd');
      expect(table.cells.any((c) => c.row == 1 && c.column == 1), isFalse);
    });

    test('cell spans keep inline bold, emphasis and links', () {
      final table = _tableBlock(
        '<table><tr><td><p>请于<strong>'
        '<span style="color: rgb(192, 0, 0);">10月8日前</span></strong>'
        '<a href="http://jwzx.zjxu.edu.cn/jwglxt/">教务</a>报名</p></td></tr></table>',
      );
      final cell = table.cells.single;
      final deadline = cell.spans.firstWhere((s) => s.text == '10月8日前');
      expect(deadline.bold, isTrue);
      expect(deadline.emphasis, isTrue);
      final link = cell.spans.firstWhere((s) => s.link != null);
      expect(link.text, '教务');
      expect(link.link, 'http://jwzx.zjxu.edu.cn/jwglxt/');
    });

    test('nested tables fail closed instead of flattening', () {
      final table = _tableBlock(
        '<table><tr><td>外层</td>'
        '<td><table><tr><td>内层</td></tr></table></td></tr></table>',
      );
      expect(table.supported, isFalse);
      expect(table.cells, isEmpty);
    });

    test('malformed or out-of-range spans fail closed', () {
      for (final attr in [
        'rowspan="abc"',
        'rowspan="0"',
        'rowspan="-1"',
        'colspan="1.5"',
        'colspan="9999"',
      ]) {
        final table = _tableBlock(
          '<table><tr><td $attr>a</td><td>b</td></tr></table>',
        );
        expect(table.supported, isFalse, reason: attr);
      }
    });

    test('overlapping spans are rejected', () {
      final table = _tableBlock(
        '<table><tr><td>a</td><td rowspan="2">b</td></tr>'
        '<tr><td colspan="2">c</td></tr></table>',
      );
      expect(table.supported, isFalse);
    });

    test('adjacent tables and surrounding blocks keep source order', () {
      final detail = _parse(
        _page(
          body: '''
<p>前</p>
<table><tr><td>T1</td></tr></table>
<p>中</p>
<table><tr><td>T2</td></tr></table>
<p>后</p>''',
        ),
      );
      expect(detail.blocks.map((b) => b.runtimeType.toString()).toList(), [
        'NoticeParagraph',
        'NoticeTable',
        'NoticeParagraph',
        'NoticeTable',
        'NoticeParagraph',
      ]);
      final tables = detail.blocks.whereType<NoticeTable>().toList();
      expect(tables, hasLength(2));
      expect(tables[0].cells.single.plainText, 'T1');
      expect(tables[1].cells.single.plainText, 'T2');
    });
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

  group('table header fallback', () {
    test('td-only table promotes the first row to header', () {
      final table = _tableBlock(
        '<table><tr><td>序号</td><td>课程</td></tr>'
        '<tr><td>1</td><td>高等数学</td></tr></table>',
      );
      expect(_cellAt(table, 0, 0).header, isTrue);
      expect(_cellAt(table, 0, 1).header, isTrue);
      expect(_cellAt(table, 1, 0).header, isFalse);
    });

    test('tables with explicit th keep only the th cells as header', () {
      final table = _tableBlock(
        '<table><tr><td>说明</td><td>值</td></tr>'
        '<tr><th>学分</th><td>4</td></tr></table>',
      );
      expect(_cellAt(table, 0, 0).header, isFalse);
      expect(_cellAt(table, 1, 0).header, isTrue);
    });

    test('single-row td table is not promoted', () {
      final table = _tableBlock('<table><tr><td>a</td><td>b</td></tr></table>');
      expect(table.hasHeaderCells, isFalse);
    });
  });
}
