"""MIX Python runner — 原生 CPython 代码块执行服务器。

由 serious_python 打包进 APK，运行时在后台线程启动（SeriousPython.run）。
纯 stdlib 实现（零第三方依赖，避免把 Flask 全家桶打进 APK），通过
HTTP/JSON 与 Flutter 通信：

  POST /ping      {"ok": true}
  POST /add_path  {"path": "/data/.../python_wheels/numpy"}  注入 sys.path
  POST /run       {"code": "..."}  执行代码，返回 stdout + matplotlib 图片

执行模型（与 WebView/Pyodide 版保持一致）：
  - matplotlib 用 Agg backend（无 GUI），plt.show() 钩子收集所有 figure
    渲染成 base64 PNG 回传 Flutter
  - exec 在一个持久化 globals 空间里跑（多次调用共享状态，等价于 notebook
    cell 之间共享变量）
  - 每次 run 前清空图片列表，但保留已画的 figure（notebook 语义）

端口策略：启动时绑定 127.0.0.1:0（随机空闲端口），把实际端口号写到
<support>/data/mix_runner_port 文件，Flutter 侧轮询读取后发起 HTTP 请求。
"""

import base64
import io
import json
import os
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

PORT_FILE = "mix_runner_port.json"


class MixRunner:
    """持久化执行环境：共享 globals 空间 + matplotlib 图片收集。"""

    def __init__(self):
        self._globals = {
            "__name__": "__main__",
            "__builtins__": __builtins__,
        }
        self._setup_matplotlib()

    def _setup_matplotlib(self):
        """预置 matplotlib：Agg backend + show() 钩子收集 figure 成 base64。"""
        prelude = "\n".join([
            "import sys, io, base64",
            "import matplotlib",
            "matplotlib.use('Agg')",
            "import matplotlib.pyplot as plt",
            "_MIX_IMGS = []",
            "def _mix_save_figs():",
            "    import io as _io, base64 as _b64",
            "    for _f in plt.get_fignums():",
            "        _fig = plt.figure(_f)",
            "        _buf = _io.BytesIO()",
            "        _fig.savefig(_buf, format='png', dpi=110, bbox_inches='tight')",
            "        _MIX_IMGS.append(_b64.b64encode(_buf.getvalue()).decode())",
            "        plt.close(_fig)",
            "plt.show = _mix_save_figs",
        ])
        exec(prelude, self._globals)

    def add_path(self, path):
        """把按需下载解压的 wheel 目录加入 sys.path（幂等）。"""
        if path and path not in sys.path:
            sys.path.insert(0, path)
        return {"ok": True}

    def run(self, code):
        """执行代码块，返回 stdout/stderr/图片/错误。"""
        out = io.StringIO()
        err = io.StringIO()
        images = []
        try:
            # 每次 run 重置图片收集列表（figure 本身保留在 plt 状态里）
            self._globals["_MIX_IMGS"] = []

            old_out, old_err = sys.stdout, sys.stderr
            sys.stdout, sys.stderr = out, err
            try:
                exec(code, self._globals)
                # 执行完统一保存所有 figure（不管有没有调 show）
                exec("_mix_save_figs()", self._globals)
            finally:
                sys.stdout, sys.stderr = old_out, old_err

            images = list(self._globals.get("_MIX_IMGS", []))
            return {
                "ok": True,
                "stdout": out.getvalue(),
                "stderr": err.getvalue(),
                "images": images,
            }
        except Exception:
            return {
                "ok": False,
                "error": traceback.format_exc(),
                "stdout": out.getvalue(),
                "stderr": err.getvalue(),
                "images": images,
            }


runner = MixRunner()


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            path = urlparse(self.path).path

            if path == "/ping":
                self._send_json({"ok": True})
            elif path == "/add_path":
                self._send_json(runner.add_path(body.get("path", "")))
            elif path == "/run":
                self._send_json(runner.run(body.get("code", "")))
            else:
                self._send_json({"ok": False, "error": f"unknown path: {path}"})
        except Exception as e:
            self._send_json({"ok": False, "error": traceback.format_exc()})

    def log_message(self, *args):
        # 静默访问日志
        pass


def main():
    # 绑定随机空闲端口，端口号写入 <support>/data/mix_runner_port.json
    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    try:
        with open(PORT_FILE, "w") as f:
            json.dump({"port": port}, f)
    except Exception:
        # 写端口文件失败不致命：Flutter 端还可以通过其它方式发现端口
        pass

    print(f"MIX runner listening on 127.0.0.1:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
