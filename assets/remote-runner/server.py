#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MIX 云端代码执行服务器（单文件、零第三方依赖，Python 3.8+）

部署：
    sudo bash deploy.sh [端口] [token]        # 一键部署（systemd 常驻）
    或手动：
    sudo cp server.py /opt/mix-runner/
    sudo MIX_RUN_TOKEN=xxx MIX_RUN_PORT=8123 python3 /opt/mix-runner/server.py

协议：
    POST /run   {"token": "...", "language": "python", "code": "..."}
    返回       {"stdout","stderr","images"(base64 PNG 列表),"exit_code","duration_ms","error"}

    GET /health  健康检查

安全：
    - token 认证（部署时用随机串，App 设置里填同样的）
    - 每次执行独立临时目录，跑完即删
    - 全局串行 + 超时 kill（防死循环打满服务器）
    - stdout/stderr 截断上限，防刷屏
"""
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("MIX_RUN_TOKEN", "changeme")
PORT = int(os.environ.get("MIX_RUN_PORT", "8123"))
TIMEOUT = int(os.environ.get("MIX_RUN_TIMEOUT", "15"))     # 秒
MAX_OUTPUT = 200_000        # stdout/stderr 各自截断上限（字节）
MAX_BODY = 1_000_000        # 请求体上限（字节，/run）
MAX_EXTRACT_BODY = 40_000_000  # /extract 请求体上限（字节，base64 文件约 30MB）
EXTRACT_TIMEOUT = 120       # 格式提取/转换超时（秒）
IMG_DIR = "/tmp/mix_imgs"   # matplotlib 图片中转目录

# 语言 → 执行方案（ext: 源码文件名；compile/run: 命令）
LANGS = {
    "python": {"ext": "main.py", "run": ["python3", "main.py"]},
    "c": {"ext": "main.c", "compile": ["gcc", "-O2", "-o", "prog", "main.c"],
          "run": ["./prog"]},
    "js": {"ext": "main.js", "run": ["node", "main.js"]},
    "bash": {"ext": "main.sh", "run": ["bash", "main.sh"]},
    "java": {"ext": "Main.java", "compile": ["javac", "Main.java"],
             "run": ["java", "Main"]},
    "sql": {"ext": "main.sql", "run": ["sqlite3", ":memory:", ".read main.sql"]},
}
ALIASES = {"py": "python", "javascript": "js", "sh": "bash", "shell": "bash"}

_lock = threading.Lock()
os.makedirs(IMG_DIR, exist_ok=True)


def _strip_jupyter(code):
    """剥离 Jupyter 魔法/命令，避免纯 Python 解释器报 SyntaxError。

    策略：假装看不见——不执行魔法，只是让它们不炸：
      - `%magic` 行内魔法（如 %matplotlib inline）→ 丢弃该行
      - `%%cell_magic` 单元魔法 → 丢弃首行，body（后续行）保留
      - `!shell` 系统命令 → 丢弃该行
      - `plt.plot?` 帮助查询 → 丢弃该行
    """
    lines = []
    for line in code.split("\n"):
        s = line.strip()
        if not s:
            lines.append(line)
            continue
        if s.startswith("%") or s.startswith("!"):
            continue
        # 帮助查询：整行由标识符/点/括号/逗号/运算符构成，以 ? 结尾。
        if re.match(r"^[\w\s\.\(\)\[\],=+\-*/<>:]*\?\s*$", line):
            continue
        lines.append(line)
    return "\n".join(lines)


def wrap_python(code):
    """注入 matplotlib Agg 后端；结尾自动把画出的图存成 PNG。

    对用户代码零侵入：教材代码里 plt.show() 在 Agg 下是 no-op，
    执行完后把当前所有 figure 保存为 /tmp/mix_imgs/fig_N.png。
    先剥离 Jupyter 魔法（%matplotlib inline 等在纯 Python 里是 SyntaxError）。
    """
    code = _strip_jupyter(code)
    if "matplotlib" not in code and "plt." not in code:
        return code
    prologue = (
        "import matplotlib\n"
        "matplotlib.use('Agg')\n"
        "import matplotlib.pyplot as plt\n"
    )
    epilogue = (
        "\ntry:\n"
        "    import os as _os\n"
        "    _os.makedirs('%s', exist_ok=True)\n"
        "    for _i, _n in enumerate(plt.get_fignums()):\n"
        "        plt.figure(_n).savefig('%s/fig_%%d.png' %% _i, "
        "bbox_inches='tight', dpi=110)\n"
        "except Exception:\n"
        "    pass\n" % (IMG_DIR, IMG_DIR)
    )
    return prologue + code + epilogue


def _java_file_name(code):
    """Java 单文件：public class 名须与文件名一致，自动提取。"""
    m = re.search(r"\bpublic\s+class\s+(\w+)", code)
    return (m.group(1) if m else "Main") + ".java"


def _sandbox_setup():
    """子进程执行前设置资源限制（沙盒第一层）。

    - 虚拟内存上限：防 malloc 爆炸 / fork 炸弹撑爆内存
    - CPU 时间：超时之外的硬兜底（防恶意代码绕过超时）
    - 进程数：防 fork 炸弹
    - 写文件大小：防写满磁盘
    - 文件描述符：防耗尽
    """
    import resource
    MEM_LIMIT = 512 * 1024 * 1024          # 512MB 虚拟内存
    CPU_LIMIT = TIMEOUT + 5                 # 超时基础上再留余量
    resource.setrlimit(resource.RLIMIT_AS, (MEM_LIMIT, MEM_LIMIT))
    resource.setrlimit(resource.RLIMIT_CPU, (CPU_LIMIT, CPU_LIMIT))
    resource.setrlimit(resource.RLIMIT_NPROC, (32, 32))
    resource.setrlimit(resource.RLIMIT_FSIZE, (64 * 1024 * 1024, 64 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))


# 子进程最小环境：不继承宿主机环境变量（防泄露 token/密钥），
# 只保留执行必需项。
_MIN_ENV = {
    "PATH": "/usr/bin:/bin",
    "HOME": "/tmp",
    "LANG": "C.UTF-8",
    "MPLCONFIGDIR": "/tmp/mplconfig",      # matplotlib 缓存目录（nobody 无 $HOME）
}


def _run(args, cwd, timeout):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                          timeout=timeout, preexec_fn=_sandbox_setup,
                          env=_MIN_ENV)


def execute(lang, code):
    spec = LANGS.get(lang)
    if spec is None:
        return {"error": "不支持的代码语言: %s" % lang}
    workdir = tempfile.mkdtemp(prefix="mixrun_")
    t0 = time.time()
    try:
        src = wrap_python(code) if lang == "python" else code
        if lang == "java":
            fname = _java_file_name(code)
        else:
            fname = spec["ext"]
        with open(os.path.join(workdir, fname), "w") as f:
            f.write(src)
        try:
            if "compile" in spec:
                cp = _run(spec["compile"], workdir, TIMEOUT)
                if cp.returncode != 0:
                    return {"stdout": cp.stdout[:MAX_OUTPUT],
                            "stderr": (cp.stderr or "编译失败")[:MAX_OUTPUT],
                            "images": [], "exit_code": cp.returncode,
                            "duration_ms": int((time.time() - t0) * 1000)}
            rp = _run(spec["run"], workdir, TIMEOUT)
            rc, out, err = rp.returncode, rp.stdout, rp.stderr
        except subprocess.TimeoutExpired:
            return {"error": "执行超时（>%ds），已终止。死循环或等待输入都会触发。"
                    % TIMEOUT}
        images = []
        if lang == "python":
            for p in sorted(glob.glob(os.path.join(IMG_DIR, "fig_*.png"))):
                with open(p, "rb") as f:
                    images.append(base64.b64encode(f.read()).decode())
                os.remove(p)
        return {"stdout": out[:MAX_OUTPUT], "stderr": err[:MAX_OUTPUT],
                "images": images, "exit_code": rc,
                "duration_ms": int((time.time() - t0) * 1000)}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


# ============================================================================
# /extract 格式提取与转换（PyMuPDF / tesseract / pandoc）
# ============================================================================
# 与 /run 的沙盒策略一致：token 认证、独立临时目录、超时、输出截断。
# 依赖（deploy.sh 会装）：
#   pip install pymupdf weasyprint
#   apt install tesseract-ocr tesseract-ocr-chi-sim pandoc

EXTRACT_MAX_TEXT = 400_000   # 提取文本上限（字符）


def extract_pdf_text(data, filename):
    """PyMuPDF 逐页提文本层（秒级，替代 WebView+pdf.js）。"""
    import fitz
    doc = fitz.open(stream=data, filetype="pdf")
    pages = []
    for i, page in enumerate(doc):
        pages.append("--- 第 %d 页 ---\n%s" % (i + 1, page.get_text("text")))
    text = "\n\n".join(pages)[:EXTRACT_MAX_TEXT]
    return {"text": text, "pages": doc.page_count}


def extract_ocr(data, filename):
    """tesseract OCR：扫描版 PDF / 图片文字（chi_sim+eng）。"""
    with tempfile.NamedTemporaryFile(
            suffix=os.path.splitext(filename)[1] or ".png", delete=False) as f:
        f.write(data)
        f.flush()
        inpath = f.name
    outpath = inpath + "_out"
    try:
        cp = subprocess.run(
            ["tesseract", inpath, outpath, "-l", "chi_sim+eng"],
            timeout=EXTRACT_TIMEOUT, capture_output=True)
        if cp.returncode != 0:
            return {"error": "OCR 失败: %s" % (cp.stderr or "tesseract 未安装").strip()}
        with open(outpath + ".txt", encoding="utf-8", errors="replace") as f:
            text = f.read()[:EXTRACT_MAX_TEXT]
        return {"text": text}
    finally:
        for p in (inpath, outpath + ".txt"):
            try:
                os.remove(p)
            except OSError:
                pass


def _md_convert(data, filename, out_ext, extra_args):
    workdir = tempfile.mkdtemp(prefix="mixconv_")
    inpath = os.path.join(workdir, "input.md")
    outpath = inpath + out_ext
    try:
        with open(inpath, "wb") as f:
            f.write(data)
        env = dict(_MIN_ENV)
        # nobody 用户对 / 无写权限；pandoc 建临时文件需要可写的 TMPDIR + cwd。
        # weasyprint 是 pip 装的 CLI，在 /usr/local/bin（不在 _MIN_ENV 的 PATH）。
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin"
        env["TMPDIR"] = workdir
        cp = subprocess.run(
            ["pandoc", inpath, "-o", outpath] + extra_args,
            cwd=workdir, env=env,
            timeout=EXTRACT_TIMEOUT, capture_output=True)
        if cp.returncode != 0:
            return {"error": "pandoc 失败: %s" % (cp.stderr or "pandoc 未安装").strip()}
        with open(outpath, "rb") as f:
            out_bytes = f.read()
        return {
            "output": base64.b64encode(out_bytes).decode(),
            "output_name": os.path.splitext(filename)[0] + out_ext,
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def extract_md_to_docx(data, filename):
    return _md_convert(data, filename, ".docx", [])


def extract_md_to_pdf(data, filename):
    # weasyprint 引擎：纯 Python CSS 渲染，避免装整套 texlive。
    return _md_convert(data, filename, ".pdf", ["--pdf-engine=weasyprint"])


def extract(task, data, filename):
    handlers = {
        "pdf_text": extract_pdf_text,
        "ocr": extract_ocr,
        "md_to_docx": extract_md_to_docx,
        "md_to_pdf": extract_md_to_pdf,
    }
    fn = handlers.get(task)
    if fn is None:
        return {"error": "不支持的 extract 任务: %s（可选: %s）"
                % (task, ", ".join(sorted(handlers)))}
    try:
        return fn(data, filename)
    except Exception as e:
        return {"error": "%s: %s" % (task, e)}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/health"):
            self._send(200, {"ok": True, "service": "MIX remote runner",
                             "languages": sorted(LANGS)})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/extract":
            return self._handle_extract()
        if self.path != "/run":
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > MAX_BODY:
                return self._send(413, {"error": "请求体过大"})
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self._send(400, {"error": "JSON 解析失败"})
        if body.get("token") != TOKEN:
            return self._send(401, {"error": "token 错误"})
        lang = str(body.get("language", "")).lower()
        lang = ALIASES.get(lang, lang)
        code = str(body.get("code", ""))
        with _lock:
            result = execute(lang, code)
        self._send(200, result)

    def _handle_extract(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > MAX_EXTRACT_BODY:
                return self._send(413, {"error": "请求体过大（>30MB 原始文件）"})
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self._send(400, {"error": "JSON 解析失败"})
        if body.get("token") != TOKEN:
            return self._send(401, {"error": "token 错误"})
        task = str(body.get("task", ""))
        filename = str(body.get("filename", "file"))
        try:
            data = base64.b64decode(body.get("data", ""))
        except Exception:
            return self._send(400, {"error": "data 不是合法 base64"})
        with _lock:
            result = extract(task, data, filename)
        self._send(200, result)

    def log_message(self, *args):
        pass  # 静默，避免日志刷屏


if __name__ == "__main__":
    if TOKEN == "changeme":
        print("⚠️  未设置 MIX_RUN_TOKEN，使用默认 token 'changeme'（公网极不安全！）")
    print("MIX remote runner listening on 0.0.0.0:%d" % PORT)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
