/// cron 定时任务：创建/列出/删除定时任务，App 存活时按 schedule 触发。
///
/// schedule 支持：'30m'（每30分钟）、'every 2h'、'0 9 * * *'（cron 5段，本地时区）、
/// ISO 一次性。触发时通过 [cronFireHandler] 交付到当前对话。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/services.dart';
import 'registry.dart';

const String _jobsKey = 'cron_jobs';

/// cron job。
class CronJob {
  final String id;
  final String schedule;
  final String task;
  final bool enabled;
  final String? lastRun;

  const CronJob({
    required this.id,
    required this.schedule,
    required this.task,
    this.enabled = true,
    this.lastRun,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'schedule': schedule,
        'task': task,
        'enabled': enabled,
        'last_run': lastRun,
      };

  factory CronJob.fromJson(Map<String, dynamic> j) => CronJob(
        id: j['id'] as String? ?? '',
        schedule: j['schedule'] as String? ?? '',
        task: j['task'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
        lastRun: j['last_run'] as String?,
      );
}

/// 触发回调：UI 注册，把 cron 任务交给 agent 执行并展示结果。

/// 定时器集合（id → timer）。
final Map<String, Timer> _timers = {};
bool _schedulerStarted = false;

/// 解析 schedule 为下一次触发延迟（毫秒）。返回 null 表示不支持。
Duration? _parseSchedule(String schedule, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final raw = schedule.trim();
  final s = raw.toLowerCase();

  // 纯数字 + 单位：30m / 2h / 45s
  final intervalRe = RegExp(r'^(?:every\s+)?(\d+)\s*(s|m|h|d)$');
  final im = intervalRe.firstMatch(s);
  if (im != null) {
    final v = int.parse(im.group(1)!);
    return switch (im.group(2)) {
      's' => Duration(seconds: v),
      'm' => Duration(minutes: v),
      'h' => Duration(hours: v),
      'd' => Duration(days: v),
      _ => null,
    };
  }

  // cron 5 段：min hour dom mon dow
  final cronRe = RegExp(r'^(\d+|\*)\s+(\d+|\*)\s+(\d+|\*)\s+(\d+|\*)\s+(\d+|\*)$');
  final cm = cronRe.firstMatch(s);
  if (cm != null) {
    final min = _parseField(cm.group(1)!, 0, 59, n.minute);
    final hour = _parseField(cm.group(2)!, 0, 23, n.hour);
    // 计算下一次 cron 触发。简化：仅支持分/时段的简单调度，逐分钟推进。
    var target = DateTime(n.year, n.month, n.day, hour, min);
    if (target.isBefore(n)) {
      target = target.add(const Duration(hours: 24));
    }
    var delta = target.difference(n);
    if (delta.isNegative) delta = Duration.zero;
    return delta;
  }

  // ISO 一次性时间戳：'2026-08-07T09:00' / '2026-08-07 09:00:00' / 带时区偏移。
  final iso = DateTime.tryParse(raw);
  if (iso != null) {
    var delta = iso.difference(n);
    if (delta.isNegative) delta = Duration.zero; // 已过期 → 立即触发。
    return delta;
  }

  return null;
}

/// 是否为一次性任务（ISO 时间戳调度）。一次性任务触发后自动删除。
bool _isOneShot(String schedule) => DateTime.tryParse(schedule.trim()) != null;

int _parseField(String f, int min, int max, int current) {
  if (f == '*') return current;
  final v = int.tryParse(f);
  if (v == null) return current;
  return v.clamp(min, max);
}

/// 启动调度器：加载已存 job 并建立定时器。
Future<void> startCronScheduler() async {
  if (_schedulerStarted) return;
  _schedulerStarted = true;
  final jobs = await _loadJobs();
  for (final j in jobs.where((j) => j.enabled)) {
    _scheduleJob(j);
  }
}

/// 停止所有定时器（App 退出时）。
void stopCronScheduler() {
  for (final t in _timers.values) {
    t.cancel();
  }
  _timers.clear();
  _schedulerStarted = false;
}

void _scheduleJob(CronJob job) {
  _timers[job.id]?.cancel();
  final delay = _parseSchedule(job.schedule);
  if (delay == null) return;
  _timers[job.id] = Timer(delay, () async {
    // 已触发：从活动集合移除（此后 _deleteJob 的 cancel 只作用于真正的 pending timer）。
    _timers.remove(job.id);
    try {
      final fire = Services.instance.cronFireHandler;
      if (fire != null) {
        await fire(job);
      }
    } catch (_) {}
    // 触发期间任务可能已被 agent/用户删除或禁用。以存储中的最新状态为准，
    // 被删的任务绝不能被 _saveJob（upsert）重新写回——那是「删了又出现」的根源。
    final current = await _findJob(job.id);
    if (current == null) return; // 已删除 → 不复活、不重排。
    final updated = CronJob(
      id: current.id,
      schedule: current.schedule,
      task: current.task,
      enabled: current.enabled,
      lastRun: DateTime.now().toIso8601String(),
    );
    // 一次性任务（ISO 时间戳）触发后自动删除；周期任务记录 last_run 并继续调度。
    if (_isOneShot(updated.schedule)) {
      await _deleteJob(updated.id);
      return;
    }
    if (updated.enabled) {
      await _saveJob(updated);
      _scheduleJob(updated);
    }
  });
}

Future<CronJob?> _findJob(String id) async {
  final jobs = await _loadJobs();
  for (final j in jobs) {
    if (j.id == id) return j;
  }
  return null;
}

Future<List<CronJob>> _loadJobs() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_jobsKey);
  if (raw == null || raw.isEmpty) return [];
  try {
    final list = jsonDecode(raw) as List;
    return [
      for (final e in list)
        if (e is Map<String, dynamic>) CronJob.fromJson(e),
    ];
  } catch (_) {
    return [];
  }
}

