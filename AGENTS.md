# AGENTS.md — 协作者维护约定

本文件供 AI 协作者 / 接手的开发者阅读。项目全貌见 [README.md](./README.md)。

## 必须遵守的维护约定

1. **重大更新必须同步更新文档**：新增子系统 / 工具集 / 外部服务、架构调整、依赖大版本升级等重大变更时，必须同步更新：
   - `README.md`（项目能力全景，保持与代码状态一致）
   - `docs/HANDOFF.md`（当前进度、关键约定、踩坑记录）
   小改动（bug 修复、文案）可以不更新。

2. **复刻策略不可偏离**：MIX 以 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 为唯一行为规范（映射表 `docs/HERMES_MAPPING.md`），不自创工具系统。新工具应遵循 `tools/registry.dart` 的注册协议（name / toolset / JSON Schema / check_fn / handler(args)→JSON）。

3. **笔记库根固定为 `documents/notes`**：printnotes UI 与 agent `notes_*` 工具共用该目录，不可改成任意目录。

4. **两个本地 patch 的依赖**（`dependency_overrides`：flutter_inappwebview_android、file_picker）升级前必须确认上游已兼容 AGP 9，否则回退到编译失败。
