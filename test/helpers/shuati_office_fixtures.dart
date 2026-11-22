// 测试用合成 xlsx / docx / zip 生成器（只含合成内容，无真实用户数据）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _colName(int index) {
  var n = index + 1;
  final buf = StringBuffer();
  while (n > 0) {
    final rem = (n - 1) % 26;
    buf.write(String.fromCharCode(65 + rem));
    n = (n - 1) ~/ 26;
  }
  return buf.toString().split('').reversed.join();
}

Uint8List zipBytes(Map<String, List<int>> files, {int level = 6}) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, e.value));
  }
  return ZipEncoder().encodeBytes(archive, level: level);
}

/// 生成 xlsx。单元格：`String` → 共享字符串（或内联字符串）；`num` → 数值；
/// `bool` → 布尔；`null` → 空洞（不写 `<c>`）。
/// [secondSheet] 非空时追加第二个工作表（应被忽略）。
Uint8List buildXlsx(
  List<List<Object?>> rows, {
  bool inlineStrings = false,
  List<List<Object?>>? secondSheet,
  int startCol = 0,
  bool withDimension = true,
  String prefix = '',
}) {
  final shared = <String>[];
  int sharedIndex(String s) {
    final i = shared.indexOf(s);
    if (i >= 0) return i;
    shared.add(s);
    return shared.length - 1;
  }

  String sheetXml(List<List<Object?>> data) {
    final buf = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<${prefix}worksheet xmlns${prefix.isEmpty ? '' : ':${prefix.replaceAll(':', '')}'}='
      '"http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    );
    final lastCol = data.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    if (withDimension && data.isNotEmpty) {
      buf.write(
        '<${prefix}dimension ref="${_colName(startCol)}1:${_colName(startCol + lastCol - 1)}${data.length}"/>',
      );
    }
    buf.write('<${prefix}sheetData>');
    for (final (r, row) in data.indexed) {
      buf.write('<${prefix}row r="${r + 1}">');
      for (final (c, cell) in row.indexed) {
        if (cell == null) continue;
        final ref = '${_colName(startCol + c)}${r + 1}';
        if (cell is String) {
          if (inlineStrings) {
            buf.write(
              '<${prefix}c r="$ref" t="inlineStr"><${prefix}is><${prefix}t>${_esc(cell)}</${prefix}t></${prefix}is></${prefix}c>',
            );
          } else {
            buf.write(
              '<${prefix}c r="$ref" t="s"><${prefix}v>${sharedIndex(cell)}</${prefix}v></${prefix}c>',
            );
          }
        } else if (cell is bool) {
          buf.write(
            '<${prefix}c r="$ref" t="b"><${prefix}v>${cell ? 1 : 0}</${prefix}v></${prefix}c>',
          );
        } else if (cell is num) {
          buf.write(
            '<${prefix}c r="$ref"><${prefix}v>$cell</${prefix}v></${prefix}c>',
          );
        }
      }
      buf.write('</${prefix}row>');
    }
    buf.write('</${prefix}sheetData></${prefix}worksheet>');
    return buf.toString();
  }

  final sheet1 = sheetXml(rows);
  final sheet2 = secondSheet == null ? null : sheetXml(secondSheet);
  final sst = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${shared.length}" uniqueCount="${shared.length}">',
  );
  for (final s in shared) {
    sst.write('<si><t xml:space="preserve">${_esc(s)}</t></si>');
  }
  sst.write('</sst>');

  final sheets = StringBuffer('<sheet name="Sheet1" sheetId="1" r:id="rId1"/>');
  final rels = StringBuffer(
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>',
  );
  if (sheet2 != null) {
    sheets.write('<sheet name="Sheet2" sheetId="2" r:id="rId2"/>');
    rels.write(
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>',
    );
  }
  rels.write(
    '<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>',
  );

  return zipBytes({
    '[Content_Types].xml': utf8.encode(
      '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
    ),
    'xl/workbook.xml': utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>$sheets</sheets></workbook>',
    ),
    'xl/_rels/workbook.xml.rels': utf8.encode(
      '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>',
    ),
    'xl/sharedStrings.xml': utf8.encode(sst.toString()),
    'xl/worksheets/sheet1.xml': utf8.encode(sheet1),
    if (sheet2 != null) 'xl/worksheets/sheet2.xml': utf8.encode(sheet2),
  });
}

/// 生成 docx：每个字符串一个段落；`\t` 变成 `<w:tab/>`；
/// [tableRows] 非空时在段落后追加一个表格（单元格内是段落）。
Uint8List buildDocx(
  List<String> paragraphs, {
  List<List<String>> tableRows = const [],
  bool withSoftBreak = false,
}) {
  String run(String text) {
    final parts = text.split('\t');
    final buf = StringBuffer('<w:r>');
    for (final (i, part) in parts.indexed) {
      if (i > 0) {
        buf.write('<w:tab/>');
      }
      if (part.isNotEmpty) {
        buf.write('<w:t xml:space="preserve">${_esc(part)}</w:t>');
      }
    }
    buf.write('</w:r>');
    return buf.toString();
  }

  final body = StringBuffer();
  for (final p in paragraphs) {
    body.write(
      '<w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr>${run(p)}</w:p>',
    );
  }
  if (withSoftBreak) {
    body.write('<w:p><w:r><w:t>软换行前</w:t><w:br/><w:t>软换行后</w:t></w:r></w:p>');
  }
  if (tableRows.isNotEmpty) {
    body.write('<w:tbl>');
    for (final row in tableRows) {
      body.write('<w:tr>');
      for (final cell in row) {
        body.write('<w:tc><w:p>${run(cell)}</w:p></w:tc>');
      }
      body.write('</w:tr>');
    }
    body.write('</w:tbl>');
  }

  return zipBytes({
    '[Content_Types].xml': utf8.encode(
      '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
    ),
    'word/document.xml': utf8.encode(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body<w:sectPr/></w:body></w:document>',
    ),
  });
}
