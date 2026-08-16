# 记忆子系统真机验证清单（v4 架构，2026-08）

> 目的：验证 P0-P4 在真实华为手机（FOA-AL00）上的表现。前置：装最新 APK
> （GitHub Actions 产物 `mix-app-debug.apk`，或应用内自更新）。
> 方式：USB adb（`adb forward tcp:8022 tcp:8022` + SSH，禁无线 adb）。

## 1. FTS5 可用性（最高风险，P0 前置）

| 步骤 | 预期 | 失败对策 |
|---|---|---|
| 手机 `adb shell` 查系统 SQLite 版本 | `sqlite3 --version`（若系统无 sqlite3 CLI 跳过） | — |
| 聊天输入"你好"（寒暄，验证 trivial 门控不检索） | 正常回复，无 `<memory-context>` | 门控 bug 排查 |
| 聊天输入"矩阵乘法怎么算" | 若记忆库有相关文档 → 系统提示含 `<memory-context>`（对话调试日志可见） | FTS5 不可用 → LIKE 降级（仍应命中）；长期方案迁 sqlite3 3.x |
| `memory_search` 工具触发（让 agent 搜"行列式"） | 返回匹配文档列表（`fts` 字段指示 FTS5 是否生效） | — |

**判定**：`memory_search` 的 `fts: true` = FTS5 可用（好）；`fts: false` = 降级 LIKE（可用但需计划迁移 sqlite3 3.x）。

## 2. 中文分词 + 热词检索

| 步骤 | 预期 |
|---|---|
| 让 agent 用 `memory` 工具写一段含"行列式/矩阵"的记忆 | 写入成功 |
| `memory_search` 搜"行列式" | 命中刚写的记忆（bm25 排序） |
| `memory_search` 搜长句"行列式的性质是什么" | OR 分词命中（验证 OR 连接防召回归零） |
| `memory_search` 故意打错"行列势"（错字） | typo 容错：在标签库找相近标签 OR 展开 → 命中"行列式"相关记忆（验证编辑距离容错） |

## 3. 确定性图建构（自动标签 + 知识点边）

| 步骤 | 预期 |
|---|---|
| 学习模式建知识点（如"行列式"）+ 写含该词的记忆 | memory.db 出现 `kind='knowledge'` 文档 |
| 写两篇都含"行列式"的记忆 | memory_links 出现 kind='tag' 边（Hebbian） |
| 调试：`adb shell` 拉 memory.db 查表 | tags/links/evidence 有数据 |

## 4. 笔记同步（printnotes 入库）

| 步骤 | 预期 |
|---|---|
| 在笔记库（documents/notes）建一篇 .md 笔记，重启 App | memory_search 能搜到该笔记（kind='note'） |
| 修改笔记内容，重启 | 内容更新（mtime 增量生效，不重复插入） |

## 5. 学习状态 + 画像投影

| 步骤 | 预期 |
|---|---|
| 做题（study_quiz）答对/答错几题 | memory_evidence 出现 knowledge correct/wrong 记录 |
| 让 agent 调 `study_status` | 状态分类（mastered/weak 等）+ 复习推荐 |
| `memory_read` 读 memory/profile.md | 学习状态投影 Markdown 内容 |

## 6. Goal 系统

| 步骤 | 预期 |
|---|---|
| 让 agent 用 `goal` 工具创建"掌握线性代数第二章" | 创建成功返回 goal_id |
| 重启 App，再让 agent `goal list` | goal 仍在（持久化） |
| `goal progress`（关联 evidence_obj 时） | 证据驱动进度值 |

## 7. 性能观察

| 项 | 预期 |
|---|---|
| 首轮对话延迟（分词器冷启动：dict.dgz 复制+加载） | 可接受（词典 2MB，预期 <1s） |
| 每轮 prefetch（8s 有界） | 寒暄消息无感知延迟；实质消息注入不卡 UI |
| memory_search 响应 | FTS5 毫秒级；LIKE 降级大库时观察 |

## 完成标准

1-7 全部通过 → 记忆子系统真机可用，HANDOFF 更新"真机验证"状态。
任一失败 → 记录现象到 HANDOFF 踩坑，按对策处理。
