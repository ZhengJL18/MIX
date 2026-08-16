import 'package:flutter_test/flutter_test.dart';
import 'package:mix/utils/levenshtein.dart';

void main() {
  group('levenshteinDistance', () {
    test('相同字符串 0', () {
      expect(levenshteinDistance('行列式', '行列式'), 0);
      expect(levenshteinDistance('', ''), 0);
    });

    test('单字符编辑', () {
      expect(levenshteinDistance('行列式', '行列势'), 1); // 替换。
      expect(levenshteinDistance('矩阵', '矩阵论'), 1); // 插入。
      expect(levenshteinDistance('矩阵', '矩'), 1); // 删除。
    });

    test('经典用例', () {
      expect(levenshteinDistance('kitten', 'sitting'), 3);
      expect(levenshteinDistance('flaw', 'lawn'), 2);
    });

    test('空串', () {
      expect(levenshteinDistance('', 'abc'), 3);
      expect(levenshteinDistance('abc', ''), 3);
    });
  });

  group('typoTolerance', () {
    test('词长分级', () {
      expect(typoTolerance(1), 0);
      expect(typoTolerance(2), 0); // 太短不给错（防误配）。
      expect(typoTolerance(3), 1);
      expect(typoTolerance(4), 1);
      expect(typoTolerance(8), 1);
      expect(typoTolerance(9), 2);
      expect(typoTolerance(20), 2);
    });
  });
}
