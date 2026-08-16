import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/local_doc_parser.dart';

/// 构造最小 OOXML zip（docx/pptx/xlsx 共用容器）。
Uint8List makeZip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.string(e.key, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  group('docxToMarkdown', () {
    test('最小 docx → 文本', () async {
      final bytes = makeZip({
        '[Content_Types].xml': '<?xml version="1.0"?><Types/>',
        '_rels/.rels': '<Relationships/>',
        'word/document.xml':
            '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            '<w:body><w:p><w:r><w:t>你好世界</w:t></w:r></w:p>'
            '<w:p><w:r><w:t>第二段</w:t></w:r></w:p>'
            '</w:body></w:document>',
      });
      final md = await docxToMarkdown(bytes);
      expect(md, isNotNull);
      expect(md, contains('你好世界'));
      expect(md, contains('第二段'));
    });

    test('非法字节 → null', () async {
      expect(await docxToMarkdown(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('pptxToMarkdown', () {
    test('最小 pptx → 每页大纲', () {
      final bytes = makeZip({
        '[Content_Types].xml': '<Types/>',
        'ppt/presentation.xml': '<p:presentation/>',
        'ppt/slides/slide1.xml':
            '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
            '<a:t>第一页标题</a:t><a:t>要点一</a:t><a:t>要点二</a:t></p:sld>',
        'ppt/slides/slide2.xml':
            '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
            '<a:t>第二页标题</a:t></p:sld>',
      });
      final md = pptxToMarkdown(bytes);
      expect(md, isNotNull);
      expect(md, contains('## 第 1 页'));
      expect(md, contains('第一页标题'));
      expect(md, contains('- 要点一'));
      expect(md, contains('## 第 2 页'));
      expect(md, contains('第二页标题'));
    });

    test('非 pptx zip → null', () {
      final bytes = makeZip({'foo.txt': 'hello'});
      expect(pptxToMarkdown(bytes), isNull);
    });
  });

  group('xlsxToMarkdown', () {
    test('最小 xlsx → Markdown 表格', () {
      final bytes = makeZip({
        '[Content_Types].xml': '<Types/>',
        'xl/sharedStrings.xml':
            '<sst><si><t>姓名</t></si><si><t>年龄</t></si><si><t>张三</t></si><si><t>25</t></si></sst>',
        'xl/worksheets/sheet1.xml':
            '<worksheet><sheetData>'
            '<row r="1"><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row>'
            '<row r="2"><c t="s"><v>2</v></c><c><v>25</v></c></row>'
            '</sheetData></worksheet>',
      });
      final md = xlsxToMarkdown(bytes);
      expect(md, isNotNull);
      expect(md, contains('| 姓名 | 年龄 |'));
      expect(md, contains('| --- | --- |'));
      expect(md, contains('| 张三 | 25 |'));
    });

    test('非 xlsx zip → null', () {
      final bytes = makeZip({'a.txt': 'x'});
      expect(xlsxToMarkdown(bytes), isNull);
    });
  });

  group('parseOfficeToMarkdown', () {
    test('路由到对应解析器', () async {
      final xlsx = makeZip({
        'xl/sharedStrings.xml': '<sst><si><t>A</t></si></sst>',
        'xl/worksheets/sheet1.xml':
            '<worksheet><sheetData><row r="1"><c t="s"><v>0</v></c></row>'
            '</sheetData></worksheet>',
      });
      final md = await parseOfficeToMarkdown(xlsx);
      expect(md, contains('| A |'));
      // 非 OOXML → null。
      final plain = makeZip({'x.txt': 'plain'});
      expect(await parseOfficeToMarkdown(plain), isNull);
    });
  });
}
