import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/services/services.dart';
import 'package:mix/tools/cron_tools.dart';
import 'package:mix/tools/model_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// cron 调度回归测试。
///
/// 核心防回归点：任务在触发执行（fire）期间被删除时，绝不复活
/// （曾因 fire 后无条件 _saveJob(upsert) 导致「删了又出现」）。
/// 以及一次性 ISO 任务触发后自动删除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object> seededJobs(List<Map<String, dynamic>> jobs) =>
      {'cron_jobs': jsonEncode(jobs)};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    registerCronTools(); // 幂等：同 toolset 重复注册允许覆盖。
    Services.instance.cronFireHandler = null;
  });

  tearDown(() {
    stopCronScheduler();
    Services.instance.cronFireHandler = null;
  });

  Future<List<dynamic>> storedJobs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cron_jobs');
    if (raw == null || raw.isEmpty) return [];
    return jsonDecode(raw) as List;
  }

  Map<String, dynamic> jobJson(String id, String schedule,
          {String task = 'task', bool enabled = true}) =>
      {
        'id': id,
        'schedule': schedule,
        'task': task,
        'enabled': enabled,
        'last_run': null,
      };

  test('触发执行期间被删除的任务不复活（核心回归）', () async {
    SharedPreferences.setMockInitialValues(seededJobs([
      jobJson('cron_resurrect', '1s'),
    ]));
    // 模拟 agent 在 fire 期间执行任务后调用 cron_delete。
    Services.instance.cronFireHandler = (job) async {
      await handleFunctionCall('cron_delete', {'id': job.id});
    };

    await startCronScheduler();
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    final jobs = await storedJobs();
    expect(
      jobs.where((j) => j['id'] == 'cron_resurrect'),
      isEmpty,
      reason: '删除发生在 fire 期间，任务绝不能被 _saveJob 重新写回',
    );
  });

  test('一次性 ISO 任务触发后自动删除', () async {
    final iso = DateTime.now()
        .add(const Duration(seconds: 1))
        .toIso8601String();
    SharedPreferences.setMockInitialValues(seededJobs([
      jobJson('cron_oneshot', iso),
    ]));
    var fired = false;
    Services.instance.cronFireHandler = (job) async {
      fired = true;
    };

    await startCronScheduler();
    await Future<void>.delayed(const Duration(milliseconds: 2600));

    expect(fired, isTrue);
    final jobs = await storedJobs();
    expect(
      jobs.where((j) => j['id'] == 'cron_oneshot'),
      isEmpty,
      reason: '一次性任务触发后应自动删除',
    );
  });

  test('周期任务触发后保留并记录 last_run', () async {
    SharedPreferences.setMockInitialValues(seededJobs([
      jobJson('cron_recurring', '1s'),
    ]));
    var fired = false;
    Services.instance.cronFireHandler = (job) async {
      fired = true;
    };

    await startCronScheduler();
    await Future<void>.delayed(const Duration(milliseconds: 1600));

    expect(fired, isTrue);
    final jobs = await storedJobs();
    final job = jobs.where((j) => j['id'] == 'cron_recurring').toList();
    expect(job, hasLength(1));
    expect(job.first['last_run'], isNotNull);
  });

  test('cron_delete 正常删除存储中的任务', () async {
    SharedPreferences.setMockInitialValues(seededJobs([
      jobJson('cron_del', '30m'),
    ]));
    final result =
        await handleFunctionCall('cron_delete', {'id': 'cron_del'});
    expect(result, contains('deleted'));
    final jobs = await storedJobs();
    expect(jobs, isEmpty);
  });
}
