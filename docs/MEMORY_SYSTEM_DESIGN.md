# MIX 记忆子系统升级设计 v4（终版：记忆网 + 通用置信度引擎 + Agent 层升级）

> 状态：**设计稿，未实施**。调研（2026-08-16）全部闭环，报告见 `docs/research/`（记忆对标 / Claude 插件 / 搜索引擎 / 分词词库）。
> 核心洞察（旅行者 2026-08，多轮讨论收敛）：
> 1. **建构端盲区**：扩散激活只在检索端（pull），建构端只有"聊天记录 + 硬编码画像"，**没有图可走** → 确定性图建构（自动标签 + 共现 + 知识层级 + Hebbian），写路径零 LLM。
> 2. **图不交给 AI 自觉**：从使用数据统计长出来，热词污染用 BM25 饱和 + 黑名单 + IDF 门槛挡住。
> 3. **画像分层**：静态基线卡（冻结快照兜底）+ 动态状态（数据源/图检索按需），预算/阈值/决策点防过量注入。
> 4. **摘要层**：LLM 读取不白费——激活即总结，snippet 模式注入，图管"哪些相关"、摘要管"内容是什么"。
> 5. **通用置信度引擎（本版核心抽象）**：检索痕迹 + 推导层不是服务学习引擎的附件，而是**通用的置信度机制**——给每个记忆对象（文档/标签/知识点/事实/偏好条目）计算可靠度，统一服务：注入决策、排序加权、画像可靠性、学习状态描绘、记忆对账。学习引擎的 BKT 只是它在"掌握度"上的特例。
> 6. **Agent 层升级**：DSH 启示 1-5（Goal 系统 / 异步委派 / 工具结果裁剪 / 技能目录注入 / 记忆时点对账）融入记忆系统，目标："副业干过主业"——记忆系统作为记忆系统，其自然副产品描绘学习状态的能力超过学习引擎的显式画像。

---

## 1. 总体目标

把 MIX 的记忆从「两个硬编码 bucket + 会话记录」升级为三层咬合的完整系统：

```
┌─ 记忆子系统（记忆网）──────────────────────────────────┐
│  多记忆文档（printnotes 共用）+ 确定性图建构（自动标签/    │
│  共现/相似度/知识层级/Hebbian）→ 热词检索 → 扩散激活 →    │
│  摘要优先注入 → 预算裁剪 → 决策点注入                       │
└──────────────────────────────────────────────────────┘
┌─ 通用置信度引擎（可靠度）──────────────────────────────┐
│  痕迹层（检索/激活/采纳/时间，确定性记录）                 │
│  推导层（Beta 置信度 + 遗忘衰减 + 可提取性）               │
│  → 注入决策 / 排序加权 / 画像可靠性 / 学习描绘 / 对账触发   │
└──────────────────────────────────────────────────────┘
┌─ Agent 层升级（DSH 启示 1-5）─────────────────────────┐
│  Goal 系统（持久目标+自动续跑）/ 异步委派生命周期          │
│  工具结果裁剪（pruner）/ 技能目录会话注入 / 记忆时点对账     │
└──────────────────────────────────────────────────────┘
```

原则：全部纯 Dart / SQLite；写路径零 LLM（LLM 只在"回合后沉淀判断 + 摘要生成"）；不引入 embedding/向量库/服务器/JS 运行时。

## 2. 调研结论摘要（全部闭环，报告见 docs/research/）

