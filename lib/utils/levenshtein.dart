/// Levenshtein 编辑距离（typo 容错用，v4 §12 搜索引擎调研：词长分级容错）。
library;

/// 计算两串的编辑距离（纯 Dart，O(mn) 滚动数组）。
int levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final m = a.length;
  final n = b.length;
  var prev = List<int>.generate(n + 1, (i) => i);
  var curr = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    curr[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = [
        prev[j] + 1, // 删除
        curr[j - 1] + 1, // 插入
        prev[j - 1] + cost, // 替换
      ].reduce((x, y) => x < y ? x : y);
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[n];
}

/// typo 容错阈值（词长分级，搜索引擎调研：1-4 字 0 错 / 5-8 字 1 错 /
/// ≥9 字 2 错；中文单字太敏感，2 字起给 1 错余地）。
///
/// 返回该词允许的最大编辑距离。
int typoTolerance(int wordLength) {
  if (wordLength <= 2) return 0; // 太短，容忍 1 错会误配。
  if (wordLength <= 4) return 1;
  if (wordLength <= 8) return 1;
  return 2;
}
