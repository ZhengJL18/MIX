import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix/skills/skill_discovery.dart';
import 'package:mix/skills/skill_parser.dart';
import 'package:mix/services/services.dart';
import 'package:mix/tools/skills_tool.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late SkillDiscovery discovery;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jailer_skill_test_');
    final skillsRoot = p.join(tmp.path, 'skills');
    Directory(p.join(skillsRoot, 'coding')).createSync(recursive: true);
    discovery = SkillDiscovery(skillsRoot: skillsRoot);
    Services.instance.skillDiscovery = discovery;
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 写一个 SKILL.md。
  void writeSkill(String category, String name, String desc) {
    final dir = p.join(tmp.path, 'skills', category, name);
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, 'SKILL.md')).writeAsStringSync(
      '---\nname: $name\ndescription: $desc\n---\n\n# $name\n\nBody content.\n',
    );
  }

  group('parseFrontmatter', () {
    test('解析 frontmatter + 正文', () {
      final (fm, body) = parseFrontmatter(
        '---\nname: test-skill\ndescription: Test skill\n---\n\n# Body\n',
      );
      expect(fm['name'], 'test-skill');
      expect(fm['description'], 'Test skill');
      expect(body, contains('# Body'));
    });

    test('无 frontmatter 返回空 dict + 原正文', () {
      final (fm, body) = parseFrontmatter('# Just body\n');
      expect(fm, isEmpty);
      expect(body, contains('# Just body'));
    });

    test('BOM 前导剥离', () {
      final (fm, _) = parseFrontmatter('﻿---\nname: x\ndescription: y\n---\n');
      expect(fm['name'], 'x');
    });

    test('畸形 YAML fallback 简单解析', () {
      final (fm, _) = parseFrontmatter('---\nname: x\ndescription: y: with colon\n---\n');
      expect(fm.containsKey('name'), isTrue);
    });
  });

  group('isValidSkillName / validateFrontmatter', () {
    test('合法名', () {
      expect(isValidSkillName('my-skill'), isTrue);
      expect(isValidSkillName('skill2.0'), isTrue);
      expect(isValidSkillName('Bad Name'), isFalse);
      expect(isValidSkillName('UPPER'), isFalse);
    });

    test('description ≤60 校验（新建）', () {
      final longDesc = List.filled(80, 'a').join();
      final err = validateFrontmatter(
        '---\nname: x\ndescription: $longDesc\n---\n',
        {'name': 'x', 'description': longDesc},
        requireShortDesc: true,
      );
      expect(err, contains('60'));
    });
  });

  group('SkillDiscovery', () {
    test('发现 skill + 元数据', () {
      writeSkill('coding', 'flutter-helper', 'Helps with Flutter');
      final skills = discovery.findAllSkills();
      expect(skills.length, 1);
      expect(skills.first.name, 'flutter-helper');
      expect(skills.first.category, 'coding');
      expect(skills.first.description, 'Helps with Flutter');
    });

    test('排除支持目录（references）', () {
      writeSkill('coding', 'main', 'Main skill');
      // references 下放一个伪 SKILL.md。
      final refDir = p.join(tmp.path, 'skills', 'coding', 'main', 'references');
      Directory(refDir).createSync(recursive: true);
      File(p.join(refDir, 'SKILL.md')).writeAsStringSync(
        '---\nname: ref\ndescription: Should be excluded\n---\n',
      );
      final skills = discovery.findAllSkills();
      expect(skills.length, 1);
      expect(skills.first.name, 'main');
    });

    test('findSkill 按名查找', () {
      writeSkill('coding', 'flutter-helper', 'desc');
      final skill = discovery.findSkill('flutter-helper');
      expect(skill, isNotNull);
      expect(skill!.dir, contains('flutter-helper'));
    });
  });

  group('skills 工具', () {
    test('skill_manage create + skills_list', () {
      final result = skillManageTool(
        action: 'create',
        name: 'test-skill',
        content: '---\nname: test-skill\ndescription: A test skill\n---\n\nBody\n',
        category: 'general',
      );
      final map = jsonDecode(result) as Map;
      expect(map['success'], true);

      final list = skillsListTool();
      final listMap = jsonDecode(list) as Map;
      expect(listMap['count'], 1);
    });

    test('skill_manage create 拒绝过长 description', () {
      final longDesc = List.filled(70, 'a').join();
      final result = skillManageTool(
        action: 'create',
        name: 'bad-skill',
        content: '---\nname: bad-skill\ndescription: $longDesc\n---\n',
      );
      expect(result, contains('60'));
    });

    test('skill_manage create 拒绝重名', () {
      skillManageTool(
        action: 'create',
        name: 'dup',
        content: '---\nname: dup\ndescription: First\n---\n',
      );
      final result = skillManageTool(
        action: 'create',
        name: 'dup',
        content: '---\nname: dup\ndescription: Second\n---\n',
      );
      expect(result, contains('already exists'));
    });

    test('skill_view 读取内容', () {
      skillManageTool(
        action: 'create',
        name: 'view-skill',
        content: '---\nname: view-skill\ndescription: View me\n---\n\nBody here\n',
      );
      final result = skillViewTool(name: 'view-skill');
      final map = jsonDecode(result) as Map;
      expect(map['content'], contains('Body here'));
    });

    test('skill_manage delete', () {
      skillManageTool(
        action: 'create',
        name: 'del-skill',
        content: '---\nname: del-skill\ndescription: Delete me\n---\n',
      );
      final result = skillManageTool(action: 'delete', name: 'del-skill');
      final map = jsonDecode(result) as Map;
      expect(map['success'], true);
      expect(discovery.findSkill('del-skill'), isNull);
    });

    test('skill_manage patch 模糊编辑', () {
      skillManageTool(
        action: 'create',
        name: 'patch-skill',
        content: '---\nname: patch-skill\ndescription: Patch me\n---\n\nOld line here\n',
      );
      final result = skillManageTool(
        action: 'patch',
        name: 'patch-skill',
        oldString: 'Old line here',
        newString: 'New line here',
      );
      final map = jsonDecode(result) as Map;
      expect(map['success'], true);
      final content = discovery.readContent(discovery.findSkill('patch-skill')!.path);
      expect(content, contains('New line here'));
    });
  });

  group('system prompt 注入', () {
    test('buildSkillsSystemPrompt 按 category 分组', () {
      writeSkill('coding', 'a-skill', 'About coding A');
      writeSkill('writing', 'b-skill', 'About writing B');
      final block = buildSkillsSystemPrompt();
      expect(block, contains('## Skills (mandatory)'));
      expect(block, contains('coding'));
      expect(block, contains('a-skill'));
      expect(block, contains('writing'));
      expect(block, contains('b-skill'));
    });

    test('无 skill 返回空', () {
      Services.instance.skillDiscovery =
          SkillDiscovery(skillsRoot: p.join(tmp.path, 'empty'));
      final block = buildSkillsSystemPrompt();
      expect(block, isEmpty);
    });
  });
}
