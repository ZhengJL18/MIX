# 开源嵌入式/轻量搜索引擎调研报告（供"纯 Dart + SQLite FTS5 手机端记忆搜索"借鉴）

> 调研日期：2026 年；调研方式：web_search 定位 + curl/fetch 直读一手来源（GitHub 源码/官方文档/AOSP 源码），关键论断均经本机实测或源码级核实。Star/许可证为 GitHub API 当日快照。
> 委托方背景：Flutter 纯 Dart Android 手机端"个人化本地记忆搜索引擎"，SQLite FTS5 已有，无服务器无 embedding。本报告回答：哪些开源搜索引擎概念值得抄、哪些依赖重不能搬、经典管线哪些环节有现成蓝本、哪些必须自研。

---

## 0. 结论先行：委托方该抄哪些概念（按 价值+落地成本 排序）

| 排名 | 概念 | 价值 | 落地成本 | 蓝本来源 |
|---|---|---|---|---|
| 1 | **BM25 打分公式与默认参数**（k1=1.2, b=0.75，长度归一 dl/avgdl） | 极高（排序核心） | 零（FTS5 `bm25()` 已内置同款） | Lucene/Tantivy/FTS5 三处源码一致 |
| 2 | **分段写入 + 定期合并的节奏**（segment → optimize） | 高（碎片化写入时保查询性能、清删除） | 零（FTS5 `optimize`/`merge` 即合并） | Tantivy/Lucene/bleve |
| 3 | **末词前缀搜索 + 前缀索引**（prefix 只作用于查询末词） | 高（记忆搜索的"想不起全名"场景） | 低（FTS5 原生 `term*` + `prefix=` 或 trigram） | Meilisearch/Typesense/FTS5 |
| 4 | **同义词/别名：查询时 OR 展开** | 高（个人记忆会用自己话描述，别名命中率关键） | 低（Dart 侧改写查询即可，改别名无需重建索引） | Meilisearch（源码实证查询时展开） |
| 5 | **typo 容错：作为排序加分项而非过滤 + 按词长分级** | 中高（输入错误/记忆模糊） | 中（Dart 实现 Levenshtein 约 30 行；先做"0 typo 词"） | Meilisearch/Typesense |
| 6 | **字段加权与"列存储特征 + 二次排序"**（fast field 思想：把标签/时间/重要度取出与 BM25 融合） | 高（记忆搜索需要时间衰减、标签图、重要度） | 中（FTS5 列权重零成本起步；复杂融合在 Dart 侧做） | Lucene/Tantivy fast field/FTS5 bm25 列权重 |
| 7 | **查询语法与查询解析器**（短语/NEAR/布尔/列过滤） | 高 | 零（FTS5 MATCH 原生支持） | FTS5/Meilisearch |
| 8 | **分词管线化设计**（tokenizer → filter 链） | 高（架构正确性） | 中（英文零成本；**中文必须自研**，见 §4/§8） | Tantivy/Lucene/bleve |

**明确不抄（依赖重/手机端用不上）**：FST term dictionary、bitpacking/SIMD 压缩、mmap Directory、多线程索引、Block-Max WAND 剪枝、skip list、norm 的 1 字节压缩编码（FTS5 B-tree 已提供同等功能；手机端几千~几万条数据量不需要这些极致优化）。

**旁路提示**：若委托方愿意放弃"纯 Dart"约束，pub.dev 上有现成 FFI 方案：`mimir`（内嵌 Meilisearch，typo 容错+CJK 开箱即用）、`flutter_tantivy`（Tantivy FFI 封装）、`flutter_lindera_tantivy`（Tantivy + Lindera 中日韩分词）。纯 Dart 约束下，生产级路线就是 SQLite FTS5 + 自研薄层。

---

## 1. Tantivy（Rust，Lucene 风格嵌入式全文搜索引擎）⭐最重要的架构蓝本