| 维度 | 结论 | 蓝本 |
|---|---|---|
| 一站式方案 | 不存在——"异步激活+热词+多文档图+摘要"无单一开源项目做完 | 拼装态 |
| 异步骨架 | 成熟：prefetch 有界等待 8s + 围栏注入 + 单 worker 保序写 + 下一轮预热 | **Hermes memory_manager** |
| 潜意识观察 | 后台观察会话 + 4 注入点，注入当前轮 user message 保 prefix cache | claude-subconscious、Hermes Issue #553 |
| 热词检索 | FTS5 `bm25()` + OR 连接 + min-max 归一化 + 加权融合 | Gentleman-Programming/engram（6012★）、TAIPANBOX/engram |
| 扩散激活 | 检索时 pull 式 2 跳 BFS 图游走（每跳 ×0.5 衰减） | TAIPANBOX/engram `graph.py` |
| 建构端图化 | 空白（本设计自研） | 自动标签 + 共现 + 知识层级 + Hebbian |
| 分词与词库 | jieba（dict+idf+HMM 全 MIT）+ dart_jieba（纯 Dart 1.9MB）；THUOCL 领域词 | fxsjy/jieba、dart_jieba |
| 热词提取 | TF-IDF（idf 表 + median_idf 兜底）+ 中文黑名单 + IDF 门槛 + BM25 饱和 | jieba extract_tags、scikit-learn max_df |
| 标签推荐 | 稀疏共现矩阵 cosine/Jaccard top-k（25-50 即达 96-98%）；FolkRank 差分压制高频标签 | ItemCF（Sarwar 2001）、Jäschke 2007 |
| 摘要层 | 两级存储（原文权威 + 摘要导航），激活后异步总结 | OpenClaw dreaming、claude-subconscious Stop hook |
| 搜索引擎 | 该抄：BM25 参数/分段合并节奏/前缀搜索/同义词 OR 展开/typo 词长分级/fast field 二次排序；自研仅查询体验层五块 | Tantivy、Meilisearch、MiniSearch |
| 置信度建模 | Beta-Binomial 置信度 + 遗忘衰减 + retrievability（Bjork） | BKT（Corbett & Anderson 1995）、ACT-R |
| DSH 1-5 | Goal 持久化 / 异步委派 / pruner / 技能目录注入 / 时点对账 | DeepSeek Harness 架构 |

**⚠️ FTS5 工程风险**：AOSP 证实 Android 系统 SQLite 从未启用 FTS5（只启 FTS3/FTS4）——sqflite 走系统库，**FTS5 可用性因设备而异**。方案 A（推荐）：会话库迁移 `sqlite3` 3.x（自带 SQLite、默认含 `SQLITE_ENABLE_FTS5`）；方案 B：保持 sqflite + FTS5 探测 + LIKE 降级 + 纯 Dart 倒排兜底。**P0 第一件事：真机验证 FTS5**。

## 3. 数据层设计（新增表，沿用 sqflite 会话库）

