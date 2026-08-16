import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/tools/tool_result_pruner.dart';

void main() {
  group('pruneToolResult', () {
    test('短结果原样返回', () {
      final raw = '{"ok": true}';
      expect(pruneToolResult(raw), raw);
    });

    test('长文本截断 + 标注', () {
      final raw = 'x' * 40000;
      final pruned = pruneToolResult(raw);
      expect(pruned.length, lessThan(35000));
      expect(pruned, contains('[truncated by pruner'));
      expect(pruned, contains('total 40000 chars'));
    });

    test('大 JSON 数组 → 统计 + 前几项', () {
      final raw = jsonEncode([for (var i = 0; i < 10000; i++) {'i': i}]);
      final pruned = pruneToolResult(raw);
      expect(pruned, contains('"_pruned":true'));
      expect(pruned, contains('"total_items":10000'));
      expect(pruned, contains('"shown_count":5'));
      final decoded = jsonDecode(pruned) as Map<String, dynamic>;
      expect(decoded['_pruned'], true);
      expect((decoded['items'] as List).length, 5);
    });

    test('大 JSON 对象 → 键数 + 前几键', () {
      final raw = jsonEncode({
        for (var i = 0; i < 10000; i++) 'key$i': i,
      });
      final pruned = pruneToolResult(raw);
      expect(pruned, contains('"_pruned":true'));
      expect(pruned, contains('"total_keys":10000'));
      expect(pruned, contains('"shown_keys"'));
    });

    test('自定义阈值', () {
      final raw = 'y' * 5000;
      expect(pruneToolResult(raw, maxChars: 1000), contains('[truncated'));
      expect(pruneToolResult(raw, maxChars: 6000), raw);
    });
  });
}