- **仓库**：https://github.com/quickwit-oss/tantivy
- **Star/活跃度**：15,698 ⭐（GitHub API 2026-08-15 快照），pushed 2026-08-15，非常活跃
- **许可证**：MIT
- **架构文档**：仓库根 `ARCHITECTURE.md`（注意：不在 docs/ 下，已移到根目录）https://raw.githubusercontent.com/quickwit-oss/tantivy/main/ARCHITECTURE.md

**核心架构要点**（均出自 ARCHITECTURE.md 与源码，一手）：

1. **Segment 生命周期（最重要的可借鉴概念）**：索引 = 一组**不可变的小 segment**（UUID 命名，各数据文件按扩展名区分）+ 一个 `meta.json` 记录 segment 清单与 schema，commit 时原子改写 meta.json。每个写线程持有内存中的可变表示，达到 `memory_budget_per_thread` 或批次结束即由 serializer 落盘为紧凑不可变文件。
2. **合并（merge）**：后台线程按 MergePolicy 找合并候选。目的有二：清除被 tombstone 删除的文档、减少 segment 数量（"hundreds of segments can have a measurable impact on search performance"）。默认 LogMergePolicy 常量：min_num_segments=8、level_log_size=0.75、max_docs_before_merge=1000 万、删除比例阈值 1.0。
3. **倒排结构**：Term→TermInfo 由 term dictionary 承担（fst crate 的有限状态转换器映射排序 term→TermOrdinal，再经 term info store 取 TermInfo）；TermInfo→Posting 由 posting lists 承担：按 **128 doc 一块**，doc_id delta 编码 + bitpack，tf bitpack，末块用 varint；skip list 每块记录 last_doc/bitwidth/tf_sum/块内最大 fieldnorm+tf，可估算块最大分做剪枝（Block-Max 思想）。
4. **BM25 与 fieldnorm**：默认相似度即 BM25（k1=1.2, b=0.75；idf=ln(1+(N−n+0.5)/(n+0.5))）。fieldnorm = 每文档字段 token 数，压成 **1 字节**（0–40 原样存，之后 log 刻度 256 档），BM25 据此预计算 256 项 tf 因子查表。
5. **写入与删除**：add/delete 进入带 opstamp（递增操作 id）的有序操作流；delete_term 只推入 DeleteQueue 不立即动文件；commit 时每线程落一个 segment，并把删除写成不可变 alive bitset tombstone 文件（`segment_id.opstamp.del`）；物理清除靠合并时按 alive set 重写排除。即：**删除 = tombstone + 合并时物理清除，不原地重写**。
6. **docstore vs fast field（双存储架构，可借鉴）**：docstore 按行存、LZ4 压缩，用于展示搜索结果（SERP），规则：单次查询命中 docstore 超过 100 次就是误用；fast field 按列存、bitpacked，DocId 随机访问 = `min_value + fetch_bits(num_bits*doc_id)`，用于排序/聚合（如"把点赞数取出与相关性分融合"）。Lucene 术语里 fast field 叫 **DocValues**。
7. **分词管线**：TextAnalyzer = Tokenizer + 链式 TokenFilter（LowerCaser、Stemmer 17 语种、StopWordFilter 等），可插拔；中文靠第三方 crate（tantivy-jieba、cang-jie）。ARCHITECTURE.md 明言："分/规范化过度→高召回低精度；不分→高精度低召回"，分词是搜索体验的关键。
8. **Searcher 快照**：搜索经 Searcher 持有 SegmentReader 列表，任何时刻搜索都发生在不可变快照上（无论后台如何合并/GC）。

