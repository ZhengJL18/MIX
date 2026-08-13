/// study_list / study_question 工具：学习模式出题入口。
///
/// 薄工具层，真实逻辑由 [studyQuestionHandler] / [studyListHandler] 委托给
/// 注入方（ChatScreen/bridge，拥有 LLM client + StudyEngine + 画像读取）。
library;

import 'registry.dart';

/// 出题执行器（多阶段管线）：给定科目/知识点，返回题目 JSON。
/// [kpId] 知识点 id；[targetDifficulty] 目标难度档（easy/medium/hard，可选）。
Future<String> Function(
  int kpId, {
  String? targetDifficulty,
})? studyQuestionHandler;

/// 知识点列表执行器：返回可用科目/知识点（带掌握度）。
Future<String> Function()? studyListHandler;

/// 画像更新执行器：把本次作答观察写进学生画像（0_profile.md）。
Future<String> Function(String note)? studyProfileUpdateHandler;

/// 作答记录执行器：把判题结果写入 practice_records（掌握度来源）。
Future<String> Function({
  required int questionId,
  required bool correct,
  String? mainCause,
  String? minorCause,
})? studyRecordHandler;

/// study_record 工具 handler：落库本次作答（对/错）。
Future<String> _handleStudyRecord(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  final handler = studyRecordHandler;
  if (handler == null) {
    return toolError('study_record: 学习引擎未初始化');
  }
  final qid = args['question_id'];
  if (qid is! int && qid is! String) {
    return toolError('study_record: 缺少有效的 question_id');
  }
  final correct = args['correct'] == true;
  try {
    return await handler(
      questionId: qid is String ? int.tryParse(qid) ?? 0 : qid,
      correct: correct,
      mainCause: args['main_cause'] as String?,
      minorCause: args['minor_cause'] as String?,
    );
  } catch (e) {
    return toolError('study_record failed: $e');
  }
}

/// study_profile_update 工具 handler。
Future<String> _handleStudyProfileUpdate(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  final handler = studyProfileUpdateHandler;
  if (handler == null) {
    return toolError('study_profile_update: 学习引擎未初始化');
  }
  final note = (args['student_note'] as String? ?? '').trim();
  if (note.isEmpty) {
    return toolError('study_profile_update: 缺少 student_note');
  }
  try {
    return await handler(note);
  } catch (e) {
    return toolError('study_profile_update failed: $e');
  }
}

/// study_list 工具 handler。
Future<String> _handleStudyList(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  final handler = studyListHandler;
  if (handler == null) {
    return toolError('study_list: 学习引擎未初始化');
  }
  try {
    return await handler();
  } catch (e) {
    return toolError('study_list failed: $e');
  }
}

/// study_question 工具 handler。
Future<String> _handleStudyQuestion(Map<String, dynamic> args,
    [Map<String, dynamic>? kwargs]) async {
  final handler = studyQuestionHandler;
  if (handler == null) {
    return toolError('study_question: 学习引擎未初始化');
  }
  final kpId = args['kp_id'];
  if (kpId is! int && kpId is! String) {
    return toolError('study_question: 缺少有效的 kp_id');
  }
  final targetDifficulty = args['target_difficulty'] as String?;
  try {
    return await handler(
      kpId is String ? int.tryParse(kpId) ?? 0 : kpId,
      targetDifficulty: targetDifficulty,
    );
  } catch (e) {
    return toolError('study_question failed: $e');
  }
}

const Map<String, dynamic> _studyListSchema = {
  'name': 'study_list',
  'description':
      'List available knowledge points with their mastery (recent accuracy). '
      'Use at the start of a study session to pick what to practice and to '
      'announce the round ("这轮 N 题，主练 X，上次正确率 Y%").',
  'parameters': {
    'type': 'object',
    'properties': {},
    'required': [],
  },
};

const Map<String, dynamic> _studyProfileUpdateSchema = {
  'name': 'study_profile_update',
  'description':
      'Update the student profile (0_profile.md) with observations from this '
      'session. Call after explaining a question when you noticed something '
      'worth recording: a misconception, a repeated error pattern, a concept '
      'the student struggled with, or a clear strength. Not gated on wrong '
      'answers — record anything meaningful. The profile feeds future question '
      'targeting.',
  'parameters': {
    'type': 'object',
    'properties': {
      'student_note': {
        'type': 'string',
        'description': 'What the student did / was confused about / improved on',
      },
    },
    'required': ['student_note'],
  },
};

const Map<String, dynamic> _studyRecordSchema = {
  'name': 'study_record',
  'description':
      'Record the student\'s answer to a question into practice history. This '
      'drives mastery calculation (recent accuracy) and future question '
      'targeting. Call IMMEDIATELY after the student answers, BEFORE explaining. '
      'The question_id comes from the study_question result JSON.',
  'parameters': {
    'type': 'object',
    'properties': {
      'question_id': {
        'type': 'integer',
        'description': 'The question_id returned by study_question',
      },
      'correct': {
        'type': 'boolean',
        'description': 'Whether the student answered correctly',
      },
      'main_cause': {
        'type': 'string',
        'description': 'Optional main cause if wrong (e.g. concept confusion)',
      },
    },
    'required': ['question_id', 'correct'],
  },
};

const Map<String, dynamic> _studyQuestionSchema = {
  'name': 'study_question',
  'description':
      'Generate a practice question for the given knowledge point using a '
      'multi-stage refined pipeline (draft → complexity rounds → independent '
      'critique → refine → final check). Returns a JSON question with 4 '
      'options, the correct answer, and an explanation. Targeting is based on '
      'the student profile (0_profile.md).',
  'parameters': {
    'type': 'object',
    'properties': {
      'kp_id': {
        'type': 'integer',
        'description': 'Knowledge point id from study_list',
      },
      'target_difficulty': {
        'type': 'string',
        'enum': ['easy', 'medium', 'hard'],
        'description': 'Optional target difficulty; defaults to auto from mastery',
      },
    },
    'required': ['kp_id'],
  },
};

/// 注册学习工具。
void registerStudyTools() {
  registry.register(
    name: 'study_list',
    toolset: 'study',
    schema: _studyListSchema,
    handler: _handleStudyList,
    isAsync: true,
    emoji: '📚',
  );
  registry.register(
    name: 'study_question',
    toolset: 'study',
    schema: _studyQuestionSchema,
    handler: _handleStudyQuestion,
    isAsync: true,
    emoji: '📝',
    // 题目 JSON 有界。
    maxResultSizeChars: 6000,
  );
  registry.register(
    name: 'study_profile_update',
    toolset: 'study',
    schema: _studyProfileUpdateSchema,
    handler: _handleStudyProfileUpdate,
    isAsync: true,
    emoji: '👤',
  );
  registry.register(
    name: 'study_record',
    toolset: 'study',
    schema: _studyRecordSchema,
    handler: _handleStudyRecord,
    isAsync: true,
    emoji: '✅',
  );
}
