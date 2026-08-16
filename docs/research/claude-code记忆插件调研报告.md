# Claude Code 生态记忆插件调研报告（面向 Flutter 纯 Dart 复刻）

> 调研日期：2026-08（本报告所有 star 数为 GitHub API 实时抓取快照，可能与当下略有出入；最近提交时间取自 `pushed_at` 字段）。
> 信息来源：GitHub API / raw.githubusercontent.com 的 README 与源码、npm registry、官方文档站、媒体报道（仅用于佐证改名链）。GitHub API 中途触发限流，已改用 raw 文件与网页抓取核实。

---

## 1. Clawdbot（已改名 → Moltbot → OpenClaw）

**仓库地址**：委托方给的 `github.com/clawdlabs/clawdbot` 已 **404 不存在**。改名链确证：`Clawdbot → Moltbot → OpenClaw`，现仓库为 **https://github.com/openclaw/openclaw**（386,374★）。
证据链：
- [cloudflare/moltworker](https://github.com/cloudflare/moltworker) 描述："Run OpenClaw, (formerly Moltbot, formerly Clawdbot) on Cloudflare Workers"
- [clawdocs 迁移指南](https://github.com/clawdocs/clawdocs.github.io/blob/gh-pages/docs/guides/migration.md)
- 媒体报道：[Mashable：Clawdbot is now Moltbot…](https://mashable.com/article/clawdbot-changes-name-to-moltbot-openclaw)、[IT之家：数小时两度改名 Clawdbot 变身 OpenClaw](https://www.ithome.com/0/918/052.htm)

**成熟度**：极高且极活跃——386k+ star，最后推送 2026-08-15，是目前最火的开源个人 AI agent 平台。注意：**它是完整 agent 平台（TypeScript），不是 Claude Code 插件**。

**机制分析**（一手来源：[docs/concepts/memory.md](https://github.com/openclaw/openclaw/blob/main/docs/concepts/memory.md)、[docs/concepts/memory-architecture.md](https://github.com/openclaw/openclaw/blob/main/docs/concepts/memory-architecture.md)、[docs/concepts/memory-search.md](https://github.com/openclaw/openclaw/blob/main/docs/concepts/memory-search.md)）：
- **记忆载体**：纯 Markdown 文件，四层：`USER.md`（稳定偏好，会话开始加载）、`MEMORY.md`（长期记忆，会话开始加载）、`memory/YYYY-MM-DD.md` 每日笔记（工作层，可被 `memory_search`/`memory_get` 索引）、`DREAMS.md`。另有一个 SQLite 索引支撑记忆检索。设计原则第一条即 "No hidden state"——模型只记得写进文件的东西。
- **自动写入**：三路并行——(1) 模型按指令主动写文件（"Remember that I prefer TypeScript"）；(2) 内置 `session-memory` hook 自动写 `memory/YYYY-MM-DD-<slug>.md`；(3) **dreaming 后台周期任务**把每日笔记蒸馏进 `MEMORY.md`（"moves curation off the busy reply path and into a dedicated background pass"）。
- **按需检索/激活**：`memory_search` 工具为混合检索（embeddings + keywords，可本地 llama.cpp / 各云端 embedding provider），由 agent 按需调用；**激活**＝`USER.md`/`MEMORY.md` 每会话开头注入 + 今天/昨天的每日笔记在 `/new` 或 `/reset` 时**自动加载**。
- **异步**：明确实现。架构文档原则 5："Failures never block replies. Every memory step in the reply path has a timeout, a fallback, or both"，固化/蒸馏放在独立后台 pass。
- **热词匹配**：`memory_search` 支持关键词检索（FTS/关键词通道）。

**可借鉴性**：⭐ 六项目中与需求（Markdown 文档记忆 + 自动写入 + 会话开始唤醒 + 异步后台）匹配度最高。Markdown 分层（长期文件 + 日期笔记）、会话开始加载今日/昨日笔记、后台蒸馏——全部可用纯 Dart 复刻（`path_provider` 管文件 + isolate 做后台任务）。依赖平台能力无法移植的部分：agent runtime 本身、lifecycle hooks、embedding provider 生态。

---

## 2. Basic Memory

**仓库地址**：https://github.com/basicmachines-co/basic-memory（3,665★）；官网 https://basicmemory.com，文档 https://docs.basicmemory.com；PyPI 包 `basic-memory`；MCP server。

**成熟度**：高且极活跃——最后推送 2026-08-15，MCP Toplist 上榜，有商业化云服务（Basic Memory Cloud，$15/月，[README 原文](https://github.com/basicmachines-co/basic-memory/blob/main/README.md)）。

**机制分析**（一手来源：[README](https://github.com/basicmachines-co/basic-memory/blob/main/README.md)、[插件 DESIGN.md](https://github.com/basicmachines-co/basic-memory/blob/main/plugins/claude-code/DESIGN.md)、[hooks.json](https://github.com/basicmachines-co/basic-memory/blob/main/plugins/claude-code/hooks/hooks.json)、[session_start.py](https://github.com/basicmachines-co/basic-memory/blob/main/plugins/claude-code/hooks/session_start.py)）：
- **记忆载体**：**Markdown 文件 + frontmatter + observations/wikilinks**，配 SQLite 知识图谱；可选 Postgres+Milvus（向量）。"Your knowledge lives as Markdown files that both you and your AI can read, write, and search"。
- **自动写入**：双通道——(1) MCP 工具（`memory.write` 等）由模型主动调用（同步）；(2) Claude Code 插件 hooks：`SessionStart`（会话开始 briefing）、`PreCompact`（压缩前自动 checkpoint 会话）。另有 opt-in 的 capture output style。
- **按需检索/激活**：`search` 工具为**混合检索（全文 FTS + FastEmbed 向量，可加 cross-encoder 重排）**；`build_context` 按知识图谱邻域导航 `memory://` URLs；**激活**＝`SessionStart` hook 在会话开始时"从知识图谱给 Claude 简报"（timeout 20s，fail-open，绝不断会话）。
- **异步**：**部分**。会话开始激活是同步 hook；写入是模型驱动的 MCP 调用（同步）；README 中唯一明确的"background thread"是遥测上报而非记忆（"Events go to our Umami Cloud on a background thread — never blocks the CLI"）。**没有**"对话进行中后台唤醒注入"或异步写队列。
- **热词匹配**：有，混合检索中的全文通道（matched chunk 会随结果返回）。

**可借鉴性**：⭐ Markdown 文件 + 知识图谱（wikilink/observation）概念、SessionStart briefing（= 手机端 app 启动时异步加载相关文档）值得借鉴；MCP 与 Claude Code 插件 hooks 无法移植，但"会话开始注入 + 压缩前 checkpoint"可复刻为 app 内事件钩子（会话开始/长会话归档）。

---

## 3. memory-bank（定位结果：无单一权威仓库）

**定位结论**：GitHub 上 "Claude Code memory bank" 是一类**方法论项目**，没有唯一 canonical 仓库。搜索结果按 star 排序的代表：
- **hudrazine/claude-code-memory-bank**（40★，最后推送 2025-07-27，已停更约一年）：https://github.com/hudrazine/claude-code-memory-bank —— 基于 [Cline Memory Bank](https://docs.cline.bot/prompting/cline-memory-bank) 方法论改造，最贴合"claude-code memory bank 类项目"这个描述
- russbeye/claude-memory-bank（19★，2025-09-28 停更）：https://github.com/russbeye/claude-memory-bank
- pmikutel/directed-memory-bank（5★，TypeScript，2026-07-20 有更新）：https://github.com/pmikutel/directed-memory-bank
- diaz3618/memory-bank-mcp（1★，MCP 版，2026-03 停更）：https://github.com/diaz3618/memory-bank-mcp

**机制分析**（以 hudrazine 为代表，[README](https://github.com/hudrazine/claude-code-memory-bank/blob/main/README.md)）：
- **记忆载体**：纯 Markdown 层级文件：`projectbrief.md → productContext.md / systemPatterns.md / techContext.md → activeContext.md → progress.md`，存在仓库内、可 git 追踪。
- **自动写入**：**无 hooks**。靠 CLAUDE.md `@import` 加载指令 + `/workflow:update-memory` 等 slash command，由模型主动写文件——纯手动/模型自觉驱动。
- **按需检索**：**无搜索机制**。整个 bank 通过 `@import` 静态全量加载进上下文。
- **激活/异步**：均无。每次会话全量静态加载，无后台任务。
- **热词匹配**：无。

**可借鉴性**：文件层级组织（brief/context/patterns/progress 分离）与"启动时加载"思想可借鉴；但机制上是最弱的一类——无自动写入、无检索、无异步。`@import` 是 Claude Code 专有能力，Dart 端需自行实现"启动时读文件拼接上下文"。

---

## 4. claude-memory-fts（npm 包）

**仓库地址**：npm 包 https://www.npmjs.com/package/claude-memory-fts（v2.0.1，2026-03-13 发布，2026-04-11 最后更新）；源码 https://github.com/kurovu146/claude-memory-mcp（**0★**，TypeScript，最后推送 2026-04-11）。

**成熟度**：低。作者个人项目（kurovu146 / Vu Duc Tuan），0 star、单维护者、已 4 个月无更新；npm 侧功能完整（v2.0.1）。

**机制分析**（一手来源：[npm README](https://www.npmjs.com/package/claude-memory-fts)、[src/index.ts](https://github.com/kurovu146/claude-memory-mcp/blob/main/src/index.ts)、[src/repository.ts](https://github.com/kurovu146/claude-memory-mcp/blob/main/src/repository.ts)）：
- **记忆载体**：**SQLite**（`~/.claude/memory.db` 的 `memory_facts` 表，含 FTS5 虚拟表 + 向量列），**非 Markdown**。
- **自动写入**：**无自动 hook 写**。`memory_save` MCP 工具由模型主动调用；`--setup-hook` 只配置注入 hook，不自动采集。
- **按需检索**：`memory_search` 工具＝**混合检索（FTS5 关键词 + all-MiniLM-L6-v2 语义向量，RRF 融合，LIKE 兜底）**。
- **激活**：`UserPromptSubmit` hook 把 **top-30 重要记忆注入每次 prompt**——注意这是**静态注入**（按访问频率+recency 衰减排序，每次全量注入 top30），不是按当前对话内容动态唤醒。
- **异步**：**无**。源码显示 `saveFact` 内联 `await generateEmbedding(fact)`（写路径同步算向量）；注入 hook 同步执行。
- **热词匹配**：有 FTS5 关键词通道 + LIKE 兜底，但注入是静态 top-30 而非热词驱动。

**可借鉴性**：⭐ "FTS5 关键词 + 语义向量 + RRF 融合"的混合检索架构与"重要性排序（访问频率 × 时间衰减 × 类别权重）"思路很适合移植到 Dart（sqflite FTS5）；但 SQLite 非 Markdown、无异步、MCP/hooks 依赖 Claude Code 生态。

---

## 5. PMB / pmb-ai

**仓库地址**：https://github.com/oleksiijko/pmb（289★，Python，2026-05-25 创建，最后推送 2026-08-10，活跃）；PyPI 包 `pmb-ai`；官网 https://pmbai.dev，文档 https://docs.pmbai.dev。

**成熟度**：中低但**正在活跃开发**。自述定位"beats mem0/Letta/Zep on retrieval"（[PyPI 页](https://pypi.org/project/pmb-ai/)），有 LoCoMo recall@10 94.5% / p50 70ms 的评测宣传（[HackerNoon 报道](https://hackernoon.com/how-i-built-local-first-memory-for-claude-code-cursor-and-codex-945percent-locomo-recall10-70ms-p50)）。

**机制分析**（一手来源：[README "How it works" / "Hooks" / "Ambient memory" 章节](https://github.com/oleksiijko/pmb/blob/main/README.md)）：
- **记忆载体**：**SQLite 为准（source of truth）+ LanceDB 向量索引**，工作区在本地磁盘；另有可选的 `.pmb/resume.md`（Markdown）。**主载体不是 Markdown 文件**。
- **自动写入**：⭐ 三层 hooks（`pmb hooks install claude-code`，"force-feed PMB at the protocol level - no model cooperation"）：
  - `PostToolUse` → ambient observe：每次工具调用追加轻量 action journal（单条 SQLite INSERT，**无模型参与**）；
  - `Stop` → follow-through + **ambient auto-write**：确定性检查已浮现的教训是否被落实；若模型本回合没调用 `record_*` 工具，自动合成一条活动记录（模板合成，瞬时完成，可配 LLM 摘要并超时回退）；
  - `UserPromptSubmit` → **auto-recall**：每条消息先做 regex 分类（multilingual、sub-ms），把匹配的记忆（教训、历史决策、召回命中、项目概览）在模型思考**之前**注入，琐碎消息不注入。
- **按需检索**：recall = **BM25 + dense vector + entity graph + 可选 cross-encoder rerank，RRF 融合**，p50 35ms，**读路径无 LLM 调用**；`pmb recall` CLI 可手动搜。
- **激活**：`SessionStart` → session-restore（压缩后重建"上次进行到哪"）；每消息 auto-recall 注入（真正的"对话进行中热词唤醒"）。
- **异步**：⭐ **写入明确异步**——"The MCP tool returns in under a millisecond; the embed + LanceDB insert happen on a background thread"（SQLite 先写、向量后补，异步嵌入队列）；召回是同步但 sub-ms 级。
- **热词匹配**：⭐ 每消息 regex 分类（sub-ms、无模型）就是典型热词匹配实现。

**可借鉴性**：⭐ 六项目中**异步与热词召回机制最贴近需求**：异步写队列（先落 SQLite 再后台算向量）、每消息 regex 热词分类 + 注入、ambient observe（无模型参与的自动采集）。Python 实现本身不能搬到 Dart，但"写队列 + isolate 后台嵌入 + regex 分类器"三个机制在 Dart 里都有直接对应物。注意载体是 SQLite+LanceDB 而非 Markdown，若坚持"Markdown 文档记忆"需自行改造。

---

## 6. ErebusEnigma/context-memory

**仓库地址**：https://github.com/ErebusEnigma/context-memory（**5★**，Python，最后推送 2026-02-17，约半年停滞）。

**成熟度**：低。5 star、单作者、有 CI/测试（README 自称 364 passing tests）但已 6 个月无提交。

**机制分析**（一手来源：[README](https://github.com/ErebusEnigma/context-memory/blob/main/README.md)、[hooks/hooks.json](https://github.com/ErebusEnigma/context-memory/blob/main/hooks/hooks.json)）：
- **记忆载体**：**SQLite**（`~/.claude/context-memory/context.db`，sessions/summaries/topics/messages/code_snippets/context_checkpoints 表），**非 Markdown**。
- **自动写入**：两个 hooks——`Stop` hook（`auto_save.py`：读 Claude Code stdin 的 JSONL transcript，**head+tail 采样**（前5条+后10条）自动保存会话摘要，带 git 分支 topic 与去重窗口）＋ `PreCompact` hook（压缩前保存完整 checkpoint，schema v4）。另有 `/remember` slash command（模型生成结构化摘要）。
- **按需检索**：`/recall` slash command 或 MCP `context_search` 工具＝**FTS5 + BM25 关键词搜索（Porter stemming，"running" 能匹配 "run"）**，两档（tier1 <10ms 摘要级、tier2 <50ms 深取消息/代码），**纯关键词、无向量**。
- **激活**：**无**。只有 Stop/PreCompact 两个 hook，**没有 SessionStart**——不做会话开始注入，纯按需 `/recall`。
- **异步**：**部分**。写入 hooks 在会话结束/压缩前运行（脱离主对话循环，相当于"事后后台"），但检索是同步的；没有对话中后台唤醒。
- **热词匹配**：✓ 纯 FTS5 关键词（Porter stemming），是六项目里最纯粹的"热词搜索"实现。

**可借鉴性**：Stop-hook 自动保存 + head+tail 采样（省 token 的摘要策略）、FTS5 BM25 + Porter stemming 热词搜索、PreCompact checkpoint——思路都可复刻到 Dart；Python + Claude Code hooks 依赖无法移植。

---

## 小结：谁真正实现了"Markdown 文档记忆 + 自动写入 + 异步按需检索激活"组合

| 项目 | 载体=Markdown | 自动写入 | 异步 | 会话开始/进行中唤醒激活 | 热词搜索 | 成熟度 |
|---|---|---|---|---|---|---|
| **OpenClaw**（原 Clawdbot） | ✅ 文件分层（MEMORY.md+每日笔记） | ✅ 模型+hook+dreaming 后台 | ✅ 后台固化，绝不阻塞回复 | ✅ 会话开始加载今日/昨日笔记 + 按需 memory_search | ✅ 关键词+向量混合 | 386k★ 极活跃 |
| **Basic Memory** | ✅ Markdown+知识图谱 | ✅ MCP+SessionStart/PreCompact hooks | ⚠️ 部分（写入/激活均同步） | ✅ SessionStart 简报 | ✅ 全文+向量混合 | 3,665★ 极活跃 |
| **PMB** | ⚠️ 否（SQLite+LanceDB，resume.md 可选） | ✅ 三层 hooks 无模型自动采集 | ✅ 写入异步（后台嵌入队列） | ✅ 每消息 auto-recall + SessionStart 恢复 | ✅ regex 热词+BM25 | 289★ 活跃 |
| **claude-memory-fts** | ❌ SQLite | ⚠️ 仅模型主动调工具 | ❌ 同步 | ⚠️ 静态 top-30 注入（非按需） | ✅ FTS5+语义 RRF | 0★ 停滞 |
| **context-memory** | ❌ SQLite | ✅ Stop/PreCompact hooks | ⚠️ 部分（事后 hooks） | ❌ 无激活 | ✅ 纯 FTS5 BM25 | 5★ 停滞 |
| **memory-bank 类** | ✅ 纯 Markdown | ❌ 仅模型手动 | ❌ | ❌ 全量静态加载 | ❌ 无 | ≤40★ 多已停更 |

**结论**：真正同时满足"Markdown 文档记忆 + 自动写入 + 异步按需检索激活"的只有 **OpenClaw（原 Clawdbot）**，且它成熟度最高（386k★ 极活跃）——但它不是 Claude Code 插件，而是完整 agent 平台；**Basic Memory** 满足 Markdown + 自动写入 + 会话开始激活，但写入/激活是同步的，且是 MCP/插件形态；**PMB** 在异步与热词召回上最强，但主载体不是 Markdown。

**对 Flutter 纯 Dart 手机端复刻的落地建议**：组合三者——① 用 OpenClaw 的分层 Markdown 记忆（MEMORY.md + 日期笔记）与"会话开始加载今日/昨日笔记"；② 用 Basic Memory 的"会话开始 briefing + 长会话 checkpoint"作为 app 内事件钩子；③ 用 PMB 的"异步写队列（先落盘、后台 isolate 算索引/向量）+ 每消息 regex 热词分类召回"。热词搜索在 Dart 端可直接用 SQLite FTS5（`sqflite_common_ffi` + `sqlite3_flutter_libs` 内置 FTS5），或自建简化倒排索引；异步用 `Isolate`/`compute`。Claude Code 专有能力（hooks、MCP、CLAUDE.md `@import`、slash commands、plugin marketplace）无法直接移植，需在 app 内自建等价的事件钩子（会话开始 / 每轮消息 / 会话结束 / 后台定时蒸馏）。
