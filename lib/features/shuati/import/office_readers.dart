/// `.xlsx` / `.docx` 读取（`SafeZipReader` + `xml`，无其它第三方依赖）。
///
/// - xlsx：取第一个工作表（`SheetNames[0]`）的单元格，等价于 SheetJS
///   `sheet_to_json(sheet, {header: 1, blankrows: false})`；
/// - docx：等价于 mammoth `extractRawText`（段落文本 + `\n\n`，制表符保留，
///   软换行 `w:br` **不输出**——mammoth 的纯文本转换同样丢弃它）。
///
/// 不支持 `.xls`（BIFF 二进制）：没有成熟的纯 Dart 解析器，调用方应提示另存为 xlsx。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../domain/js_compat.dart';
import 'import_models.dart';
import 'safe_zip.dart';

/// 单个 XML 部件解压后的上限。
const int kMaxOfficePartBytes = 40 * 1024 * 1024;

/// 单表最多读取的行 / 列数（防止畸形 `r` 属性撑爆内存）。
const int kMaxSheetRows = 200000;
const int kMaxSheetCols = 512;

ShuatiImportFailure _corrupt([String detail = '']) => ShuatiImportFailure(
  ShuatiImportFailureCode.corruptArchive,
  detail.isEmpty ? '文件已损坏或不是有效的 Office 文档' : '文件已损坏或不是有效的 Office 文档（$detail）',
);

SafeZipReader _openZip(Uint8List bytes) {
  try {
    return SafeZipReader.open(bytes);
  } on SafeZipException catch (e) {
    throw _corrupt(e.message);
  }
}

Uint8List _readPart(SafeZipReader zip, String name) {
  try {
    return zip.read(name, maxBytes: kMaxOfficePartBytes);
  } on SafeZipException catch (e) {
    throw _corrupt(e.message);
  }
}

XmlDocument _parseXml(Uint8List bytes) {
  try {
    // XML 部件规范为 UTF-8；坏字节替换而不是抛出。
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    return XmlDocument.parse(text);
  } on XmlException {
    throw _corrupt('XML 解析失败');
  }
}

// ============ xlsx ============

/// 读取 xlsx 第一个工作表，返回按行的单元格文本（空洞为 `null`，行尾空洞不补）。
///
/// 单元格取值对齐 SheetJS 的原始值再经 JS `String(...)`：共享字符串 / 内联字符串 /
/// 公式字符串为文本；数字走 [jsNumberToString]（整数值不带 `.0`）；布尔为
/// `true` / `false`；错误单元格视为空。
List<List<String?>> readXlsxFirstSheetRows(Uint8List bytes) {
  final zip = _openZip(bytes);
  if (!zip.contains('xl/workbook.xml')) throw _corrupt('缺少 workbook.xml');

  final workbook = _parseXml(_readPart(zip, 'xl/workbook.xml'));
  final sheetEl = workbook
      .findAllElements('sheet', namespaceUri: '*')
      .firstOrNull;
  if (sheetEl == null) return const [];

  final sheetPath = _resolveSheetPath(zip, sheetEl);
  if (sheetPath == null || !zip.contains(sheetPath)) {
    throw _corrupt('找不到第一个工作表');
  }

  final shared = zip.contains('xl/sharedStrings.xml')
      ? _readSharedStrings(_parseXml(_readPart(zip, 'xl/sharedStrings.xml')))
      : const <String>[];

  final sheet = _parseXml(_readPart(zip, sheetPath));
  return _readSheetRows(sheet, shared);
}

String? _resolveSheetPath(SafeZipReader zip, XmlElement sheetEl) {
  final rid =
      sheetEl.getAttribute('r:id') ??
      sheetEl.attributes
          .where((a) => a.name.local == 'id')
          .map((a) => a.value)
          .firstOrNull;
  if (rid != null && zip.contains('xl/_rels/workbook.xml.rels')) {
    final rels = _parseXml(_readPart(zip, 'xl/_rels/workbook.xml.rels'));
    for (final rel in rels.findAllElements('Relationship', namespaceUri: '*')) {
      if (rel.getAttribute('Id') == rid) {
        final target = rel.getAttribute('Target');
        if (target == null) break;
        return _normalizeTarget(target);
      }
    }
  }
  const fallback = 'xl/worksheets/sheet1.xml';
  return zip.contains(fallback) ? fallback : null;
}

