/// 桥接层配置：服务地址与 token。
///
/// 与 MIXConfig（LLM 厂商配置）分开存：桥接是"连自己服务器"，
/// 与"用哪家模型"是两件事。
library;

import 'package:shared_preferences/shared_preferences.dart';

class BridgeConfig {
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

  static Future<BridgeConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return BridgeConfig(
      baseUrl: p.getString(_kBaseUrl) ?? '',
      token: p.getString(_kToken) ?? '',
      harness: p.getString(_kHarness) ?? 'claude',
      model: p.getString(_kModel) ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, baseUrl);
    await p.setString(_kToken, token);
    await p.setString(_kHarness, harness);
    await p.setString(_kModel, model);
  }

  BridgeConfig copyWith({String? baseUrl, String? token, String? harness, String? model}) =>
      BridgeConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        token: token ?? this.token,
        harness: harness ?? this.harness,
        model: model ?? this.model,
      );
}
