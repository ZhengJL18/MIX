# MIX 云端代码执行服务器

把笔记库代码块的执行从手机搬到服务器：App 发代码过来，服务器子进程跑完把
stdout / stderr / matplotlib 图片传回去。任意语言、任意 pip 包，不再受手机
arm64 wheel 和 APK 体积限制。

## 服务器要求

Ubuntu/Debian，Python 3.8+（一般自带）。执行各语言需要对应运行时：

```bash
sudo apt update
sudo apt install -y python3 python3-pip gcc nodejs sqlite3
# 需要跑 Java 再加：
sudo apt install -y openjdk-17-jdk-headless

# Python 科学计算库（云端核心价值：一次装齐，教学代码全都能跑）
# Ubuntu 24.04+ 的 pip 需要 --break-system-packages
sudo pip3 install --break-system-packages \
  numpy matplotlib networkx sympy scipy pandas
```

## 部署

```bash
sudo bash deploy.sh            # 端口默认 8123，自动生成随机 token
sudo bash deploy.sh 9000 mytoken   # 自定义端口和 token
```

部署后：
- systemd 服务 `mix-runner` 常驻，开机自启，崩溃自动重启
- 在云厂商安全组 + 本机防火墙放行对应 TCP 端口
- 自测：`curl -X POST http://127.0.0.1:8123/run -H 'Content-Type: application/json' -d '{"token":"<TOKEN>","language":"python","code":"print(1+1)"}'`

## App 端配置

MIX 设置里填：服务器地址 `http://<公网IP>:8123` + token（代码块未配置时
点「运行」也会弹出配置框）。

## 支持的协议

```
POST /run
{"token": "...", "language": "python|c|js|bash|java|sql", "code": "..."}

→ {"stdout": "...", "stderr": "...", "images": ["<base64 PNG>..."],
   "exit_code": 0, "duration_ms": 123, "error": null}
```

- python：自动注入 matplotlib Agg 后端，`plt.show()` 无需修改，画完自动回传图片
- c：gcc 编译后执行（-O2）
- java：自动识别 `public class` 名作为文件名
- sql：sqlite3 内存库执行
- 超时 15s 自动 kill（死循环/等待输入都会触发），执行串行防打满
- token 认证，缺省 token 为 `changeme`（务必改）
