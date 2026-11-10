import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:introduction_screen/introduction_screen.dart';

import 'package:mix/printnotes/providers/settings_provider.dart';

class IntroScreen extends StatelessWidget {
  const IntroScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return IntroductionScreen(
      pages: [
        PageViewModel(
          title: "欢迎使用 MIX 笔记库",
          body: "你的 Markdown 笔记库,与 MIX 共用同一目录,"
              "agent 写的笔记这里能看到,这里编辑的笔记 agent 能读到。",
          image: Center(
              child: Icon(
            Icons.code_rounded,
            size: 150.0,
            color: Theme.of(context).colorScheme.secondary,
          )),
        ),
        PageViewModel(
          title: "笔记库位置",
          body: "笔记统一存放在 App 应用目录下的 notes 文件夹,"
              "与 Claude 共用同一个库。\n\n"
              "agent 写的笔记、学习讲义都会出现在这里,你可以直接浏览、编辑。",
          image: Center(
              child: Icon(
            Icons.folder,
            size: 150.0,
            color: Theme.of(context).colorScheme.secondary,
          )),
        ),
        PageViewModel(
          title: "网络使用",
          body: "仅当 Markdown/HTML 渲染外部图片链接时才需要联网。\n\n"
              "除此之外不传输、不收集、不存储任何数据。",
          image: Center(
              child: Icon(
            Icons.wifi_lock,
            size: 150.0,
            color: Theme.of(context).colorScheme.secondary,
          )),
        ),
      ],
      showSkipButton: false,
      showNextButton: true,
      showDoneButton: true,
      next: Icon(
        Icons.arrow_forward_rounded,
        color: Theme.of(context).colorScheme.secondary,
        size: 30,
      ),
      done: Text("完成",
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.secondary,
          )),
      onDone: () {
        context.read<SettingsProvider>().setShowIntro(false);
      },
      dotsDecorator: DotsDecorator(
        size: const Size.square(10.0),
        activeSize: const Size(20.0, 10.0),
        activeColor: Theme.of(context).colorScheme.secondary,
        color: Colors.black26,
        spacing: const EdgeInsets.symmetric(horizontal: 3.0),
        activeShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(25.0),
        ),
      ),
    );
  }
}