**对纯 Dart + FTS5 手机端的可借鉴点**：
- ✅ **segment 概念 → FTS5 等价物**：FTS5 内部倒排也是分段 B-tree；委托方可照抄"批量事务写入 + 积攒后 `optimize` 合并成单棵大树"的节奏（对应 Tantivy 的 segment merge）。Tantivy"删除积攒到阈值再合并"的批处理节奏也直接适用 FTS5（`optimize` 可清删除）。
- ✅ **fieldnorm 概念**：FTS5 `bm25()` 已内置同样的长度归一（k1=1.2/b=0.75 硬编码，见 §4），Dart 侧无需自实现；Tantivy"1 字节 log 刻度存长度"只是压缩技巧，手机端可直接存真实长度。
- ✅ **fast field 思想**：把标签/时间/重要度作为普通列存储，检索后取出与 BM25 分融合排序——这正是委托方"标签图/推荐"要的；FTS5 的 bm25 列权重是零成本近似版。
- ❌ **不能搬（Rust 生态重依赖）**：fst term dictionary、bitpacking/SIMD、mmap、多线程索引、WAND 剪枝——SQLite 内部 B-tree 已提供同等功能，手机端小数据量用不上。

---

## 2. Apache Lucene（Java，搜索引擎始祖）

- **仓库**：https://github.com/apache/lucene
- **Star/活跃度**：3,537 ⭐（GitHub API 快照，主仓库不含各语言封装），pushed 2026-08-14，非常活跃
- **许可证**：Apache-2.0
- **核心源码**：`lucene/core/src/java/org/apache/lucene/search/similarities/BM25Similarity.java`（main 分支，已完整通读）

**BM25Similarity 实现细节**（一手源码核实）：
- **默认参数**：k1=1.2、b=0.75、discountOverlaps=true（位置增量为 0 的 overlap token 不计入文档长度）；main 分支新增 k3（查询侧词频饱和 `((k3+1)·qtf)/(k3+qtf)`，默认 -1 即禁用）。
- **IDF**：`log(1 + (docCount − docFreq + 0.5) / (docFreq + 0.5))` —— 是 RSJ 平滑 +0.5 型、恒非负；N 用"含该字段的文档数"（FieldStats.docCount），不是总文档数。
- **avgdl**：`sumTotalTermFreq / docCount`（全索引该字段 token 总数 / 含该字段文档数）。
- **score 公式**：`score = boost · idf · freq / (freq + k1·((1−b) + b·dl/avgdl))`。工程实现为 float 单调性改写 `weight − weight/(1 + freq·normInverse)`，且每个 scorer 预计算 256 项 `1/(k1·((1−b)+b·LENGTH_TABLE[i]/avgdl))` 查表。
- **norm 编码**：文档长度用 `SmallFloat.intToByte4` 压成 **1 字节**（0–39 精确直存，≥40 只有约 4–5 位有效精度，相对误差约 1/16；explain() 对 >39 明确标注 "length of field (approximate)"）。纯为省空间，Dart+SQLite 场景直接用真实长度即可。
- 可直接照抄到 Dart 的伪代码：`score += idf(q) * (tf*(k1+1)) / (tf + k1*(1 - b + b*dl/avgdl))`，idf 用 `log(1+(N-df+0.5)/(df+0.5))`。

**Lucene 整体架构要点**（官方 javadoc/docs）：
- 不可变 **segment**（每个含 term dictionary + postings + norms 等文件）；删除是 tombstone（.liv 文件），合并时清除。
- **IndexWriter 流程**：每个线程一个 DWPT 内存缓冲（默认约 16MB RAM 触发 flush）→ 刷成不可变 segment → 后台 **TieredMergePolicy** 按分层策略合并。
- 近实时搜索（NRT）：`DirectoryReader.open(IndexWriter)` 在内存缓冲上直接可搜。

**对纯 Dart 的借鉴**：公式、默认参数、长度归一思路**必须照抄**（与 FTS5 内置 bm25 同源）；norm 字节编码、k3、float 改写都是 Lucene 特有工程优化，不必搬。

---

## 3. Meilisearch / Typesense（轻量搜索服务器）——机制概念借鉴

> 两者都是 Rust 独立服务器 + 内存/磁盘混合索引，**不是嵌入式、不可搬进 Flutter**；但它们的**机制设计**是"查询体验层"的最佳蓝本（这正是 FTS5 缺的）。