```sql
-- 记忆文档索引：notes 库内被标记为"记忆文档"的文件
CREATE TABLE IF NOT EXISTS memory_docs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT UNIQUE NOT NULL,          -- 相对 notes 根目录
  title TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'memory', -- memory|user|daily|topic|note
  mtime INTEGER NOT NULL,
  frozen_snapshot TEXT,               -- 冻结快照（系统提示注入用）
  importance REAL NOT NULL DEFAULT 0.5
);

-- 自动标签：热词提取产物，一对多衔接
CREATE TABLE IF NOT EXISTS memory_tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  doc_id INTEGER NOT NULL REFERENCES memory_docs(id),
  tag TEXT NOT NULL,                  -- 已归一化（别名归并）
  score REAL NOT NULL,
  UNIQUE(doc_id, tag)
);

-- 文档间关联边（图）：标签/相似/知识层级/共现/wiki
CREATE TABLE IF NOT EXISTS memory_links (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  src INTEGER NOT NULL REFERENCES memory_docs(id),
  dst INTEGER NOT NULL REFERENCES memory_docs(id),
  kind TEXT NOT NULL DEFAULT 'tag',   -- tag|similar|knowledge|cooccur|wiki
  weight REAL NOT NULL DEFAULT 1.0,   -- Hebbian：共访问/采纳强化
  UNIQUE(src, dst, kind)
);

-- 摘要层（snippet 导航，不覆盖原文/不进索引/不参与排序）
CREATE TABLE IF NOT EXISTS memory_doc_summaries (
  doc_id INTEGER PRIMARY KEY REFERENCES memory_docs(id),
  summary TEXT NOT NULL,              -- ≤100 字
  doc_mtime INTEGER NOT NULL,         -- 变更即 stale
  updated_at INTEGER NOT NULL
);

-- 通用置信度引擎：痕迹层（检索/激活/采纳事件流）
CREATE TABLE IF NOT EXISTS memory_evidence (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  obj_type TEXT NOT NULL,             -- doc|tag|knowledge|fact|goal
  obj_id INTEGER NOT NULL,
  evidence TEXT NOT NULL,             -- hit|miss|activated|adopted|rejected|correct|wrong|verified|stale
  ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_evidence_obj ON memory_evidence(obj_type, obj_id);

-- Goal 系统（DSH 启示 1）：持久目标 + 自动续跑
CREATE TABLE IF NOT EXISTS goals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  objective TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1, -- 乐观锁
  phase TEXT NOT NULL DEFAULT 'active',-- active|paused|blocked|done
  rounds INTEGER NOT NULL DEFAULT 0,   -- 已续跑轮次
  max_rounds INTEGER,
  blocked_reason TEXT,
  evidence_obj TEXT,                  -- 关联证据对象（如 knowledge:id），进度由此推导
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- 异步委派（DSH 启示 2，Hermes async_delegations 表补全）
CREATE TABLE IF NOT EXISTS async_delegations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_session_id INTEGER NOT NULL,
  task TEXT NOT NULL,
  model TEXT,
  status TEXT NOT NULL DEFAULT 'running', -- running|done|failed|cancelled
  result TEXT,
  created_at INTEGER NOT NULL,
  finished_at INTEGER
);

-- 全文检索：external-content FTS5（unicode61；中文 dart_jieba 预分词后喂入）
CREATE VIRTUAL TABLE IF NOT EXISTS memory_docs_fts USING fts5(
  title, content, tags,
  content='memory_docs', content_rowid='id'
);
-- + INSERT/UPDATE/DELETE 触发器（照抄 messages_fts 触发器模式）
-- + 不可用时 LIKE 降级（照抄 session_search 模式）
```

**与学习图谱融合**：`study_engine` 的 `subjects→knowledge_points→questions→practice_records` 四级外键树是人工确定的骨架；文档出现知识点名（含别名归并，`fuzzy_match.dart`）→ `memory_links(kind='knowledge')` 连边；扩散沿层级走。**MIX 独有的确定图谱**。

## 4. 确定性图建构（写路径零 LLM）

**图不交给任何"人"画，从使用数据统计长出来。** 五类边：

| # | 边类型 | 生成机制 | 依赖 |
|---|---|---|---|
| 1 | 自动标签边（主力） | 写入时分词 → BM25 饱和词频 → 热词 top-k（默认 5）→ 黑名单 + IDF 门槛 → 归一化 → 写 tags；同标签文档互连 | dart_jieba + idf.txt + 停用词 |
| 2 | 相似度边 | 词袋重叠余弦 > 阈值；插入时只与共享 ≥2 词候选比，每文档 top-k（默认 8） | 词频向量（无 embedding） |
| 3 | 知识层级边 | 知识点名（含别名）出现在文档 → 连边，扩散沿层级走 | study_engine |
| 4 | 共现边 | 同一对话/同一批练习共同出现的文档/标签 → 连边，权重=共现次数 | 会话/练习数据 |
| 5 | Hebbian 反馈边（查询时） | 命中 A、扩散带出 B、B 被采纳 → A-B 边权 +1 | 检索日志 |

**写入管线**（后台 isolate）：`分词 → BM25饱和词频 → 热词top-k → 自动标签 → 倒排更新 → 标签边 → 候选相似度边 → 知识点匹配边 → 落盘`。标签推荐实现：稀疏共现矩阵 + 对称 cosine/Jaccard（不对称的条件概率不能建无向边）+ 每行 top-k（25-50）+ 阈值建边（Jaccard 0.05-0.2 或共现 ≥3）；需要多跳传播时切 PPR + FolkRank 差分（w=w₁−w₀ 压制高频"万金油"标签）。

## 5. 检索端：热词种子 → 图扩散 → 摘要优先 → 预算 → 注入

