import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/chinese_segmenter.dart';
import 'package:mix/services/memory_tagger.dart';

void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tmp = Directory.systemTemp.createTempSync('mix_tagger_test_');
  final tagger = MemoryTagger();
  // 初始化分词器（assets/dict.dgz → 私有目录 → dart_jieba）与 idf 表
  // （项目 assets 直接 File 读，测试环境 cwd=项目根）。
  final segReady = await initChineseSegmenter(tmp.path);
  if (File('assets/jieba_idf.txt').existsSync()) {
    await tagger.loadIdfFromFile('assets/jieba_idf.txt');
  }
  // 分词器不可用（CI 环境 assets 异常）时跳过全部测试，不假失败。
  final ready = segReady;

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('extractHotwords', () {
    test('正常文档提取 top-k 热词', () {
      const text =
          '行列式的性质包括转置不变性、倍乘性质。行列式的计算与矩阵乘法密切相关。'
          '矩阵的逆与行列式的关系是线性代数的重要内容。';
      final hot = tagger.extractHotwords(text, topK: 5);
      expect(hot, isNotEmpty);
      final words = hot.map((h) => h.word).toList();
      expect(words, contains('行列式'));
      expect(words, contains('矩阵'));
    }, skip: !ready);

    test('连续重复轰炸不能刷高权重（防污染）', () {
      final bombed = tagger.extractHotwords('矩阵' * 500, topK: 3);
      final normal = tagger.extractHotwords(
        '矩阵乘法与行列式计算是线性代数的重要内容，考试经常考察矩阵的逆。',
        topK: 3,
      );
      // 轰炸文档词数少，但重复被折叠 → 不会出现荒谬高分。
      expect(bombed.length, lessThanOrEqualTo(1));
      // 正常文档的 top1 词分应显著高于轰炸的（若都有矩阵）。
      if (bombed.isNotEmpty && normal.isNotEmpty) {
        expect(normal.first.score, greaterThan(bombed.first.score));
      }
    }, skip: !ready);

    test('虚词/单字符被黑名单与长度过滤', () {
      final hot = tagger.extractHotwords(
        '的的了了是是在在我我的，。！？',
        topK: 5,
      );
      expect(hot, isEmpty);
    }, skip: !ready);

    test('无 idf 表时纯 TF + log 饱和仍可提取', () {
      final t2 = MemoryTagger(); // 不加载 idf。
      final hot = t2.extractHotwords(
        '贝叶斯公式与条件概率，贝叶斯公式是概率论的核心，条件概率是基础。',
        topK: 3,
      );
      expect(hot, isNotEmpty);
    }, skip: !ready);

    test('score 降序', () {
      final hot = tagger.extractHotwords('a词 a词 b词 b词 b词 c词', topK: 3);
      for (var i = 1; i < hot.length; i++) {
        expect(hot[i - 1].score, greaterThanOrEqualTo(hot[i].score));
      }
    }, skip: !ready);
  });
}
