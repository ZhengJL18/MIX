# MIX

在 Flutter 隔离墙（Android App 沙盒）内实现 agent 级能力的纯 Dart 框架，通用 AI agent。

**复刻策略**：以开源 [Hermes Agent](https://github.com/NousResearch/hermes-agent)（main，锚定 commit `0a62610f10cc34d696b2239b2c69fa1ba0f1ca63`）为唯一行为规范，用 Dart 逐文件重写其核心闭环，**不自创工具系统**。复刻清单见 `docs/HERMES_MAPPING.md`。

**平台**：Android（主）。

> 平台状态（2026-08）：Linux 桌面版已停止维护。含 Linux 支持的完整源码保存在 `linux-desktop` 分支；master 已移除全部 Linux 相关代码（`linux/` 目录、run_terminal 工具、桌面工作区、deb 更新、CI linux job 等），只构建 Android。

> ⚠️ **维护约定（重要）**：功能有**重大更新**时（新增子系统 / 工具集 / 外部服务、架构调整、依赖大版本升级），本文档必须同步更新，并同步更新 `docs/HANDOFF.md` 的进度与踩坑记录。小事（bug 修复、文案）可不改。

---

## 已实现能力全景（按当前代码状态，2026-08）

### Agent 核心闭环
- `MIXAgent` 主循环（对应 Hermes `conversation_loop.py`）：prologue → 上下文压缩门控 → LLM 调用（错误分类 + jittered 退避重试）→ 工具执行回填 → 循环 / 终止，全程落库
- **上下文压缩**：LLM 摘要中间段（保护头 + 尾 ~20K token），最近 2 次压缩省 <10% 防抖动
- **错误分类**：401/403/413/429/5xx → 重试 / 压缩 / 轮换凭据 / 友好中文提示
- **防死循环**：同一工具 + 同参数连续失败 3 次注入警告，2 轮仍失败自动中断
- **消息配对清洗** `sanitizeToolPairing`：发送前修复残缺/错位的 assistant↔tool 消息对（严格 OpenAI 格式，防 400）
- **迭代预算**：每 agent 独立计数器，预算耗尽即停
- **会话持久化 + 跨重启恢复**：上次会话 id 记忆，重启自动恢复历史

### 工具系统（≈40 个工具，全部走 Hermes 式注册协议）
- **文件**：`read_file` / `write_file` / `patch`(V4A) / `search_files` / copy / move / delete，含路径安全、敏感路径拦截、V4A 穿越拒绝
- **网络**：`web_search`（谷歌 → 必应 → DuckDuckGo 无 key 逐级 fallback）/ `web_extract` / `web_download`，内置 SSRF 防护（拦截私网 / 云元数据端点）
- **记忆**：`memory`（MEMORY.md / USER.md 文件持久化、容量上限、冻结快照注入保 prefix cache）+ `memory_search` / `memory_read`（多记忆文档热词检索，见下"记忆子系统"）
- **任务与会话**：`todo` / `session_search`（SQLite FTS5 四模式）/ `clarify`（内联选择卡，UI 机械判对错）
- **技能**：`skills_list` / `skill_view` / `skill_manage`（SKILL.md frontmatter 解析、渐进式披露索引）
- **委派与多代理**：`delegate_task`（最多 3 层子代理，快模型分级委派）/ `moa_discuss`（3 视角 × N 轮辩论 + 主持人综合）/ `delegate_to_department`（公司模式，CEO 调度部门）
- **git**：基于 git2dart（嵌入式 libgit2），clone / init / status / add / commit / log / branch / diff / push / pull + `github_ci_logs`，认证自动读配置里的 GitHub PAT
- **学习**：`study_list` / `study_question` / `study_record` / `study_profile_update` / `study_quiz`（批量题卡：左右滑动逐题作答，UI 机械判题，答完回填 agent 讲解；学习模式与通用助手均可出批量题）
- **笔记库**：`notes_list` / `notes_search` / `notes_read` / `notes_write`（写后聊天侧出「打开笔记」深链）
- **其他**：`vision_analyze`（独立视觉模型配置）、`read_doc`（格式探测 + **本地文档→Markdown**：docx 结构化转换 / pptx 逐页大纲 / xlsx 表格 / pdf 本地文本提取（pdfium），云端 /extract 仅 fallback）、`md_to_docx` / `md_to_pdf` / `cloud_extract`、`cron_create/list/delete`（App 存活时触发）、用户脚本（知乎去登录 / 通用复制解锁 / 小红书）

### 记忆子系统（v4 架构，2026-08 P0-P4 落地，设计见 `docs/MEMORY_SYSTEM_DESIGN.md`）
- **多记忆文档**：记忆库 `memory.db`（memory_docs / tags / links / summaries / evidence / goals / async_delegations 七表 + FTS5），`memory` 工具写入的内容自动索引为记忆文档；**笔记库（printnotes）增量同步**为记忆文档（`NotesSyncService`，kind='note'，mtime 增量比对）——笔记可被 `memory_search` 检索、进联想图
- **中文分词**：dart_jieba（Python jieba 纯 Dart 移植，MIT），assets 打包词典（2MB）+ jieba idf.txt（6.2MB 热词权重）；FTS5 预分词检索 + LIKE 降级
- **热词检索**：`memory_search`（FTS5 bm25 + OR 连接 + 摘要优先 + token 预算）、`memory_read`（全文/摘要）
- **确定性图建构（P1）**：写入时自动提取热词标签（黑名单 + IDF 门槛 + log 饱和防污染）→ 同标签文档互连（Hebbian 边权）→ 知识点匹配连边（study_engine 知识点入图为 `kind='knowledge'` 文档，扩散沿知识层级走）
- **置信度引擎（P1）**：检索/读取/激活/作答事件流（memory_evidence）→ Beta-Binomial 置信度 + 遗忘衰减 → 注入门控（可靠度低不注入，"宁可缺不可杂"）
- **异步预取**：每轮 `prefetchRecall` 冻结快照 + 热词检索合成 `<memory-context>` 围栏注入当前轮（保 prefix cache），**有界等待 8s 超时跳过**
- **摘要层（P2）**：回合后异步总结激活过的文档（快模型，≤100 字 snippet，原文权威）→ 检索/注入摘要优先
- **Goal 系统（P3）**：`goal` 工具（create/list/update/progress），持久目标 + revision 乐观锁 + 续跑轮次；进度由置信度引擎证据驱动（`evidence_obj` 关联）
- **记忆对账（P3）**：`memory_verify`（check 可靠度报告 / verify 正证据 / stale 负证据），时点快照原则——引用外部状态前先对账，结果写回证据形成"越用越可信"闭环
- **工具结果 pruner（P3）**：超大工具输出确定性裁剪（JSON 统计/文本头部），防淹没上下文
- **技能目录注入（P3）**：技能名+描述并入系统提示 volatile 层（`<skills-catalog>`），agent 不遗忘可用技能
- **异步委派（P3）**：`delegate_task_async` 派发立即返回 delegation_id 后台执行 + `delegation_status` 查询（async_delegations 表）
- **学习描绘（P4）**：判题落库写知识点证据（correct/wrong）→ `MemoryLearning` 推导可提取性/掌握/遗忘（状态分类 mastered/learning/weak/review_due）→ `study_status` 工具（复习推荐）；`MemoryProfileProjector` 证据驱动画像投影（回合后刷新 `memory/profile.md`）

### 学习模式（核心特色：聊天即学习主场）
- `StudyEngine`：SQLite 事实层（subjects / knowledge_points / questions / practice_records），**掌握度 = 近 15 题正确率的 SQL 现场聚合**，零公式零 LLM
- `StudyQuestionService`：7 阶段精炼出题管线（选点取材 → 雏形 → 加复杂度×1-4 轮 → 独立批判 → 回头 → 精炼 → 终审），token 有界；方法论沉淀在 `skills/question-design/SKILL.md`
- 出题 → `study_quiz` 批量题卡呈现（PageView 滑动，题目+选项同卡）→ **UI 机械判题**（不靠 LLM 比较字母）→ 落库 → agent 讲解；单题对话式出题仍走 clarify；学生画像 `0_profile.md` 持久化
- `study_quiz` 判题/画像由 AI 声明：`grade`（是否机械判，开放题 false）/ `update_profile`（是否记画像）；题目来自 `study_question`（有 question_id）才落 `study_record`，手写题不落库

### 自进化（Continual Harness，refine 管线）
- 任务完成后读轨迹（`trajectory.jsonl`），用主 LLM 提议**小步、带证据**的编辑（memory 增/替换、skill 新建、prompt note 新增）
- 用户批准后应用，`EditJournal` 记录可逆操作支持单条回滚；基础 workflow 提示不可变

### 多代理
- `MultiAgentService` 三合一：子代理（独立 MIXAgent）、部门执行（角色讨论 → 并行分工 → 经理汇总）、MoA 讨论；失败隔离、取消传播、进度事件驱动 UI

### 工作流（5 个内置）
coding（先计划后执行，plan 模式）/ research / daily / company（CEO + 部门）/ study（学习教练）

### 对话体验
- `MIXMarkdown` 统一渲染：Markdown + LaTeX（行内/块级、矩阵/方程组/行列式）+ `[[wiki 链接]]` + `#标签` + `==高亮==` + 上下标 + 代码复制
- 计划模式（先只读探索出计划，批准后执行）、思考强度滑块（7 个流程各自独立）、reasoning 思考块实时流式显示

### 笔记库（printnotes 子系统）
- 嵌入的 Obsidian 式 Markdown 笔记 App，与 agent 共用 `documents/notes` 目录（UI 编辑的笔记 agent 能读到，agent 写的笔记 UI 能看到）
- 树形 / 网格 / 平铺三种布局、标签、回收站 / 归档、全文搜索、任务列表勾选、外部修改检测
- 教材导入：内置 3 套开源数学教材（MIT 18.06 线代 / obsidian_math 高数线代 / Prob140 概率论），从自有镜像或 GitHub 拉取
- mermaid 图渲染（按需下载 mermaid.min.js + 单个全局 Headless WebView 串行渲染）、云端代码块执行（python/c/js/bash/java/sql）

### 配置与服务
- 多供应商 LLM（DeepSeek / 通义 / OpenAI / Kimi / 智谱 / Gemini / OpenRouter / Anthropic），`/models` 动态拉模型列表
- 云端保险柜：注册 / 登录后 AES-256-CBC + PBKDF2 加密备份上传下载（服务器只存密文）
- 自动更新：国内镜像优先 + GitHub Releases 兜底；Android 应用内安装（app_installer_plus）
- 「所有文件访问」权限引导（原生 `ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` 专用页）
- 5 套内置主题（青绿/靛蓝/暖橙/紫罗兰/玫瑰）+ 明暗切换

### 阻塞型重活隔离（isolate）
- **原则**：所有同步 CPU 密集 / 文件 IO 重活（git 全家、加密解密、zip 打包、tar 解压解析、大 JSON 解析）一律丢后台 isolate（`Isolate.run`）执行，主 isolate 只收结果，杜绝「下载 / git clone 时 UI 卡死」。
- 已隔离：git 工具集全部 10 个操作（git_tools）、保险柜加密/解密（vault_screen）、md→docx zip 打包（convert_tools）、教材导入解压解析（textbook_importer）、出题 JSON 提取（study_question_service）。
- 约束：isolate 内不能碰平台通道 / SharedPreferences / UI；跨 isolate 只传可发送的 primitive，进度回调留在主 isolate 侧按阶段推进。

## 项目结构

```
lib/
├── agent/          # Agent 核心循环（主循环/压缩/预算/错误分类/工作流/公司模式）
├── config/         # LLM 配置（mix_config / providers 解析链）
├── db/             # SQLite 会话库（sessions / messages / FTS5）
├── llm/            # OpenAI 兼容 LLM 客户端（SSE 流式 + tool_calls 聚合）
├── notes/          # 笔记库路径常量（documents/notes，UI 与 agent 共用）
├── printnotes/     # 笔记子系统（自包含 markdown 渲染引擎 + 笔记库 UI）
├── refine/         # 自进化管线（轨迹 / prompt notes / 编辑台账）
├── screens/        # 聊天 / 设置 / 历史 / 技能 / GitHub / 保险柜等页面
├── services/       # 记忆子系统（记忆库/分词/索引/置信度/摘要/学习/投影/笔记同步）
                    #   + 多代理 / 学习引擎 / 出题 / 保险柜 / 更新 / 权限
├── skills/         # 技能系统（SKILL.md 发现 / 解析）
├── theme/          # 集中式主题系统（AppPalette + 5 套主题）
├── tools/          # 工具实现（registry / model_tools / 各工具模块）
└── widgets/        # MIXMarkdown 全局渲染组件
server/             # vault-server.js（云端保险柜服务端，Node 零依赖）
skills/             # 内置技能（question-design 出题方法论）
assets/             # katex（打包进 APK）/ mermaid（按需下载）/ mirror-sync / remote-runner
third_party/        # 本地 patch 的第三方插件（AGP 9 兼容，见下）
docs/               # HERMES_MAPPING.md（复刻映射表）/ HANDOFF.md（交接说明）
test/               # 39 个测试文件
```

## 关键约定与踩坑（接手必读）

1. **`dependency_overrides` 本地 patch 了两个插件**（AGP 9 兼容）：
   - `third_party/flutter_inappwebview_android`：原版 1.1.3 在 AGP 9 下调已移除的 `getDefaultProguardFile('proguard-android.txt')`，本地副本改一行修复。
   - `third_party/file_picker`：11.0.3 在 AGP 9 + Flutter Built-in Kotlin 下条件跳过 KGP，导致 `FilePickerPlugin.kt` 未编译，本地副本修 build.gradle 始终应用 Kotlin。
   - **升级这两个依赖前，务必确认上游已兼容 AGP 9，否则回退到编译失败。**
2. **大体积运行时资源按需下载**：mermaid.min.js 等不进 APK，由 `RemoteAssetManager` 从仓库 raw 拉取缓存到私有目录；仅 KaTeX（约 600KB）打包进 APK（md_to_pdf 完全离线渲染）。
3. **sqflite_common_ffi 在 dev_dependencies**：sqflite 在测试主机（非 Android）无实现，`test/session_db_test.dart` 靠它提供本地数据库工厂；它是**测试依赖**，不属于 App 运行时依赖。
4. **Android 11+ 首次使用**：需在设置页授予「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`），否则 agent 无法读写公共目录。权限检测/引导走原生通道（`MainActivity.kt` MethodChannel `com.mix.app/storage`），鸿蒙上比 permission_handler 可靠。
5. **笔记库根固定为 `documents/notes`**：printnotes UI 与 agent `notes_*` 工具共用，**不可改任意目录**，否则 UI 与 agent 分叉。
6. **消息配对严格性**：OpenAI 兼容后端要求 assistant 声明 tool_calls 后紧跟连续的 tool 结果，中间不能插 user 消息——所有路径（历史恢复 / 压缩 / 中断 / 防死循环警告）都要保证这一点，这是大量 400 错误的根源。
7. **外部基础设施硬依赖**（一台服务器，`43.139.179.58`，无 TLS 明文 HTTP）：
   - `/update/latest.json` 更新镜像（`assets/mirror-sync/sync_mirror.py` 每 10 分钟同步 GitHub Releases）
   - `/vault` 云端保险柜（`server/vault-server.js`）
   - `/run` 云端代码执行 + `/extract` 格式转换（`assets/remote-runner/server.py`）
   - `/textbooks` 教材镜像
   - 服务器不可用则对应功能自动降级，App 主体不受影响。

## 构建 & 运行

```bash
flutter pub get
flutter build apk --release     # Android
```

- Flutter SDK 要求：`^3.12.2`（见 `pubspec.yaml`）。

## 测试

```bash
flutter test
```

39 个测试文件覆盖：agent 主循环（防死循环 / 消息清洗 / 迭代预算）、LLM 流式聚合、错误分类、上下文压缩、工具注册与参数强转、schema 清洗、记忆子系统（记忆库 CRUD/检索/标签/链接/证据/摘要/置信度/热词/索引/学习状态/画像投影/笔记同步/goal/对账/异步委派/pruner）、模糊匹配 / SequenceMatcher、vault 加密往返、web 搜索后端等。
注意：`markdown_math_test` / `matrix_test` 因 markdown_widget 引擎的 visibility_detector 全局 Timer 与测试框架不兼容，**全部 skip**（引擎由 printnotes 生产验证）。

## 文档导航

- `docs/HERMES_MAPPING.md`：Hermes → Dart 复刻映射表（唯一权威，P0→P1→P2 逐文件推进）
- `docs/HANDOFF.md`：交接说明（当前进度、关键约定、踩坑）