### 3.1 Meilisearch
- **仓库**：https://github.com/meilisearch/meilisearch
- **Star/许可证**：58,973 ⭐；许可证为 **MIT + BUSL-1.1 双许可**（`LICENSE`：`SPDX-License-Identifier: MIT AND BUSL-1.1`，企业版部分走 BSL）——注意不是纯 MIT
- **文档一手来源**：官方文档站 + docs 仓库 markdown 源（`capabilities/full_text_search/relevancy/`、`resources/internals/`）

机制要点：
1. **排序规则（ranking rules）——typo 是排序规则而非过滤条件**：内置七条规则默认顺序 `words → typo → proximity → attributeRank → sort → wordPosition → exactness`。words（命中词数，最优先，且**强制恒在最高优先级**、从右往左计算）、typo（按 typo 数升序）、proximity（命中词间距）、attributeRank（字段重要性顺序）、sort（查询时排序参数）、exactness（精确度）。"按 typo 数排序"和"typo tolerance（匹配放宽到几个 typo）"是两个独立开关。
2. **typo tolerance 词长分级**：默认 1–4 字词 0 typo、5–8 字 1 typo、≥9 字 2 typo，每词上限 2，用 prefix Levenshtein；可配 `minWordSizeForTypos`（约束 0 ≤ oneTypo ≤ twoTypos ≤ 255）、`disableOnWords`、`disableOnAttributes`。
3. **同义词 = 查询时展开（重要纠正）**：源码 `crates/milli/src/search/new/query_term/parse_query.rs` 在构建查询项时读同义词库，挂到 `term.zero_typo.synonyms` —— **只在 0 typo 词上生效、改同义词无需重建索引**。
4. **前缀搜索默认只作用于查询末词**。

### 3.2 Typesense
- **仓库**：https://github.com/typesense/typesense
- **Star/许可证**：26,441 ⭐；**GPL-3.0**（强 copyleft，比 Meilisearch 更不友好，嵌入式场景基本排除）
- 机制要点：`num_typos` 默认 2（Damerau–Levenshtein 距离），min_len_1typo=4、min_len_2typo=7；`typo_tokens_threshold` 默认 1（惰性纠正）；prefix 默认 true 且仅末词、默认只取 top 4 前缀候选；同义词单向/多向、查询时应用于查询 token。

**对纯 Dart 手机端的借鉴判断**：
- ✅ 值得抄：① typo 作为排序加分项（FTS5 检索结果后按编辑距离分级微调排序）而非过滤；② 词长分级（短词不容错、长词最多 2 错）；③ 前缀只作用于末词（FTS5 原生 `末词*` 支持）；④ 同义词查询时 OR 展开（Dart 侧改写查询，别名表独立存，改别名即时生效）。
- ❌ 不搬：服务器架构、内存索引、Rust 生态、GPL（Typesense）。

---

## 4. SQLite FTS5 能力边界（委托方已用底座，含关键纠错）

- **一手来源**：https://sqlite.org/fts5.html + 源码 `ext/fts5/fts5_aux.c` 等 + 本机实测（Python sqlite3 3.45.1）