1. 热词定位种子：FTS5 `bm25()` + OR 连接（长问题召回归零的坑）+ 专有名词 IDF boost（×1.5）。
2. 图扩散：种子 top-k（默认 5）→ 沿 links 2 跳 BFS，每跳衰减 `decay(0.5) × min(边权, 1.0)`；排序 `α·bm25 + β·激活 + γ·importance`（importance 来自置信度引擎 §6）。
3. 摘要优先：有摘要且未 stale → 注入摘要（标注"LLM 生成，可能遗漏原文"），全文由 `memory_read` 按需读。
4. 预算裁剪：默认 1500 tokens（przm 细节）。
5. 门控：可靠度/分数不达阈值 → **不注入**（宁可缺，不可杂，fail-closed；基线卡兜底）；trivial-prompt 跳过。
6. 注入格式：`<memory-context>` 围栏注入**当前轮 user message**，不进 system prompt（保 prefix cache，Hermes 范式）。
7. 决策点注入：平时不注入，只在用户提问后/PreToolUse 注入（claude-subconscious 模式）。

## 6. 通用置信度引擎（本版核心抽象）

**不是服务学习引擎的附件，是通用的可靠度机制。** 学习引擎的 BKT 只是它在"掌握度"上的特例。

### 6.1 痕迹层（确定性记录，检索/激活/作答路径顺手写，零成本）

`memory_evidence` 事件：`hit`（检索命中并采纳）/ `miss`（检索无果）/ `activated`（被扩散激活）/ `adopted`（注入被模型采纳）/ `rejected`（注入被忽略或用户纠正）/ `correct` / `wrong`（作答）/ `verified`（对账确认）/ `stale`（发现过时）。每个记忆对象（文档/标签/知识点/事实/goal）都有事件流。

### 6.2 推导层（确定性统计，零 LLM）

对每个记忆对象 O，从事件流推导：

- **置信度** = Beta-Binomial 后验均值 `(p+1)/(p+n+2)`（p=正证据：hit/adopted/correct/verified；n=负证据：miss/rejected/wrong/stale；拉普拉斯平滑；样本量小时置信度自动保守）。
- **新鲜度** = 遗忘衰减 `exp(-Δt/τ)`（或 ACT-R `Σt^(-d)`，τ 按对象类型：事实长、偏好中、学习状态短）。
- **可提取性**（retrievability，Bjork）= 最近激活成功率 × 新鲜度——记忆系统直接测"提取不提取得出来"，比测验代理测量本质更准。
- **综合可靠度** = f(置信度, 新鲜度, importance)。

### 6.3 应用矩阵（统一服务全系统）

| 应用 | 机制 |
|---|---|
| 注入决策 | 可靠度低于阈值 → 不注入或标注"可能过时"（§5 门控的量化依据） |
| 排序加权 | `γ·importance` 用可靠度调制：高可靠记忆优先注入 |
| 画像可靠性 | 用户偏好条目 = 带可靠度的证据对象；3 个月前记的偏好 vs 本周验证的偏好权重不同 |
| **学习状态描绘**（副业干过主业） | 知识点可靠度 = 掌握度信号：反复 miss/重试 = 难点，一次命中即走 = 掌握，长未激活 = 遗忘中。**BKT 是其特例**（作答即检索验证的一种） |
| **记忆对账触发**（DSH 启示 5） | 可靠度低 + 引用外部状态（GitHub/服务器/进度）的记忆 → 检索/引用前触发 verify 对账 |
| 摘要 stale 判断 | 文档 mtime 变更 + 可靠度下降 → 标记重生成 |
| Goal 进度证据 | goal 关联证据对象（§7.1），进度 = 该对象可靠度/可提取性演化 |

**与学习引擎的关系不是合并，是取代**：学习状态描绘完全来自记忆系统自然副产品（检索/激活/沉淀/遗忘节律），无侵入式学习分析；做题退化为"校准信号"（`correct/wrong` 事件偶尔验证隐式推断）。`0_profile.md` 从"维护的文档"变成"从证据推导的投影缓存"。

## 7. Agent 层升级（DSH 启示 1-5 融入）

