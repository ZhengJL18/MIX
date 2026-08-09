// 通用代码执行框架（CodeEngine）。
//
// 思路：mermaid / python(Pyodide) 本质是同一套模式——
//   "识别代码块语言 → 查映射表 → 按需下载/加载资源 → 执行/渲染 → 展示结果"
// 这里把模式抽象成 CodeEngine + 全局注册表：
//   - 新增一种语言 = 新建一个 CodeEngine 实现 + 注册一行，codeWrapper 不用改；
//   - 运行时资源（WASM / 脚本 / 数据）不打包进 APK，通过 requiredAssets
//     声明后按需下载（URL / 大小 / sha256），缓存到应用私有目录。
//
// 用法（以未来加 JS 为例）：
//   class JsCodeEngine extends CodeEngine { ... }
//   CodeEngineRegistry.register(const JsCodeEngine());
//   // 远端放好运行时文件，App 内即可运行 ```js 代码块。

import 'package:flutter/widgets.dart';

/// 引擎所需的按需下载资源（空列表 = 无需下载，资源已内置）。
class EngineAsset {
  const EngineAsset({
    required this.name,
    required this.url,
    required this.sizeMB,
    this.sha256,
  });

  /// 资源名（用于提示与缓存目录）。
  final String name;

  /// 下载地址（用户 GitHub 仓库等稳定源）。
  final String url;

  /// 大致体积，用于 UI 提示。
  final double sizeMB;

  /// 可选 sha256，下载后校验完整性。
  final String? sha256;
}

/// 一种可执行 / 可渲染的代码语言 = 一个引擎。
abstract class CodeEngine {
  const CodeEngine();

  /// 主语言名（小写，如 'python'、'mermaid'）。
  String get language;

  /// 别名（如 'py' → python）。
  List<String> get aliases;

  /// 展示名（如 'Python (Pyodide)'）。
  String get displayName;

  /// 需要按需下载的资源（首次使用时由 UI 提示下载）。
  List<EngineAsset> get requiredAssets;

  /// 构建代码块组件（引擎自身的渲染/执行 UI）。
  Widget buildWidget(String code);
}

/// 语言 → 引擎 全局映射表（"只需一个映射表"的落点）。
class CodeEngineRegistry {
  CodeEngineRegistry._();

  static final Map<String, CodeEngine> _engines = {};

  /// 注册引擎（幂等：重复注册同名语言会覆盖）。
  static void register(CodeEngine engine) {
    _engines[engine.language.toLowerCase()] = engine;
    for (final a in engine.aliases) {
      _engines[a.toLowerCase()] = engine;
    }
  }

  /// 按代码块语言查引擎（未注册返回 null → 走普通高亮）。
  static CodeEngine? engineFor(String language) {
    if (language.isEmpty) return null;
    return _engines[language.toLowerCase()];
  }

  /// 已注册的全部引擎（去重）。
  static Iterable<CodeEngine> get engines => _engines.values.toSet();

  /// 已支持的语言集合（含别名）。
  static Set<String> get supportedLanguages => _engines.keys.toSet();
}
