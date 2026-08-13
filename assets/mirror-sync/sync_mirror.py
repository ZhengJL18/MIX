#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MIX 更新镜像同步脚本：从 GitHub Releases 拉最新 apk，写 latest.json。

替代服务器上停更的旧同步脚本（旧脚本只同步 apk、且已停在 build 135）。
Linux 桌面版已停止维护（2026-08），本脚本只同步 apk，供 Android 客户端走国内镜像。

部署（云服务器 43.139.179.58，nginx 静态托管 /update 目录）：

    1. 把本脚本放到服务器（如 /opt/mix-runner/sync_mirror.py）
    2. 确认 nginx 的 update 目录（latest.json 所在绝对路径），设为 MIX_UPDATE_DIR
    3. 加 cron，每 10 分钟一次（匿名 GitHub API 限流 60/小时 → 10 分钟 = 6/小时，安全）：
       */10 * * * * MIX_UPDATE_DIR=/var/www/html/update python3 /opt/mix-runner/sync_mirror.py >> /var/log/mix-sync.log 2>&1

可选：
    - GITHUB_TOKEN：GitHub PAT，避免匿名限流，可提到每 5 分钟
    - MIX_PUBLIC_BASE：镜像对外 URL 根（默认 http://43.139.179.58/update）
"""
import json
import os
import hashlib
import datetime
import urllib.request

REPO = 'ZhengJL18/MIX'
API = f'https://api.github.com/repos/{REPO}/releases/latest'
# nginx 静态托管的 update 目录（latest.json 所在绝对路径）
UPDATE_DIR = os.environ.get('MIX_UPDATE_DIR', '/var/www/html/update')
# 镜像对外 URL 根（写入 latest.json 的 apk_url）
PUBLIC_BASE = os.environ.get('MIX_PUBLIC_BASE', 'http://43.139.179.58/update')
# 可选 GitHub PAT，避免匿名 API 限流（60/小时）
GITHUB_TOKEN = os.environ.get('GITHUB_TOKEN', '')


def _fetch_json(url):
    headers = {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'MIX-mirror-sync',
    }
    if GITHUB_TOKEN:
        headers['Authorization'] = f'token {GITHUB_TOKEN}'
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def _download(url, dest):
    req = urllib.request.Request(url, headers={'User-Agent': 'MIX-mirror-sync'})
    with urllib.request.urlopen(req, timeout=600) as r, open(dest, 'wb') as f:
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            f.write(chunk)


def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    os.makedirs(UPDATE_DIR, exist_ok=True)
    rel = _fetch_json(API)
    tag = rel.get('tag_name', '')
    if not tag:
        return
    try:
        build = int(tag.rsplit('+', 1)[-1])
    except ValueError:
        build = 0

    apk = None
    for a in rel.get('assets', []):
        name = a.get('name', '')
        if name.endswith('.apk'):
            apk = a
            break

    manifest = {
        'version': tag.lstrip('v'),
        'build': build,
        'notes': rel.get('body', ''),
        'updated_at': datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
    }

    # apk（Android）
    if apk:
        path = os.path.join(UPDATE_DIR, 'MIX.apk')
        _download(apk['browser_download_url'], path + '.tmp')
        os.replace(path + '.tmp', path)
        manifest['apk_url'] = f'{PUBLIC_BASE}/MIX.apk'
        manifest['size'] = apk.get('size', os.path.getsize(path))
        manifest['sha256'] = _sha256(path)

    # 原子写 latest.json（先 tmp 再 replace，避免读到半截）
    tmp = os.path.join(UPDATE_DIR, 'latest.json.tmp')
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    os.replace(tmp, os.path.join(UPDATE_DIR, 'latest.json'))
    print(f"[sync] build={build} apk={'yes' if apk else 'no'}")


if __name__ == '__main__':
    main()
