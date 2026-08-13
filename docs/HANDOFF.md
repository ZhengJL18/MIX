# MIX 项目交接说明（Handoff）

> 给接续此项目的协作者 / AI。本文概括项目定位、当前进度、关键约定和踩过的坑，方便快速上手。

## 1. 项目是什么

**MIX**：在 Flutter 隔离墙（Android App 沙盒）内实现 agent 级能力的纯 Dart 框架。

- **复刻策略**：以开源 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（master）为唯一行为规范，用 Dart 逐文件重写其核心闭环，**不自创工具系统**。
- **目标形态**：Android App（可运行在手机沙盒内做 agent），同时带 Linux 桌面支持。
- **核心技术栈**：Flutter / Dart，纯 Dart 实现（无原生 agent 依赖），SQLite 存会话，libgit2（git2dart）做 git。

## 2. 当前进度

- 处于「复刻映射」阶段：`docs/HERMES_MAPPING.md` 钉死了「必须复刻 / 手机不可用跳过 / 适配」三类清单，按 **P0 → P1 → P2** 逐文件 Dart 复刻。
- **P0 核心工具集已实现**（见下）。

## 3. 已实现能力

### 核心工具集（P0）
- 文件工具：`read_file` / `write_file` / `patch` / `search_files`，通过 `MANAGE_EXTERNAL_STORAGE` 读写公共目录（Download/Documents）。
- 记忆系统：`memory`，跨会话持久、自动注入、容量上限管理。
- 网络工具：`web_search` / `web_extract`，内置 SSRF 防护（拦截解析到私有/内网地址）。
- 任务管理：`todo`。
- 会话回顾：`session_search`。
- 技能系统：`skills_list` / `skill_view` / `skill_manage`。

### git 支持
- 基于 git2dart（嵌入 libgit2）：clone / status / add / commit / pull / push。
- 认证走 App 设置中的 GitHub PAT（`github_pat_token` / `github_username`）。
- 支持 SSL 证书配置（修 clone 报 `SSL certificate invalid`）。

### 对话体验
- Markdown 渲染；LaTeX 公式（行内 `$...$`、块 `$$...$$`，支持矩阵/方程组/行列式/下标/分数等）。

### 配置
- 多供应商 LLM（DeepSeek / OpenAI 兼容），动态拉取模型列表；设置页引导「所有文件访问」授权。

## 4. 项目结构

```
lib/
├── agent/       # Agent 核心循环
├── config/      # LLM 配置（mix_config / providers）
├── db/          # SQLite 会话库（sessions / messages / FTS5）
├── llm/         # LLM 客户端（OpenAI 兼容 SSE 流式）
├── notes/       # 笔记库（subject_library 讲义等）
├── printnotes/  # printnotes 渲染引擎 + UI 子系统（md 渲染自包含）
├── refine/      # 精炼/润色
├── screens/     # 聊天 / 设置 / 历史 / 技能页面
├── services/    # 权限处理等服务
├── skills/      # 技能系统
├── theme/       # 主题
├── tools/       # 工具实现（file / web / memory / todo / session / skills）
└── widgets/     # Markdown / LaTeX 组件

server/          # vault-server.js（本地笔记同步服务）
skills/          # 内置技能（question-design 等）
third_party/     # 本地 patch 的第三方插件（见下）
docs/            # 文档（HERMES_MAPPING.md 等）
```

## 5. 关键约定与踩坑（重要，接手必读）

1. **`dependency_overrides` 本地 patch 了两个插件**（AGP 9 兼容性问题）：
   - `third_party/flutter_inappwebview_android`：原版 1.1.3 在 AGP 9 下调用已移除的 `getDefaultProguardFile('proguard-android.txt')`，本地副本改一行修复。
   - `third_party/file_picker`：11.0.3 在 AGP 9 + Flutter Built-in Kotlin 下条件跳过 KGP，导致 `FilePickerPlugin.kt` 未编译，本地副本修 build.gradle 始终应用 Kotlin。
   - 升级这两个依赖前，务必确认上游已兼容 AGP 9，否则会回退到编译失败。

2. **大体积运行时资源按需下载**：`mermaid.min.js`、`pyodide core` 等不进 APK，由 `RemoteAssetManager` 从仓库 raw 地址拉取并缓存到私有目录，保证安装包最小。仅 **KaTeX**（约 600KB）打包进 APK，用于 `md_to_pdf` 完全离线渲染（WebView 本地加载，不依赖 CDN）。

3. **Linux 桌面端**：sqflite 无 Linux 实现，改用 `sqflite_common_ffi`（本地 sqlite）。`file_selector` 用于桌面工作区目录选择，仅 Linux 触发，Android 不启用。

4. **Android 11+ 首次使用**：需在设置页授予「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`），否则 agent 无法读写公共目录。

## 6. 构建 & 运行

```bash
flutter pub get
flutter build apk --release     # Android
# 桌面端（Linux）：
flutter run -d linux
```

- Flutter SDK 要求：`^3.12.2`（见 `pubspec.yaml`）。

## 7. 复刻进度跟踪

- 唯一权威映射表：`docs/HERMES_MAPPING.md`。接手后从这里继续 P0→P1→P2 的逐文件 Dart 复刻，不要偏离 Hermes master 的行为规范。