### 7.1 Goal 系统（启示 1：持久目标 + 自动续跑）
- `goals` 表 + 主循环外挂 goal driver：会话开始检查活跃 goal → 自动续跑 → 每轮结束记录进度（revision 乐观锁、pause/resume/blocked 语义、轮次预算）。
- **与记忆系统咬合**：goal 的进度由**证据推导**（evidence_obj 关联知识点/主题文档），不是自报——"掌握线代第二章"的进度 = 该知识点相关记忆的可靠度/可提取性演化。记忆痕迹即 goal 证据，goal 驱动"长期学习目标"（跨会话自动续跑，替代一次性对话任务）。

### 7.2 异步委派生命周期（启示 2）
- `async_delegations` 表（Hermes 有这张表，MIX `session_db.dart` 注释里预留了但未实现）。
- `delegate_task` 改异步：派发立即返回 → 后台 isolate 跑 → 完成通知（本地通知/UI 事件）→ 对话可续（手机端对应 send_message：派发后可追加指令）→ 中断只停当前轮。
- 与记忆异步骨架（prefetch/sync/摘要生成）**共用 isolate 池**，一套基础设施。
- 手机场景收益：后台出题/教材分析不阻塞聊天，完成推送通知。

### 7.3 工具结果裁剪独立化（启示 3）
- **pruner 层**：所有工具输出先确定性裁剪（大 JSON→统计摘要、大文件→头部+行数、长日志→关键行），裁剪不够才 LLM 摘要——先裁剪后压缩，省 token 省延迟。
- 记忆注入的摘要层（§5.3）就是这个思想的记忆版；与现有 `context_compressor` 配合（裁剪在前，LLM 压缩兜底）。

### 7.4 技能目录会话注入（启示 4）
- MIX 已有 `skills_list/skill_view/skill_manage`（渐进式披露），补 DSH 的做法：**会话开场把技能目录摘要（名+一句话）并入 volatile 系统提示层**，agent 主动判断该加载哪个技能——避免"想不起来有这技能"。
- 与记忆注入**共用 volatile 注入管线**（都是"开场/按需注入、不进 stable 层、保 prefix cache"）。

### 7.5 记忆时点快照对账（启示 5）
- 原则：记忆是时点快照，涉及外部状态先核实再引用。
- 由置信度引擎驱动：**可靠度低 + 引用外部状态**的记忆 → 引用前触发 verify（GitHub API / 服务器 ping / `practice_records` 查询 / 文件 mtime）。
- 对账结果写入 `verified`/`stale` 证据 → 更新可靠度 → 形成"越用越可信"闭环。与 refine 管线配合：对账发现过时 → 提议更新（用户批准后应用）。

## 8. 画像分层：缓存层 + 检索层

| 层 | 内容 | 注入策略 |
|---|---|---|
| A. 静态基线卡 | 身份/铁律/长期偏好（冻结快照，几十条） | **每轮注入**（兜底不失忆；高确定信息不允许 LLM 转述失真，不走摘要） |
| B. 动态状态 | 学习进度/近期状态/临时偏好 | **数据源直查 + 图检索 + 置信度引擎**，决策点注入（不冗余） |

动态状态从画像文件解放：学习进度 = 知识点可靠度（§6.3 学习描绘，实时推导）；近期状态 = 记忆文档网按需检索。**"取代画像"的正确含义 = 静态缩成最小卡片 + 动态交给证据推导**。互补演进：证据越足，基线卡可越缩越小；基线卡永远兜底。

## 9. 摘要层（激活即总结，两级存储）

- 时机：回合结束 → 门控（实质内容才触发）→ 后台 isolate 用 fast_model 审阅 → 产出"该写什么" → 走确定性写入管线。
- 摘要生成：本次会话**激活过/读取过**的文档或长聊天片段 → ≤100 字写 `memory_doc_summaries`。只总结"被激活"内容，成本可控。
- 边界：基线卡不走摘要；mtime 变更 → stale → 空闲重生成；与上下文压缩互补（压缩管对话内，摘要管档案层）。

## 10. 异步骨架（对齐 Hermes prefetch/sync 范式）

