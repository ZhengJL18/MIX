# MIX 项目交接说明（Handoff）

> 给接续此项目的协作者 / AI。本文概括项目定位、当前进度、关键约定和踩过的坑，方便快速上手。

## 1. 项目是什么

**MIX**：在 Flutter 隔离墙（Android App 沙盒）内实现 agent 级能力的纯 Dart 框架。

- **复刻策略**：以开源 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（master）为唯一行为规范，用 Dart 逐文件重写其核心闭环，**不自创工具系统**。
- **目标形态**：Android App（可运行在手机沙盒内做 agent）。
- **平台状态（2026-08）**：Linux 桌面版已停止维护。含 Linux 支持的完整源码保存在 `linux-desktop` 分支；master 已移除全部 Linux 相关代码（`linux/` 目录、run_terminal 工具、桌面工作区、deb 更新、CI linux job 等），只构建 Android。
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

### 阻塞型重活隔离（2026-08-16）
- **动机**：git clone / 下载 / 加解密等同步 CPU 重活跑在主 isolate，导致「UI 卡住 / 转圈」。不逐个定位真凶，改为**全部阻塞型重活统一丢后台 isolate**（`Isolate.run`），主 isolate 只收结果。
- **已隔离**：git 工具集全部 10 个操作（init/status/add/commit/log/branch/diff/clone/push/pull，git_tools.dart）；保险柜 AES+PBKDF2 加密/解密（vault_screen.dart）；md→docx zip 打包（convert_tools.dart）；教材导入解压+tar 解析+逐文件转写（textbook_importer.dart，`_extractAndWrite` 顶层函数进 isolate，进度 0.55→1.0 两段式）；出题管线 JSON 提取（study_question_service.dart，`_extractJson` → `_extractJsonFromText` 顶层函数）。
- **踩坑记录**：
  - 跨 isolate 只传可发送的 primitive（String/int/bool/List/Map），对象（TextbookSource 等）要拆字段传参。
  - 进度回调 / SharedPreferences / 平台通道不能进 isolate：token 与 SSL 初始化在 handler 里先做（主 isolate），解析后的值传进 isolate。
  - isolate 内异常会包成 RemoteError：vault 解密在 isolate 内捕获 FormatException 转 null 哨兵，外面 `on FormatException` 分支才能正常显示「密钥错误或数据损坏」。
  - 顺带修复：github_screen 本地仓库操作 switch 缺 break（case 运行时 fallthrough，commit 结果被后续 case 覆盖）——补 break。
- **约束**：今后新增阻塞型重活一律走 `Isolate.run`，不写回主 isolate；测试仍可直接调用同步纯函数（如 encryptPayload）。

### 学习工具（study）
- `study_list` / `study_question` / `study_record` / `study_profile_update`。
- **`study_quiz`（2026-08-14 新增，批量题卡）**：一次多题 → UI 渲染 PageView 滑动题卡（题目+选项同卡）→ 逐题作答、UI 机械判题（grade=true，对绿错红+简析）→ 答完 complete 回填 agent → agent 讲解错题；开放题 grade=false 由 AI 点评。`update_profile` 由 AI 出题时声明；有真实 question_id 的题才落 `study_record`，手写题不落库。已接入学习模式与通用助手（daily）工作流，`toolsets.dart` 新增 `quiz` 工具集。设计文档见 `notes/规划/MIX批量题卡-设计与落地.md`。**遗留：真机验证未做（daily「出 10 题」→ 滑动 → 判题 → 讲解）。**
  - **踩坑（8-14 修）**：判题不能复用 clarify 的 `_isClarifyCorrect`——clarify 的 answer 是字母（"B"），quiz 的 answer 是**选项文本**，点选项传字母会选对判错。专用 `_isQuizCorrect(picked, q)`：字母↔选项文本双向规约再匹配，判题与选项高亮共用。
  - 题卡内容走 `MIXMarkdown`（LaTeX 渲染）；选择题卡底部支持自定义答案输入（`_CustomAnswerField`）；卡片高度按内容估算自适应（`_cardHeight`），尽量一屏放下 4 选项。

