import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mix/theme/app_theme.dart';
import 'package:mix/widgets/chat_chrome.dart';

void main() {
  test('tool phrases use Claude-style verbs and keep TodoWrite off write', () {
    final reading = describeToolPhrase(
      name: 'read_file',
      running: true,
      ok: false,
      input: {'path': 'notes/a.md'},
    );
    expect(reading.verb, '正在读取');
    expect(reading.arg, 'notes/a.md');
    expect(reading.failed, isFalse);

    final wrote = describeToolPhrase(
      name: 'write_file',
      running: false,
      ok: true,
      input: {'file_path': 'notes/a.md'},
    );
    expect(wrote.verb, '已写入');
    expect(wrote.arg, 'notes/a.md');

    final todo = describeToolPhrase(
      name: 'TodoWrite',
      running: false,
      ok: true,
    );
    expect(todo.verb, '已更新任务');
    expect(todo.verb, isNot(contains('写入')));

    final failed = describeToolPhrase(
      name: 'bash',
      running: false,
      ok: false,
      input: {'command': 'ls'},
    );
    expect(failed.verb, '运行失败');
    expect(failed.arg, 'ls');
    expect(failed.failed, isTrue);

    final unknown = describeToolPhrase(
      name: 'custom_tool',
      running: false,
      ok: true,
    );
    expect(unknown.verb, '已调用');
    expect(unknown.arg, 'custom_tool');
  });

  test('user bubbles on both chats go through MIXMarkdown', () {
    final transcript = File('lib/bridge/bridge_transcript.dart').readAsStringSync();
    final chat = File('lib/screens/chat_screen.dart').readAsStringSync();
    final re = RegExp(r'ChatUserBubble\(\s*child:\s*MIXMarkdown\(');
    expect(re.hasMatch(transcript), isTrue, reason: 'cloud user bubble');
    expect(re.hasMatch(chat), isTrue, reason: 'local user bubble');
  });

  testWidgets('event row is a line, not a filled card', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildClaudeTheme(isDark: false),
        home: const Scaffold(
          body: ChatEventRow(
            running: true,
            ok: false,
            verb: '正在读取',
            detail: 'a.md',
          ),
        ),
      ),
    );
    expect(find.textContaining('正在读取'), findsOneWidget);
    expect(find.textContaining('a.md'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('thinking block collapses to a row when not streaming', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildClaudeTheme(isDark: true),
        home: const Scaffold(
          body: ThinkingBlock(
            text: '先看目录',
            streaming: false,
            expanded: false,
          ),
        ),
      ),
    );
    expect(find.text('已思考'), findsOneWidget);
    expect(find.text('先看目录'), findsNothing);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('empty and offline notices share one chrome', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildClaudeTheme(isDark: false),
        home: Scaffold(
          body: Column(
            children: [
              const ChatEmptyState(
                title: 'MIX',
                body: '从这里开始。',
                largeTitle: true,
              ),
              SessionNotice(
                icon: Icons.cloud_off_outlined,
                title: '离线，显示本地缓存',
                detail: '检查网络',
                actionLabel: '重试',
                onAction: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('MIX'), findsOneWidget);
    expect(find.text('离线，显示本地缓存'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(ListTile), findsNothing);

    final title = tester.widget<Text>(find.text('MIX'));
    expect(title.style?.fontSize, 28);
  });

  testWidgets('user bubble stays right-aligned', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildClaudeTheme(isDark: false),
        home: const Scaffold(
          body: ChatUserBubble(child: Text('你好')),
        ),
      ),
    );
    final align = tester.widget<Align>(find.byType(Align));
    expect(align.alignment, Alignment.centerRight);
    expect(find.text('你好'), findsOneWidget);
    final box = tester.widget<Container>(find.descendant(
      of: find.byType(ChatUserBubble),
      matching: find.byType(Container),
    ));
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, const Color(0xFFF4F2F3));
    expect(decoration.borderRadius, BorderRadius.circular(18));
  });
}
