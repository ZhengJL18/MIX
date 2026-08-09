# Third-Party Notices

本目录（`assets/python/`）包含重新分发的开源软件包，用于在 MIX 内通过 Pyodide (WebAssembly) 离线运行 Python 代码并渲染 matplotlib 图表。

以下包均允许再分发（redistribution），版权归各自作者所有。

## Pyodide 运行时

- 项目：https://github.com/pyodide/pyodide
- 许可证：Mozilla Public License 2.0 (MPL-2.0)
- 版权：© 2019-2026 Pyodide contributors and Mozilla

## Python 包（wheels）

| 包 | 版本 | 许可证 |
|---|---|---|
| numpy | 2.4.3 | BSD-3-Clause |
| matplotlib | 3.10.8 | PSF License (BSD-based) |
| networkx | 3.6.1 | BSD-3-Clause |
| contourpy | 1.3.3 | BSD-3-Clause |
| cycler | 0.12.1 | BSD-3-Clause |
| fonttools | 4.62.1 | MIT |
| kiwisolver | 1.5.0 | BSD-3-Clause |
| packaging | 26.1 | Apache-2.0 OR BSD-2-Clause |
| pillow | 12.2.0 | HPND (PIL Software License) |
| pyparsing | 3.3.2 | MIT |
| python-dateutil | 2.9.0.post0 | Apache-2.0 OR BSD-3-Clause |
| pytz | 2026.1.post1 | MIT |
| six | 1.17.0 | MIT |

各包完整许可证文本见对应 wheel 内的 `*.dist-info/licenses/` 目录（wheel 为 zip 格式，可解压查看）。

## 下载来源

- Pyodide 运行时与编译包：https://cdn.jsdelivr.net/pyodide/v314.0.4/
- 纯 Python 包（python-dateutil/pytz/six）：https://pypi.org/ (Python Package Index)

## 说明

- 这些 wheel 仅在本 App 内按需下载使用，未做任何修改。
- 如你有异议或需要移除，请联系仓库维护者。