### 记忆子系统（v4 架构，2026-08-16 P0-P3 逐步落地，设计见 `docs/MEMORY_SYSTEM_DESIGN.md`）
- **P0 检索端**：`memory.db`（memory_docs/tags/links/summaries/evidence/goals/async_delegations 七表 + FTS5）；dart_jieba 中文分词（assets/dict.dgz 2MB 复制到私有目录加载）；`memory_search`（bm25+OR+摘要优先）/ `memory_read` 工具（memory toolset）；`MemoryManager.prefetchRecall` 每轮冻结快照+热词检索合成 `<memory-context>` 注入 + 8s 有界等待。⚠️ **FTS5 可用性因设备而异**（AOSP 系统 SQLite 未编译 FTS5）——代码已 LIKE 降级，**真机必须验证**；长期方案迁 `sqlite3` 3.x 自带 FTS5。
- **P1 图建构 + 置信度**：`MemoryIndexer`（memory 工具写入后自动提取热词标签 → 同标签互连 Hebbian → 知识点匹配连边，study_engine 知识点入图为 `kind='knowledge'` 文档）；`MemoryConfidence`（Beta 置信度 + 遗忘衰减 + 注入门控）；检索/读取/激活写证据痕迹。
- **P2 摘要层**：`MemorySummarizer`（回合后 finally 异步总结激活过的文档，快模型 summarizeFn 注入，≤160 字 snippet；原文权威、stale 重生成）。
- **P3 Goal + 对账 + pruner + 技能注入 + 异步委派**：`GoalStore`（goals/async_delegations 表；create/get/list/update + revision 乐观锁 + advanceRound 续跑 + deriveProgress 证据驱动进度）；`goal` 工具（create/list/update/progress）；`memory_verify` 工具（check/verify/stale，对账闭环）；`tool_result_pruner`（JSON 数组→统计+前5项/对象→键数+前8键/文本→头部+标注，接入 model_tools.handleFunctionCall）；技能目录注入（skillCatalogProvider，`<skills-catalog>` 并入 volatile 系统提示）；异步委派（`delegate_task_async` 立即返回 delegation_id 后台执行 + `delegation_status` 查询，async_delegations 表记录）。
- **P4 学习描绘（副业干过主业）**：`study_record` 判题落库后写知识点证据（correct/wrong，study_engine.getQuestionKp 映射）；`MemoryLearning` 从证据流推导可提取性（Bjork retrievability = 命中率×新鲜度）/掌握信号（Beta 置信度）/遗忘节律（距最近证据），状态分类 unknown/mastered/learning/weak/review_due；`study_status` 工具（all / review_due 复习推荐，weak 优先）；`MemoryProfileProjector` 证据驱动画像投影（统计/复习推荐/科目分组渲染 Markdown，零 LLM，回合后刷新到记忆库 `memory/profile.md`，agent 可 memory_read——0_profile.md LLM 叙事画像的数据侧补充）。
- **踩坑（8-16）**：① dart_jieba 内部用 `dart:io File` 读词典，Flutter assets 不能 File 读 → `initChineseSegmenter` 把 assets/dict.dgz 复制到私有目录 `.mix_cache/` 再加载（包自身未声明 flutter assets，词典须自带）；② `markTestSkipped` 不在 flutter_test 导出（test_compat.dart 只 show Fake）→ 测试用 `skip:` 参数（main 里先初始化再注册 test 让 skip 正确求值）；③ sqflite 默认外键关闭 → memory.db init 显式 `PRAGMA foreign_keys = ON`，deleteDoc 同时手动清理关联（双保险）；④ `upsertSummary` 的 docMtime 是位置参数，测试误用命名参数导致 analyze 编译失败；⑤ CI analyze 日志需登录才能看 → workflow 加 "Expose analyze details" 步骤把错误写进公开 annotations（GitHub ::error:: 换行要 %0A 转义、annotation 上限 10 条，失败详情块用 python 正则提取）；⑥ **Dart 非空可选命名参数必须 required 或默认值**（`updateGoal` 的 `int expectedRevision` 缺 required 导致 goal_store_test 编译失败，flutter analyze 未报、flutter test 加载才报）；⑦ 图边是无向的 → `getNeighbors` 必须双向查询（`src=? OR dst=?` + CASE 取另一端）。
- **遗留**：P2 决策点注入（当前每轮 prefetch 注入，优化为仅决策点注入省 token）未做；异步委派的取消/完成通知 UI 未做。**P2 单 worker 保序写无需额外实现**——sqflite 单实例数据库操作天然串行（内部排队），回合后摘要/索引/投影各自 fire-and-forget 已保序。真机 FTS5 + 分词器验证未做（最高优先级，需用户手机 adb）。

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

3. **sqflite_common_ffi 在 dev_dependencies**：sqflite 在测试主机（非 Android）无实现，`test/session_db_test.dart` 靠它提供本地数据库工厂；它是**测试依赖**，不属于 App 运行时依赖。

4. **Android 11+ 首次使用**：需在设置页授予「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`），否则 agent 无法读写公共目录。

## 6. 构建 & 运行

```bash
flutter pub get
flutter build apk --release     # Android
```

- Flutter SDK 要求：`^3.12.2`（见 `pubspec.yaml`）。

## 7. 复刻进度跟踪

- 唯一权威映射表：`docs/HERMES_MAPPING.md`。接手后从这里继续 P0→P1→P2 的逐文件 Dart 复刻，不要偏离 Hermes master 的行为规范。