**能做**：
1. **bm25() 排序**（源码 `fts5_aux.c` 核实）：k1=1.2、b=0.75 **硬编码不可调**；IDF=`log((N−n+0.5)/(n+0.5))`（注意与 Lucene 的 `log(1+...)` 差一个 +1，但 FTS5 有下限：idf≤0 时钳到 1e-6 防负）；返回**负值**，`ORDER BY bm25(fts)` 升序即最优在前。列权重语法 `bm25(fts, 10.0, 5.0)`：第 N 个实参 = 第 N 列权重，**实现上是按列放大词频**（`aFreq[ip] += w`），不是整体分乘——字段加权的最廉价近似。隐藏列 `rank` 默认 = 无参 bm25()，`ORDER BY rank` 更快，可用 `rank MATCH 'bm25(10.0,5.0)'` 换权重。
2. **查询语法**：`term*` 前缀查询（仅短语末 token，引号内无效）、短语 `"a b"`、`+` 拼接、`NEAR(a b, N)`（默认 10）、`^` 列首、列过滤 `col:`/`{c1 c2}:`、布尔 AND/OR/NOT + 隐式 AND。`prefix='2 3'` 选项为指定长度前缀建独立索引加速前缀查询。
3. **tokenizer**：unicode61（默认）、ascii、porter（仅英文词干）、**trigram（SQLite 3.34.0+）**：每 3 连续字符一个 token，任意子串匹配，可优化 LIKE/GLOB，查询串 <3 字符不命中、会被标点打断。
4. **外部内容表**：`content=''`（contentless，只存索引不存原文、读回原文返回 NULL、仅支持 delete 命令；3.43.0+ 有 contentless-delete）；`content=表名`（回查内容表，一致性用户负责，官方触发器示例：INSERT 直接插、UPDATE/DELETE 用 `INSERT INTO fts(fts,rowid,...) VALUES('delete',...)` 删旧插新）。
5. **运维命令**：`'delete'`（删单行，需提供与原值完全一致的内容）、`'delete-all'`、`'rebuild'`（按内容表重建）、`'optimize'`（合并所有 B-tree 为单个，可 `'merge'` 分批）、`'integrity-check'`。
6. **辅助函数**：`highlight()`/`snippet()`（自动选片段尽量覆盖不同查询词）。自定义排序需 C API 扩展（Dart 侧做不到，只能在 Dart 层二次排序）。

**不能做（边界）**：
- **无中文分词**：unicode61 把"连续一段汉字"当**一个 token**（汉字属 Unicode Lo 类，是 token 字符）。本机实测：`MATCH '你好'` 匹配不到"你好世界"（除非 `你好*` 前缀）；trigram 下 `MATCH '你好世界'` 可命中（三字子串）。→ 中文必须 trigram 或自研分词/逐字索引。
- **无 typo tolerance、无同义词、无真 field boost**（bm25 列权重是近似）、无 matchinfo()（那是 FTS3/4 的；**FTS5 没有 matchinfo，也没有 'delete-first' 命令**，只有 delete/delete-all）、无 ICU tokenizer。
- 自定义 tokenizer 可用 `FTS5_TOKEN_COLOCATED` 实现 3 种同义词方案（官方文档 7.1.1 节）。

**对委托方**：排序直接用 `ORDER BY rank`（bm25）+ 列权重近似字段加权；中文检索 = trigram（字级子串，代价是索引膨胀 + 3 字下限）或自研分词器写入 token 列；typo/同义词/标签融合排序全部要在 FTS5 之上自研（概念蓝本见 §3）。

---

## 5. 轻量 JS 方案（评分实现可直接"翻译"成 Dart）

| 库 | 仓库 | Star/许可证 | 评分方式 | 字段加权 | 特点 |
|---|---|---|---|---|---|
| Lunr.js | https://github.com/olivernn/lunr.js | 9,200 / MIT | BM25（k1=1.2/b=0.75 可调），IDF=`log(1+\|(N−n+0.5)/(n+0.5)\|)` | 字段/文档 boost 在**构建期**乘进每字段文档向量，查询期只做点积 | 倒排索引内存驻留，`index.toJSON()` 可序列化；pipeline（trimmer/stopword/stemmer） |
| MiniSearch | https://github.com/lucaong/minisearch | 6,093 / MIT | **自研 BM25+**（k=1.2/b=0.7/δ=0.5 可调），查询期实时算 | `termWeight×termBoost×fieldBoost×docBoost×rawScore`，fuzzy/prefix 命中打折 0.45/0.375 | 倒排 trie + JSON 序列化；prefix/fuzzy/autoSuggest |
| FlexSearch | https://github.com/nextapps-de/flexsearch | 13,774 / Apache-2.0 | **无 BM25/IDF**：索引期按 resolution 分档预计算分（`src/index/add.js` 的 get_score），查询期零计算 | 自定义 scorer/encoder | 极致性能路线；`Charset.CJK` 编码器支持中文 |
| Fuse.js（对比） | https://github.com/krisk/Fuse | — | 无倒排索引，线性扫描模糊匹配 | — | 只适合小数据量，不推荐做主引擎 |
| ~~WMR~~ | https://github.com/preactjs/wmr | — | **不是搜索库**（Preact 的 dev server），任务清单中的"WMR"是误指 | — | 轻量替代：https://github.com/kbrsh/wade（2.6KB 字符 trie 子串搜索） |