| 时机 | 动作 | Dart 实现 |
|---|---|---|
| 每轮前 | prefetch：后台 isolate 检索+激活，主线程 `Future.timeout(8s)` 有界等待，超时跳过 | `Isolate.run` + `.timeout` |
| 门控 | trivial-prompt 跳过 prefetch | 现成正则 |
| 回合后 | sync：记忆落盘 + 建索引 + 摘要生成 + 证据写入，单串行队列保序 | `Isolate.run` 串行化 |
| 下一轮 | queue_prefetch 预热 + 缓存 | 后台任务 |
| App 空闲 | 定期整理：importance 衰减、相似度边批量补算、stale 摘要重生成、goal 进度推导、对账 | 现有 cron |

## 11. 中文方案与数据资产（全 MIT/Apache 可商用）

**分词：直接用 `dart_jieba`**（纯 Dart、零依赖、MIT、词典 1.9MB、HMM 与 Python 一致）。风险：单作者新项目 → 集成时自建回归测试；坑：Flutter assets 不能 `File` 读，需 `rootBundle.load` + `FlatTrie.fromBytes` patch。备选自研（前缀词典→DAG→最大概率 DP→HMM Viterbi，2-4 周）。

| 资产 | 大小 | 用途 | 许可 |
|---|---|---|---|
| jieba dict.txt（或 dart_jieba dict.dgz） | 5.07MB / 1.9MB | 分词主词典 + 中文词频表 | MIT |
| jieba idf.txt | 6.2MB | 热词权重表（median_idf 兜底） | MIT |
| jieba HMM 三表 | 1.3MB | 未登录词识别 | MIT |
| THUOCL 2-4 类（IT/医学/法律/成语） | 每类 2-60KB | 领域词典 | MIT + README 明示可商用 |
| 中文停用词（自清洗精简版） | 1-2KB | 热词黑名单 | 自清洗 |
| MIT 版权声明 | - | MIT 要求保留 | - |

**避开**：搜狗 scel（版权）、腾讯词向量（6GB）、YAKE 官方代码（AGPL-3.0）、jieba_flutter（GPL-3.0）。

**防热词污染**（业界标准）：黑名单 + IDF 门槛（scikit-learn `max_df` 同思路）+ BM25 TF 饱和（k1≈1.5, b≈0.75，重复 1000 次与 50 次贡献几乎相同）+ 连续重复去重 + 位置权重。

## 12. 搜索引擎管线映射（嵌入式调研已闭环）

经典管线：采集 → 分词 → 倒排 → 加权 → 检索 → 排序 → 扩展。MIX 映射：笔记库+会话=采集；dart_jieba=分词；FTS5=倒排+BM25；自动标签+Hebbian=排序扩展；标签图+PPR=推荐；摘要层=snippet。**每层有开源蓝本，真正自研只有"图建构 + 注入时机 + 置信度引擎"三层。**

该抄 8 项：BM25 参数 k1=1.2/b=0.75（FTS5 内置）、分段写入+定期 optimize 合并（对应写入增量+cron 批量）、末词前缀搜索（FTS5 `term*`）、同义词查询时 OR 展开（Meilisearch 实证，别名表查询时展开"线代/线性代数"）、typo 容错=排序加分+词长分级（1-4 字 0 错/5-8 字 1 错/≥9 字 2 错）、fast field 二次排序（importance/可靠度正是 fast field）、查询语法、分词管线化。不抄：FST/bitpacking/mmap/WAND/skip list（大索引优化，个人库量级用不上）。纯 Dart 无现成倒排引擎，FFI 方案与铁律冲突不采用。

## 13. 整合边界与新增工具

