import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/db/session_db.dart';
import 'package:mix/services/debug_server.dart';
import 'package:mix/services/goal_store.dart';
import 'package:mix/services/memory_db.dart';
import 'package:mix/services/memory_learning.dart';
import 'package:mix/services/memory_tagger.dart';
import 'package:mix/services/notes_sync.dart';
import 'package:mix/services/study_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late MemoryDB db;
  late StudyEngine engine;
  late DebugServer server;

  setUpAll(() {
    sqfliteFfiInit();
    sessionDbFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mix_debug_test_');
    db = MemoryDB(dbPath: '${tmp.path}/memory.db');
    await db.init();
    engine = StudyEngine(dbPath: '${tmp.path}/study.db');
    await engine.init();
    final tagger = MemoryTagger();
    final learning = MemoryLearning(db: db, studyEngine: engine);
    final goals = GoalStore(db);
    server = DebugServer(
      memoryDb: db,
      studyEngine: engine,
      goalStore: goals,
      learning: learning,
      tagger: tagger,
      notesSync: NotesSyncService(db: db, notesRoot: '${tmp.path}/notes'),
    );
  });

  tearDown(() async {
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, dynamic>> cmd(String line) async =>
      jsonDecode(await server.handleCommand(line)) as Map<String, dynamic>;

  group('DebugServer.handleCommand', () {
    test('ping', () async {
      final r = await cmd('{"cmd":"ping"}');
      expect(r['ok'], true);
      expect(r['app'], 'MIX');
      expect(r.containsKey('fts_available'), true);
    });

    test('unknown cmd', () async {
      final r = await cmd('{"cmd":"nope"}');
      expect(r['error'], isNotNull);
    });

    test('bad JSON', () async {
      final r = await cmd('not json');
      expect(r['error'], isNotNull);
    });

    test('memory_search 检索', () async {
      await db.upsertDoc(
          path: 'm.md', title: '矩阵笔记', content: '矩阵乘法与行列式');
      final r = await cmd('{"cmd":"memory_search","args":{"query":"矩阵"}}');
      expect(r['count'], 1);
      expect((r['items'] as List).first['title'], '矩阵笔记');
      expect(r.containsKey('fts_available'), true);
    });

    test('memory_docs 列表 + kind 过滤', () async {
      await db.upsertDoc(path: 'a.md', title: 'A', content: 'x', kind: 'note');
      await db.upsertDoc(path: 'b.md', title: 'B', content: 'x', kind: 'memory');
      final all = await cmd('{"cmd":"memory_docs"}');
      expect(all['count'], 2);
      final notes = await cmd(
          '{"cmd":"memory_docs","args":{"kind":"note"}}');
      expect(notes['count'], 1);
      expect((notes['docs'] as List).first['kind'], 'note');
    });

    test('memory_tags / memory_links', () async {
      final a = await db.upsertDoc(path: 'a.md', title: 'A', content: '行列式');
      final b = await db.upsertDoc(path: 'b.md', title: 'B', content: '行列式');
      await db.addTag(a, '行列式');
      await db.addLink(a, b, kind: 'tag');
      final tags = await cmd('{"cmd":"memory_tags","args":{"doc_id":$a}}');
      expect(tags['tags'], contains('行列式'));
      final links = await cmd('{"cmd":"memory_links","args":{"doc_id":$a}}');
      expect(links['count'], 1);
    });

    test('goal_list', () async {
      await server.handleCommand('{"cmd":"goal_list"}');
      final goals = GoalStore(db);
      await goals.createGoal('掌握线性代数');
      final r = await cmd('{"cmd":"goal_list"}');
      expect(r['count'], 1);
      expect((r['goals'] as List).first['objective'], '掌握线性代数');
    });

    test('study_status', () async {
      final sid = await engine.ensureSubject('科目');
      final kpId = await engine.ensureKnowledgePoint(sid, '知识点A');
      await db.addEvidence('knowledge', kpId, 'correct');
      final r = await cmd('{"cmd":"study_status"}');
      expect(r['states'], isNotNull);
      final states = r['states'] as List;
      expect(states, isNotEmpty);
    });

    test('evidence 查询', () async {
      final docId = await db.upsertDoc(path: 'e.md', title: 'E', content: 'x');
      await db.addEvidence('doc', docId, 'hit');
      final r = await cmd(
          '{"cmd":"evidence","args":{"obj_type":"doc","obj_id":$docId}}');
      expect(r['count'], 1);
      expect((r['evidence'] as List).first['evidence'], 'hit');
    });

    test('notes_sync', () async {
      final notes = Directory('${tmp.path}/notes');
      await notes.create(recursive: true);
      await File('${notes.path}/笔记.md').writeAsString('内容');
      final r = await cmd('{"cmd":"notes_sync"}');
      expect(r['updated'], 1);
      final docs = await cmd('{"cmd":"memory_docs","args":{"kind":"note"}}');
      expect(docs['count'], 1);
    });

    test('segment 无分词器时返回空词列表（不崩）', () async {
      final r = await cmd('{"cmd":"segment","args":{"text":"行列式"}}');
      expect(r.containsKey('words'), true);
    });
  });
}