**对纯 Dart 的借鉴**：
- ✅ **MiniSearch 路线最值得抄**：查询期 BM25+ 实时算分 + 倒排 Map（Dart 用 `Map<String, Map<docId, freq>>` 即可）+ 字段/文档 boost 乘到加权分里 + fuzzy/prefix 命中打折——公式三行、参数可调、语义最佳，与 FTS5 语义互补。
- ✅ **Lunr 的"构建期把 boost 折进向量"**是一种性能优化思路（Dart 可学：字段加权在写入时预乘，查询期少算）。
- ⚠️ **FlexSearch 的"索引期预计算分"路线**：与 BM25 哲学相反（无 IDF、无动态长度归一），适合纯前端极速场景；记忆搜索需要动态 BM25（新增文档改变 IDF），不建议抄，但"自定义 encoder 处理中文"思路可借鉴。

---

## 6. bleve（Go 嵌入式）及其他

- **仓库**：https://github.com/blevesearch/bleve
- **Star/许可证**：11,177 ⭐ / Apache-2.0，活跃（pushed 2026-08-13）
- **架构**（`index/scorch/README.md` 一手通读；旧 `docs/Scorch.md` 在 bleve 全部 git 历史中都不存在，现役文档即 scorch README + 独立仓库 `blevesearch/zapx` 的 zap 段格式说明）：
  - **scorch 索引 = 分段不可变索引**：每个 batch 写入生成一个新 segment；段间无序、查询时并发搜所有段。
  - **更新语义**：批量更新 = 新 segment + 对旧 segment 计算"被作废文档"的 **deleted postings bitset（tombstone）** 并 OR 进各段；`IndexSnapshot` = 一组 `SegmentSnapshot`（segment + deleted 列表），读者持不可变快照指针，任何时刻看到稳定视图。
  - **检索原语**：Segment → TermDictionary → PostingsList → Posting（Number=docid、Frequency、**Norm float**）；term search 逐段合并。
  - 数据结构：**FST term dictionary（vellum）** + **roaring bitmap 倒排** + **zap 段格式**（mmap、倒序写、分块 doc 跳读）；分析管线 tokenizer→filter→token map；BM25 评分、facet、highlight。
- **其他嵌入式引擎**（各 1-2 句）：
  - **Xapian**（C++ 嵌入式经典，https://github.com/xapian/xapian）：BM25 起源的 Okapi 家族实现，许可证 **GPL v2+**。
  - **Whoosh**（Python 纯实现，https://github.com/whoosh-community/whoosh）：倒排+BM25，教育价值高，代码易读，适合当"自研打分器"教材；**已停维护**。
  - **Sonic**（https://github.com/valeriansaliou/sonic）：Rust，**MPL-2.0**，只存"词→ID"的 identifier index，面向极速补全场景，不适合文档搜索。

**借鉴点**：bleve 再次印证"不可变 segment + 快照读 + tombstone 删除 + 合并清除"是嵌入式搜索引擎的标准架构；委托方用 FTS5 时把"批量写入 + 定期 optimize"对应上即可。FST term dictionary、zap 列存格式都是 Go 生态重依赖，不搬。

---

## 7. 纯 Dart 现状与手机端离线全文搜索实践

