#!/usr/bin/env bash
# MIX 云端代码执行服务器一键部署（Ubuntu/Debian）
# 用法: sudo bash deploy.sh [端口] [token]
#   - 端口默认 8123（避开已占用的 80）
#   - token 不传则自动生成随机串，务必保存好，App 设置里要填
set -euo pipefail

PORT="${1:-8123}"
TOKEN="${2:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(head -c 24 /dev/urandom | base64 | tr -d '=+/')"
fi

echo "==== MIX remote runner 部署 ===="
echo "端口 : $PORT"
echo "Token: $TOKEN  ← 保存好，App 设置里填这个"
echo ""

# 1. 拷贝程序
mkdir -p /opt/mix-runner
cp "$(dirname "$0")/server.py" /opt/mix-runner/server.py

# 1.5 格式转换依赖（/extract 端点）：PyMuPDF + weasyprint(pip)，
#     tesseract(中文) + pandoc(apt)。体积较大，首次部署需几分钟。
echo "-- 安装 /extract 依赖（PyMuPDF / tesseract / pandoc / weasyprint）--"
pip3 install --break-system-packages --quiet pymupdf weasyprint 2>/dev/null \
  || pip3 install --quiet pymupdf weasyprint
apt-get install -y -qq tesseract-ocr tesseract-ocr-chi-sim pandoc >/dev/null 2>&1 \
  || apt-get install -y -qq tesseract-ocr pandoc

# 2. matplotlib 缓存目录（nobody 用户无 $HOME，必须指定）
mkdir -p /tmp/mplconfig && chmod 777 /tmp/mplconfig

# 3. systemd 服务（沙盒加固：文件系统只读/资源限制/禁止提权）
cat > /etc/systemd/system/mix-runner.service <<EOF
[Unit]
Description=MIX remote code runner (sandboxed)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/mix-runner/server.py
Environment=MIX_RUN_PORT=$PORT
Environment=MIX_RUN_TOKEN=$TOKEN
Environment=MIX_RUN_TIMEOUT=15
Environment=MPLCONFIGDIR=/tmp/mplconfig
Restart=always
RestartSec=2
User=nobody
NoNewPrivileges=true

# ── 沙盒加固 ─────────────────────────────
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectProc=invisible
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryMax=1024M
CPUQuota=50%
TasksMax=64
LimitNOFILE=128

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mix-runner
sleep 1
systemctl --no-pager status mix-runner --lines=0

echo ""
echo "==== 本机自测 ===="
curl -s -X POST "http://127.0.0.1:$PORT/run" \
  -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"language\":\"python\",\"code\":\"print(1+1)\"}"
echo ""

echo ""
echo "==== 完成 ===="
echo "如果公网访问不通，检查："
echo "  1. 云厂商安全组/防火墙放行 TCP $PORT"
echo "  2. 本机 ufw: sudo ufw allow $PORT/tcp"
echo "  3. 测试: curl -X POST http://<公网IP>:$PORT/run ...（同上）"