| 模块 | 改动 |
|---|---|
| `tools/memory_tool.dart` | 保留冻结快照 + 容量上限兼容层；新增"写入时定位挂载"路径 |
| `tools/memory_manager.dart` | `prefetchAll(query)` 实现真检索（注释已留"query 保留用于未来检索实现"） |
| `db/session_db.dart` | §3 十张表 + 触发器 + FTS（注释已预留 "cjk-bigram 索引 / fts 后台重建"） |
| `printnotes/` | `documents/notes/memory/` 目录约定；wiki 链接解析器复用 |
| `services/study_engine.dart` | 知识点表并入 memory_links + 证据流（correct/wrong 事件） |
| `tools/notes_tools.dart` | notes_search 与 memory_docs_fts 共用索引 |
| 新工具 | `memory_search` / `memory_read`（检索+读全文/摘要）、`memory_verify`（对账）、`goal` 工具组（DSH 式）、`evidence_log`（调试/展示） |
| 新服务 | 置信度推导（Beta 更新 + 衰减）、goal driver、异步委派执行器 |
| isolate | 复用"阻塞重活丢 Isolate.run"模式（HANDOFF 踩坑：只传 primitive、进度回调留主 isolate） |
| 新依赖 | `dart_jieba`（分词）；数据资产进 assets/ |

## 14. 分阶段实施计划

- **P0（检索端，独立可交付）**：§3 核心表 + dart_jieba 集成 + 词库资产 + **真机 FTS5 验证**（§2 风险） + FTS 热词检索 + `memory_search`/`memory_read` + `prefetchAll` 真实现。验收：热词搜到任意主题记忆文档，中文有效。
- **P1（确定性图建构 + 置信度引擎）**：自动标签管线 + 相似度/知识层级边 + 扩散激活 + 证据层（hit/miss/activated/adopted）+ Beta 置信度推导 + 注入门控。验收：文档网随写入生长，扩散带出跨词关联，可靠度影响注入。
- **P2（异步 + 摘要）**：异步骨架（prefetch 有界/单 worker 保序/预热）+ 摘要层（回合后 fast_model 总结 + snippet 注入）+ 决策点注入。验收：长记忆以摘要注入，读全文才耗大 token。
- **P3（Agent 层，DSH 1-5）**：Goal 系统（证据驱动进度）+ 异步委派（async_delegations）+ 工具结果 pruner + 技能目录会话注入 + 记忆时点对账（verify 工具 + 可靠度触发）。验收：跨会话学习目标自动续跑，记忆引用前自动对账。
- **P4（学习描绘落地 + 校准）**：`0_profile.md` 迁移为证据推导投影 + 学习状态描绘上线（可提取性/难点/遗忘节律）+ 做题作校准信号（correct/wrong 事件）。验收：记忆系统对学习状态的描绘取代学习模式画像，做题仅作验证。

## 15. 蓝本与锚定

| 蓝本 | 用途 |
|---|---|
| Hermes `agent/memory_manager.py` + `turn_context.py` | 异步骨架、围栏注入、门控、单 worker 保序 |
| Hermes Issue #553 / claude-subconscious | 潜意识观察架构、摘要时机、4 注入点 |
| Gentleman-Programming/engram（6012★） | FTS5 词法记忆产品形态 |
| TAIPANBOX/engram | bm25+OR 连接+min-max 融合、spreading BFS、Ebbinghaus、reflect_async |
| fxsjy/jieba + dart_jieba | 中文分词 + idf 权重表（MIT） |
| THUOCL | 领域词典 |
| ItemCF（Sarwar 2001）/ FolkRank（Jäschke 2007）/ PPR | 标签共现推荐、防万金油 |
| BKT（Corbett & Anderson 1995）/ ACT-R / Bjork retrievability | 置信度引擎的数学基础 |
| scikit-learn TfidfVectorizer | min_df/max_df 防热词污染 |
| DeepSeek Harness（DSH） | Goal 持久化、异步委派、pruner、技能目录注入、时点对账 |
| Tantivy / Meilisearch / MiniSearch | 搜索引擎管线参考（§12） |
| przm-memory | token 预算 1500、专有名词 IDF boost |
| OpenClaw / Letta MemFS | 文档分层、dreaming 后台巩固 |

## 16. 维护约定

实施时（任一 P0-P4 落地）同步更新 `README.md` 能力清单与 `docs/HANDOFF.md` 进度/踩坑（MIX 维护约定）。新工具遵循 `tools/registry.dart` 注册协议。数据资产进 `assets/` 并记录许可证/来源（§11 表）。置信度引擎的数学参数（τ、k1/b、阈值）在 P1 真机数据后校准，校准结论记入 HANDOFF。