**结论先行：pub.dev 上没有成熟的"纯 Dart 倒排索引全文搜索引擎"包**（经 pub.dev API 搜索 fts5/full text/search engine/bm25 核实）。委托方"纯 Dart + FTS5"路线就是正确且唯一的生产级路线。

- **sqlite3**（https://pub.dev/packages/sqlite3，3.5.1）：纯 FFI 绑定；**3.x 起自带编译好的 SQLite（含 FTS5），无需再打 sqlite3_flutter_libs**。
- **sqlite3_flutter_libs**：**已 EOL**（0.6.0+eol，官方说明"Not used anymore, update to version 3.x of package:sqlite3 instead"）。
- **drift**（https://pub.dev/packages/drift，2.34.3）：FTS5 走 `.drift` SQL 文件里的原生 DDL（无 typed Fts5Table/MatchQuery），依赖 sqlite3。
- **关键铁证（AOSP 源码）**：Android 系统自带 SQLite **从未启用 FTS5**——`platform_external_sqlite` 的 `dist/Android.bp` 只定义了 `SQLITE_ENABLE_FTS3/FTS3_BACKWARDS/FTS4`，**没有 SQLITE_ENABLE_FTS5**（master 分支核实）。所以"低版本 Android 才要自带 SQLite"是误区：**任何 Android 版本都要用自带 FTS5 的 SQLite**（sqlite3 3.x 已默认如此）。这也能解释为何委托方"已有 FTS5"——大概率已走 sqlite3 3.x。
- **纯 Dart 玩具级包**：`search_engine`（0.1.0，Dart 2 only，停更）、`full_text_search`（0.8.0+3，Dart 2 only，isolate 方案）、lunr/bm25 等 Dart 移植（玩具级）——不建议生产使用。
- **中文现成封装（可参考）**：`sqlite3_simple`（https://pub.dev/packages/sqlite3_simple，基于 wangfenjin/simple 分词扩展 + sqlite3 3.x，中文+拼音，全平台含 Android）——若不想自研分词，这是现成的中文 FTS5 分词方案。
- **FFI 替代方案（若可放弃纯 Dart）**：`mimir`（https://github.com/GregoryConrad/mimir，168⭐/MIT，Rust 内嵌 Meilisearch，typo 容错+CJK 开箱即用）、`flutter_tantivy`（Tantivy 的 Flutter FFI 封装）、`flutter_lindera_tantivy`（Tantivy + Lindera 中日韩形态分析）。
- **手机端离线全文搜索实践**：Android 离线全文搜索的标准方案就是 SQLite FTS（FTS3/4 起，FTS5 需自带）；iOS 无内置 FTS。中文场景成熟做法：trigram（3 字子串，简单但索引膨胀+3 字下限）或自定义分词（逐字/词典切分后写入 token 列再前缀匹配）。委托方已用 FTS5，建议在"分词层"上做文章，而不是换引擎。

---

## 8. 管线蓝图映射：哪些环节有现成开源蓝本、哪些必须自研

经典管线：**采集 → 分词 → 倒排 → 加权 → 检索 → 排序 → 扩展**

