/// study_status 工具（v4 设计稿 §6.3 + P4 学习描绘）。
///
/// 列出知识点学习状态（mastered/learning/weak/review_due/unknown，证据驱动）
/// 与复习推荐——记忆系统的自然副产品描绘学习状态（"副业干过主业"），
/// 不依赖额外建模：correct/wrong 由判题写入证据流，检索痕迹提供可提取性。
library;

import 'dart:convert';

import '../services/memory_learning.dart';
import 'registry.dart';

/// main.dart 注入的学习状态推导器。
MemoryLearning? memoryLearning;

/// study_status 工具 handler。
Future<String> studyStatusTool({
  String? action,
  int? limit,
  MemoryLearning? learning,
}) async {
  if (learning == null) {
    return toolError('study_status: 学习状态引擎未初始化');
  }
  try {
    if (action == 'review' || action == 'review_due') {
      final due = await learning.reviewDue(limit: limit ?? 10);
      return jsonEncode({
        'mode': 'review_due',
        'count': due.length,
        'items': [
          for (final s in due)
            {
              'kp_id': s.kpId,
              'name': s.name,
              'subject': s.subjectName,
              'status': s.status,
              'mastery': s.mastery,
              'retrievability': s.retrievability,
              'age_seconds': s.ageSeconds,
            },
        ],
      });
    }
    final states = await learning.deriveStates();
    return jsonEncode({
      'mode': 'all',
      'count': states.length,
      'items': [
        for (final s in states)
          {
            'kp_id': s.kpId,
            'name': s.name,
            'subject': s.subjectName,
            'status': s.status,
            'mastery': s.mastery,
            'retrievability': s.retrievability,
            'evidence_count': s.evidenceCount,
          },
      ],
    });
  } catch (e) {
    return toolError('study_status failed: $e');
  }
}

/// study_status 工具 schema。
const Map<String, dynamic> studyStatusSchema = {
  'name': 'study_status',
  'description':
      'Learning state derived from memory evidence (no extra modeling): '
      'mastered/learning/weak/review_due per knowledge point. '
      'action=review_due returns review recommendations (weak first). '
      'Use to give the user learning advice / pick next review targets.',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['all', 'review_due'],
        'description': 'all (default) or review_due (review recommendations).',
      },
      'limit': {
        'type': 'integer',
        'description': 'Max items (default 10).',
      },
    },
  },
};

/// 注册 study_status 工具。
void registerStudyStatusTool({MemoryLearning? learning}) {
  memoryLearning = learning ?? memoryLearning;
  registry.register(
    name: 'study_status',
    toolset: 'study',
    schema: studyStatusSchema,
    handler: (args, [kwargs]) {
      return studyStatusTool(
        action: args['action'] as String?,
        limit: args['limit'] as int?,
        learning: memoryLearning,
      );
    },
    checkFn: () => memoryLearning != null,
    isAsync: true,
    emoji: '📊',
  );
}