Future<void> _saveJob(CronJob job) async {
  final jobs = await _loadJobs();
  final idx = jobs.indexWhere((j) => j.id == job.id);
  if (idx >= 0) {
    jobs[idx] = job;
  } else {
    jobs.add(job);
  }
  await _persist(jobs);
}

Future<void> _deleteJob(String id) async {
  final jobs = await _loadJobs();
  jobs.removeWhere((j) => j.id == id);
  await _persist(jobs);
  _timers[id]?.cancel();
  _timers.remove(id);
}

Future<void> _persist(List<CronJob> jobs) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_jobsKey, jsonEncode([for (final j in jobs) j.toJson()]));
}

String _newId() => 'cron_${DateTime.now().millisecondsSinceEpoch}';

// ============================================================================
// 工具 handlers
// ============================================================================

Future<String> _handleCronCreate(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final schedule = args['schedule'] as String? ?? '';
  final task = args['task'] as String? ?? '';
  if (schedule.isEmpty || task.isEmpty) {
    return toolError('cron_create: schedule and task are required');
  }
  if (_parseSchedule(schedule) == null) {
    return toolError("cron_create: unsupported schedule '$schedule'. "
        "Use '30m', 'every 2h', '0 9 * * *', or ISO timestamp.");
  }
  final job = CronJob(id: _newId(), schedule: schedule, task: task);
  await _saveJob(job);
  _scheduleJob(job);
  final when = _isOneShot(schedule) ? 'one-shot at' : 'every';
  return 'Cron job created (${job.id}): $when "$schedule" → $task';
}

Future<String> _handleCronList([Map<String, dynamic>? args, Map<String, dynamic>? kwargs]) async {
  final jobs = await _loadJobs();
  if (jobs.isEmpty) {
    return 'No cron jobs.';
  }
  final lines = <String>[];
  for (final j in jobs) {
    lines.add('${j.enabled ? '●' : '○'} ${j.id} | ${j.schedule} | ${j.task}'
        '${j.lastRun != null ? ' | last: ${j.lastRun!.substring(0, 16)}' : ''}');
  }
  return lines.join('\n');
}

Future<String> _handleCronDelete(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final id = args['id'] as String? ?? '';
  if (id.isEmpty) {
    return toolError('cron_delete: id is required');
  }
  await _deleteJob(id);
  return 'Cron job $id deleted';
}

const Map<String, dynamic> _cronCreateSchema = {
  'name': 'cron_create',
  'description':
      'Create a recurring or one-shot task. schedule formats: "30m" (every 30 min), '
      '"every 2h", "0 9 * * *" (cron 5-field, local time), or ISO timestamp '
      '(one-shot, auto-deleted after it fires). '
      'The task runs while the app is open and the result is delivered to chat.',
  'parameters': {
    'type': 'object',
    'properties': {
      'schedule': {'type': 'string', 'description': 'Schedule (see description)'},
      'task': {'type': 'string', 'description': 'What to do each time it fires'},
    },
    'required': ['schedule', 'task'],
  },
};

const Map<String, dynamic> _cronListSchema = {
  'name': 'cron_list',
  'description': 'List all cron jobs with schedule and status.',
  'parameters': {'type': 'object', 'properties': {}, 'required': []},
};

const Map<String, dynamic> _cronDeleteSchema = {
  'name': 'cron_delete',
  'description': 'Delete a cron job by id.',
  'parameters': {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'Cron job id'},
    },
    'required': ['id'],
  },
};

void registerCronTools() {
  registry.register(
    name: 'cron_create',
    toolset: 'cron',
    schema: _cronCreateSchema,
    handler: _handleCronCreate,
    isAsync: true,
    emoji: '⏰',
  );
  registry.register(
    name: 'cron_list',
    toolset: 'cron',
    schema: _cronListSchema,
    handler: _handleCronList,
    isAsync: true,
    emoji: '⏰',
  );
  registry.register(
    name: 'cron_delete',
    toolset: 'cron',
    schema: _cronDeleteSchema,
    handler: _handleCronDelete,
    isAsync: true,
    emoji: '⏰',
  );
}