String _normalizeTarget(String target) {
  if (target.startsWith('/')) return target.substring(1);
  final parts = <String>['xl'];
  for (final seg in target.split('/')) {
    if (seg == '..') {
      if (parts.length > 1) parts.removeLast();
    } else if (seg.isNotEmpty && seg != '.') {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

List<String> _readSharedStrings(XmlDocument doc) {
  final result = <String>[];
  for (final si in doc.findAllElements('si', namespaceUri: '*')) {
    result.add(_collectText(si));
  }
  return result;
}

/// 收集 `<t>` 文本（跳过拼音注音 `<rPh>`）。
String _collectText(XmlElement el) {
  final buf = StringBuffer();
  void walk(XmlElement e) {
    for (final child in e.children) {
      if (child is XmlElement) {
        final n = child.name.local;
        if (n == 'rPh' || n == 'phoneticPr') continue;
        if (n == 't') {
          buf.write(child.innerText);
        } else {
          walk(child);
        }
      }
    }
  }

  walk(el);
  return buf.toString();
}

int _columnIndex(String ref) {
  var col = 0;
  for (final unit in ref.codeUnits) {
    final upper = unit & ~0x20;
    if (upper < 0x41 || upper > 0x5A) break;
    col = col * 26 + (upper - 0x40);
  }
  return col - 1;
}

List<List<String?>> _readSheetRows(XmlDocument sheet, List<String> shared) {
  var originCol = 0;
  final dimension = sheet
      .findAllElements('dimension', namespaceUri: '*')
      .firstOrNull;
  final dimRef = dimension?.getAttribute('ref');
  if (dimRef != null && dimRef.isNotEmpty) {
    final start = _columnIndex(dimRef.split(':').first);
    if (start > 0) originCol = start;
  }

  final rows = <List<String?>>[];
  var rowCounter = 0;
  for (final rowEl in sheet.findAllElements('row', namespaceUri: '*')) {
    rowCounter++;
    if (rowCounter > kMaxSheetRows) {
      throw _corrupt('工作表行数过多');
    }
    final cells = <String?>[];
    var colCounter = originCol - 1;
    for (final c in rowEl.findElements('c', namespaceUri: '*')) {
      final ref = c.getAttribute('r');
      var col = ref != null ? _columnIndex(ref) : colCounter + 1;
      if (col < 0) col = colCounter + 1;
      colCounter = col;
      final index = col - originCol;
      if (index < 0) continue;
      if (index >= kMaxSheetCols) throw _corrupt('工作表列数过多');
      final value = _cellValue(c, shared);
      if (value == null) continue;
      while (cells.length <= index) {
        cells.add(null);
      }
      cells[index] = value;
    }
    if (cells.isNotEmpty) rows.add(cells);
  }
  return rows;
}

String? _cellValue(XmlElement c, List<String> shared) {
  final t = c.getAttribute('t');
  final v = c.findElements('v', namespaceUri: '*').firstOrNull?.innerText;
  switch (t) {
    case 's':
      final i = v == null ? null : int.tryParse(jsTrim(v));
      return i != null && i >= 0 && i < shared.length ? shared[i] : null;
    case 'inlineStr':
      final is_ = c.findElements('is', namespaceUri: '*').firstOrNull;
      return is_ == null ? null : _collectText(is_);
    case 'str':
    case 'd':
      return v;
    case 'b':
      return v == null ? null : (jsTrim(v) == '1' ? 'true' : 'false');
    case 'e':
      return null;
    default:
      if (v == null) return null;
      final number = num.tryParse(jsTrim(v));
      return number == null ? v : jsNumberToString(number);
  }
}

// ============ docx ============

/// mammoth `extractRawText` 等价物：每个段落输出文本后追加 `\n\n`；
/// 表格单元格内的段落同样输出；`w:tab` → `\t`。
String extractDocxRawText(Uint8List bytes) {
  final zip = _openZip(bytes);
  const part = 'word/document.xml';
  if (!zip.contains(part)) throw _corrupt('缺少 document.xml');
  final doc = _parseXml(_readPart(zip, part));
  final body = doc.findAllElements('body', namespaceUri: '*').firstOrNull;
  if (body == null) return '';
  final out = StringBuffer();
  _walkBlocks(body, out);
  return out.toString();
}

void _walkBlocks(XmlElement el, StringBuffer out) {
  for (final child in el.children) {
    if (child is! XmlElement) continue;
    final name = child.name.local;
    if (name == 'Fallback' || name == 'pPr' || name == 'sectPr') continue;
    if (name == 'p') {
      out.write(_paragraphText(child));
      out.write('\n\n');
      // 文本框里的段落单独成段。
      for (final box in child.descendantElements.where(
        (e) => e.name.local == 'txbxContent',
      )) {
        _walkBlocks(box, out);
      }
    } else {
      _walkBlocks(child, out);
    }
  }
}

String _paragraphText(XmlElement p) {
  final buf = StringBuffer();
  void walk(XmlElement e) {
    for (final child in e.children) {
      if (child is! XmlElement) continue;
      switch (child.name.local) {
        case 'pPr':
        case 'rPr':
        case 'txbxContent':
        case 'Fallback':
        case 'instrText':
        case 'delText':
          continue;
        case 't':
          buf.write(child.innerText);
        case 'tab':
          buf.write('\t');
        case 'noBreakHyphen':
          buf.write('‑');
        case 'softHyphen':
          buf.write('­');
        case 'br':
        case 'cr':
          continue;
        default:
          walk(child);
      }
    }
  }

  walk(p);
  return buf.toString();
}
