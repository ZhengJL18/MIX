/// 桥接层配置：服务地址与 token。
///
/// 与 MIXConfig（LLM 厂商配置）分开存：桥接是"连自己服务器"，
/// 与"用哪家模型"是两件事。
library;

import 'package:shared_preferences/shared_preferences.dart';

class BridgeConfig {
  /// 未单独保存地址时使用的云端 harness。
  static const defaultBaseUrl = 'https://harness.312233.xyz';

  /// 服务端地址，如 `http://127.0.0.1:8787`（经 SSH 隧道）或反代地址。
  final String baseUrl;

  /// 与服务端 /etc/harnessd/env 里 HARNESSD_TOKEN 一致。
  final String token;

  /// 默认 harness（claude / mock）。
  final String harness;

  /// 默认模型（留空用服务端默认）。
  final String model;

  const BridgeConfig({
    required this.baseUrl,
    required this.token,
    this.harness = 'claude',
    this.model = '',
  });

  bool get isComplete => baseUrl.isNotEmpty && token.isNotEmpty;

  static const _kBaseUrl = 'bridge_base_url';
  static const _kToken = 'bridge_token';
  static const _kHarness = 'bridge_harness';
  static const _kModel = 'bridge_model';
  static const _kSession = 'bridge_session_id';

  /// 空地址落到 [defaultBaseUrl]，并去掉末尾斜杠，避免拼出 `//v1`。
  static String normalizeBaseUrl(String? raw) {
    var v = (raw ?? '').trim();
    if (v.isEmpty) return defaultBaseUrl;
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  static Future<BridgeConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return BridgeConfig(
      baseUrl: normalizeBaseUrl(p.getString(_kBaseUrl)),
      token: (p.getString(_kToken) ?? '').trim(),
      harness: p.getString(_kHarness) ?? 'claude',
      model: p.getString(_kModel) ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, normalizeBaseUrl(baseUrl));
    await p.setString(_kToken, token.trim());
    await p.setString(_kHarness, harness);
    await p.setString(_kModel, model);
  }

  /// 主聊天要续上的 harness 会话。没有则新建。
  static Future<String?> loadSessionId() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_kSession);
    if (id == null || id.isEmpty) return null;
    return id;
  }

  static Future<void> saveSessionId(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSession, id);
  }

  static Future<void> clearSessionId() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kSession);
  }

  BridgeConfig copyWith({String? baseUrl, String? token, String? harness, String? model}) =>
      BridgeConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        token: token ?? this.token,
        harness: harness ?? this.harness,
        model: model ?? this.model,
      );
}
