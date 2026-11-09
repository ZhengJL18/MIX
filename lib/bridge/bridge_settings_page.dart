/// 桥接配置页：在 App 内填服务器地址与 token，并做连通性自检。
///
/// 没有这一页，装上 APK 后只能改代码才能配置 —— 那是死路。
library;

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'bridge_config.dart';

class BridgeSettingsPage extends StatefulWidget {
  const BridgeSettingsPage({super.key});

  @override
  State<BridgeSettingsPage> createState() => _BridgeSettingsPageState();
}

class _BridgeSettingsPageState extends State<BridgeSettingsPage> {
  final _baseUrl = TextEditingController();
  final _token = TextEditingController();
  final _model = TextEditingController();
  String _harness = 'claude';
  bool _loading = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  static const _hints = {
    'claude': '走服务器上的 Claude Code CLI（需服务端配好 yoshub 中转）',
    'grok': '走 OpenAI 兼容协议（需服务端配 HARNESSD_GROK_*）',
    'mock': '回显测试用，不消耗 token',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await BridgeConfig.load();
    if (!mounted) return;
    setState(() {
      _baseUrl.text = cfg.baseUrl;
      _token.text = cfg.token;
      _model.text = cfg.model;
      _harness = cfg.harness.isEmpty ? 'claude' : cfg.harness;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _token.dispose();
    _model.dispose();
    super.dispose();
  }

  BridgeConfig _current() => BridgeConfig(
        baseUrl: _baseUrl.text.trim(),
        token: _token.text.trim(),
        harness: _harness,
        model: _model.text.trim(),
      );

  Future<void> _test() async {
    final cfg = _current();
    if (!cfg.isComplete) {
      setState(() {
        _testOk = false;
        _testResult = '地址与 token 都要填';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final client = BridgeClient(baseUrl: cfg.baseUrl, token: cfg.token);
    try {
      final ok = await client.health();
      if (!ok) {
        setState(() {
          _testOk = false;
          _testResult = '连不上 ${cfg.baseUrl}/healthz\n'
              '检查：服务是否运行 / 隧道或反代是否通 / token 是否正确';
        });
        return;
      }
      final sessions = await client.listSessions();
      setState(() {
        _testOk = true;
        _testResult = '连接成功 · 现有 ${sessions.length} 个会话';
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testResult = '失败：$e';
      });
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final cfg = _current();
    if (!cfg.isComplete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址与 token 必填')),
      );
      return;
    }
    await cfg.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器桥接配置'),
        actions: [
          TextButton(
            onPressed: _loading ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _baseUrl,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://harness.example.com 或 http://127.0.0.1:8787',
                    helperText: '只填到域名/端口，不要带 /v1',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _token,
                  decoration: const InputDecoration(
                    labelText: 'Token',
                    helperText: '服务端 /etc/harnessd/env 里的 HARNESSD_TOKEN',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _harness,
                  decoration: const InputDecoration(
                    labelText: 'Harness',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'claude', child: Text('claude')),
                    DropdownMenuItem(value: 'grok', child: Text('grok')),
                    DropdownMenuItem(value: 'mock', child: Text('mock（回显测试）')),
                  ],
                  onChanged: (v) => setState(() => _harness = v ?? 'claude'),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    _hints[_harness] ?? '',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: '模型（可留空）',
                    hintText: 'claude-opus-5-5 / deepseek-flash …',
                    helperText: '留空用服务端默认',
                    border: OutlineInputBorder(),
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_check),
                      label: const Text('测试连接'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save),
                      label: const Text('保存'),
                    ),
                  ],
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (_testOk ? Colors.green : scheme.error).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        fontSize: 13,
                        color: _testOk ? Colors.green.shade800 : scheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  '手机连云服务器的三种方式：\n'
                  '1. Cloudflare Tunnel → https://harness.<你的域名>\n'
                  '2. Caddy/nginx 反代 + 证书 → https://<你的域名>\n'
                  '3. 开发调试：USB 反代到手机（adb reverse tcp:8787 tcp:8787）后填 http://127.0.0.1:8787',
                  style: TextStyle(fontSize: 12, color: scheme.outline, height: 1.6),
                ),
              ],
            ),
    );
  }
}