| 环节 | 现成蓝本？ | 说明 |
|---|---|---|
| 采集（文档入库/增量更新） | ✅ 有蓝本 | SQLite FTS5 外部内容表 + 触发器增量更新（官方示例）；分段批处理节奏抄 Tantivy/Lucene/bleve（批量 insert + 定期 optimize） |
| 分词 | ⚠️ 半自研 | 英文/通用：FTS5 unicode61/porter 即蓝本；**中文无蓝本**（unicode61 整段一个 token，实测），必须自研：词典切分（jieba 思路）或 trigram 字级子串，或两者结合（分词写入 + trigram 兜底） |
| 倒排 | ✅ 有蓝本（不重复造） | FTS5 B-tree + doclist 已内置；概念理解抄 Tantivy/Lucene（term dict + posting + skip list），但**不需要**自己实现 FST/bitpacking |
| 加权 | ✅ 有蓝本 | BM25 公式/参数：Lucene BM25Similarity.java、FTS5 bm25()（k1=1.2/b=0.75 一致）；字段加权：FTS5 bm25 列权重（零成本）或抄 MiniSearch 的 termBoost×fieldBoost×docBoost 乘法模型 |
| 检索 | ✅ 有蓝本 | FTS5 MATCH 语法（短语/前缀/NEAR/布尔/列过滤）全原生；查询解析器可参考 Meilisearch query-grammar / FTS5 语法 |
| 排序 | ⚠️ 半自研 | 相关性分有蓝本（bm25() + rank 列）；**融合排序必须自研**：时间衰减、标签图、重要度×相关性——思路抄 Tantivy fast field/Lucene DocValues（特征列存储，Dart 侧取出融合），或先用品类上 FTS5 列权重 |
| 扩展（typo/同义词/推荐） | ❌ 必须自研（但概念蓝本现成） | FTS5 无 typo/同义词。概念照抄：Meilisearch"typo 作为排序规则 + 词长分级"、同义词查询时 OR 展开（源码实证）、末词前缀（FTS5 原生 `term*`）；算法实现简单（Levenshtein 30 行、别名表一张）。标签图/推荐引擎则完全自研（图结构 + 共现统计），无现成嵌入式蓝本 |

**一句话总结**：倒排、BM25、查询语法、增量更新、合并节奏——FTS5 全都有现成蓝本（概念来自 Lucene/Tantivy 一脉），委托方要抄的是"**怎么组织写入、怎么用**"；真正必须自研的是**中文分词、typo 容错、同义词、融合排序、标签图推荐**这五块"查询体验层"，而它们的机制蓝本在 Meilisearch/Typesense/MiniSearch 里都是现成的、可逐行翻译成 Dart。

---

## 附：一手来源索引（主要）

- Tantivy ARCHITECTURE.md：https://raw.githubusercontent.com/quickwit-oss/tantivy/main/ARCHITECTURE.md ；源码 src/indexer/、src/postings/、src/fieldnorm/、src/query/bm25.rs、src/tokenizer/
- Lucene BM25Similarity.java：https://raw.githubusercontent.com/apache/lucene/main/lucene/core/src/java/org/apache/lucene/search/similarities/BM25Similarity.java ；javadoc：https://lucene.apache.org/core/9_12_0/core/org/apache/lucene/search/similarities/BM25Similarity.html
- Meilisearch：ranking rules/typo/synonyms 文档源（docs 仓库 `capabilities/full_text_search/relevancy/*.mdx`）；同义词查询时展开源码 `crates/milli/src/search/new/query_term/parse_query.rs`；LICENSE（MIT AND BUSL-1.1）
- Typesense：https://typesense.org/docs/ 搜索 API/synonyms API（SPA 站，源码为 typesense/typesense）
- SQLite FTS5：https://sqlite.org/fts5.html ；bm25 实现源码 https://github.com/sqlite/sqlite/blob/master/ext/fts5/fts5_aux.c ；本机实测（sqlite3 3.45.1）
- JS 库：lunr.js `lib/builder.js`/`lib/idf.js`、minisearch `src/`、flexsearch `src/index/add.js`/`src/charset.js`
- bleve：`index/scorch/README.md`（https://raw.githubusercontent.com/blevesearch/bleve/master/index/scorch/README.md）
- AOSP：https://github.com/aosp-mirror/platform_external_sqlite/blob/master/dist/Android.bp（仅 FTS3/FTS4）
- pub.dev：sqlite3、sqlite3_flutter_libs（EOL）、drift、mimir、flutter_tantivy、flutter_lindera_tantivy、search_engine、full_text_search；mimir 仓库 https://github.com/GregoryConrad/mimir
- GitHub API 快照：各仓库 `/repos/{owner}/{repo}`（star/license/pushed_at）
