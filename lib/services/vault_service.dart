/// 云端保险柜：注册/登录后，用 AES 加密备份包上传/下载到云服务器。
///
/// - 账号体系：注册/登录（保险柜名 + 密码），服务器返回会话 token。
/// - 备份数据用用户密钥 AES 加密（服务器只存密文）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hermes 官方云保险柜地址。
/// nginx 反代到 8741，App 直接走 80 端口（无需安全组放行 8741）。
/// 用户可覆盖（支持自建服务器）。
const String officialVaultUrl = 'http://43.139.179.58';

/// 保险柜账号配置（服务器 + 保险柜名 + 会话 token）。
class VaultConfig {
  final String serverUrl;
  final String accountName; // 保险柜名（登录后）。
  final String sessionToken; // 会话 token（登录后服务器返回）。

  const VaultConfig({
    required this.serverUrl,
    required this.accountName,
    required this.sessionToken,
  });

  bool get isComplete => serverUrl.isNotEmpty && accountName.isNotEmpty && sessionToken.isNotEmpty;
}

/// 读取已登录的保险柜配置。
Future<VaultConfig?> loadVaultConfig() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('vault_server') ?? '';
  final name = prefs.getString('vault_account') ?? '';
  final token = prefs.getString('vault_token') ?? '';
  if (url.isEmpty || name.isEmpty || token.isEmpty) {
    return null;
  }
  return VaultConfig(
    serverUrl: url,
    accountName: name,
    sessionToken: token,
  );
}

/// 保存保险柜登录态。
Future<void> saveVaultConfig(VaultConfig cfg) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('vault_server', cfg.serverUrl);
  await prefs.setString('vault_account', cfg.accountName);
  await prefs.setString('vault_token', cfg.sessionToken);
}

/// 清除保险柜登录态。
Future<void> clearVaultConfig() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('vault_server');
  await prefs.remove('vault_account');
  await prefs.remove('vault_token');
}

/// 注册保险柜账号。
/// 成功返回会话 token；失败抛 [VaultAuthException]。
Future<String> registerVaultAccount({
  required String serverUrl,
  required String name,
  required String password,
}) async {
  final uri = Uri.parse('$serverUrl/auth/register');
  final resp = await http
      .post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'password': password}),
      )
      .timeout(const Duration(seconds: 20));
  final data = _tryDecode(resp.body);
  if (resp.statusCode != 200) {
    throw VaultAuthException(data?['error'] as String? ?? '注册失败：HTTP ${resp.statusCode}');
  }
  return data?['token'] as String? ?? '';
}

/// 登录保险柜账号。
/// 成功返回会话 token；失败抛 [VaultAuthException]。
Future<String> loginVaultAccount({
  required String serverUrl,
  required String name,
  required String password,
}) async {
  final uri = Uri.parse('$serverUrl/auth/login');
  final resp = await http
      .post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'password': password}),
      )
      .timeout(const Duration(seconds: 20));
  final data = _tryDecode(resp.body);
  if (resp.statusCode != 200) {
    throw VaultAuthException(data?['error'] as String? ?? '登录失败：HTTP ${resp.statusCode}');
  }
  return data?['token'] as String? ?? '';
}

Map<String, dynamic>? _tryDecode(String body) {
  try {
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// 保险柜认证异常（注册/登录失败）。
class VaultAuthException implements Exception {
  final String message;
  VaultAuthException(this.message);
  @override
  String toString() => message;
}


/// 备份扫描跳过的目录名（克隆的 git 仓库根 + 已知重型/无关目录）。
/// 此前 listSync(recursive: true) 会把 documents 里 clone 的 GitHub 仓库
/// （github/hermes-app/third_party 等）整库塞进备份——一个笔记备份被撑到
/// 15MB 且夹带源码。含 .git 的目录视为仓库根整体跳过。
const Set<String> _backupSkipDirNames = {
  '.git',
  '.dart_tool',
  'build',
  'third_party',
  'site',
};

bool _isRepoRoot(String path) => Directory('$path/.git').existsSync();

/// 把 App 数据打包成 JSON 备份（state.db + 记忆 + 技能 + 配置）。
///
/// [includePaths] 只备份这些顶层相对路径（如 ['notes','memories']）；空 = 全备份。
/// [skipDb] 测试用：跳过数据库读取。
Future<Map<String, dynamic>> buildBackupPayload({
  List<String> includePaths = const [],
}) async {
  final payload = <String, dynamic>{};
  final dir = await getApplicationDocumentsDirectory();
  final now = DateTime.now().toIso8601String();

  // 会话库（state.db）→ base64。
  final dbFile = File('${dir.path}/state.db');
  if (dbFile.existsSync()) {
    final bytes = await dbFile.readAsBytes();
    payload['state_db'] = base64Encode(bytes);
  }

  // 记忆 + 技能：扫描 documents 下相关文件，跳过仓库根/重型目录。
  final files = <String, String>{};
  final pending = <Directory>[
    if (includePaths.isEmpty)
      dir
    else
      for (final rel in includePaths)
        if (rel.isNotEmpty) Directory('${dir.path}/$rel'),
  ];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    final baseName = current.path.split('/').last;
    if (_backupSkipDirNames.contains(baseName) || _isRepoRoot(current.path)) {
      continue;
    }
    for (final entry in current.listSync(followLinks: false)) {
      if (entry is Directory) {
        pending.add(entry);
      } else if (entry is File) {
        final name = entry.path.split('/').last;
        // 记忆 / 技能 / 配置类文本文件。
        if (name.endsWith('.md') ||
            name.endsWith('.yaml') ||
            name.endsWith('.yml')) {
          try {
            files[entry.path.substring(dir.path.length + 1)] =
                await entry.readAsString();
          } catch (_) {}
        }
      }
    }
  }
  payload['files'] = files;
  payload['backed_up_at'] = now;

  return payload;
}

/// AES-256-CBC 加密数据（PBKDF2 派生密钥，随机 IV）。
Uint8List encryptPayload(Map<String, dynamic> payload, String secret) {
  final plaintext = utf8.encode(jsonEncode(payload));

  // 派生 32 字节密钥 + 16 字节 IV。
  final random = Random.secure();
  final salt = Uint8List(16);
  for (var i = 0; i < salt.length; i++) {
    salt[i] = random.nextInt(256);
  }
  final iv = Uint8List(16);
  for (var i = 0; i < iv.length; i++) {
    iv[i] = random.nextInt(256);
  }

  final key = _deriveKey(secret, salt);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));

  // PKCS7 填充。
  final blockSize = 16;
  final paddedLen = ((plaintext.length / blockSize).ceil()) * blockSize;
  final padded = Uint8List(paddedLen)..setAll(0, plaintext);
  for (var i = plaintext.length; i < paddedLen; i++) {
    padded[i] = (blockSize - plaintext.length % blockSize) & 0xff;
  }

  final out = Uint8List(paddedLen);
  var offset = 0;
  while (offset < paddedLen) {
    offset += cipher.processBlock(padded, offset, out, offset);
  }

  // 格式：[salt(16) | iv(16) | ciphertext]。
  final result = Uint8List(16 + 16 + out.length)
    ..setAll(0, salt)
    ..setAll(16, iv)
    ..setAll(32, out);
  return result;
}

/// AES-256-CBC 解密。
Map<String, dynamic> decryptPayload(Uint8List data, String secret) {
  if (data.length < 32) {
    throw const FormatException('加密数据损坏');
  }
  final salt = Uint8List.sublistView(data, 0, 16);
  final iv = Uint8List.sublistView(data, 16, 32);
  final ciphertext = Uint8List.sublistView(data, 32);

  final key = _deriveKey(secret, salt);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));

  final out = Uint8List(ciphertext.length);
  var offset = 0;
  while (offset + 16 <= ciphertext.length) {
    offset += cipher.processBlock(ciphertext, offset, out, offset);
  }

  // 去 PKCS7 填充。
  var padLen = out.isNotEmpty ? out[out.length - 1] : 0;
  if (padLen < 1 || padLen > 16 || padLen > out.length) {
    padLen = 0;
  }
  final plaintext = utf8.decode(out.sublist(0, out.length - padLen));
  return jsonDecode(plaintext) as Map<String, dynamic>;
}

/// PBKDF2-HMAC-SHA256 派生密钥。
Uint8List _deriveKey(String secret, Uint8List salt) {
  final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, 60000, 32));
  return pbkdf2.process(utf8.encode(secret));
}

/// 上传备份（覆盖该账号保险柜）。
Future<void> uploadBackup(VaultConfig cfg, Uint8List encrypted) async {
  final uri = Uri.parse('${cfg.serverUrl}/vault');
  final resp = await http
      .put(
        uri,
        headers: {
          'Content-Type': 'application/octet-stream',
          'X-Auth-Token': cfg.sessionToken,
        },
        body: encrypted,
      )
      .timeout(const Duration(seconds: 30));
  if (resp.statusCode == 401) {
    throw HttpException('登录已过期，请重新登录');
  }
  if (resp.statusCode != 200) {
    throw HttpException('上传失败：HTTP ${resp.statusCode} ${resp.body}');
  }
}

/// 下载备份（读取该账号保险柜密文）。
Future<Uint8List> downloadBackup(VaultConfig cfg) async {
  final uri = Uri.parse('${cfg.serverUrl}/vault');
  final resp = await http
      .get(
        uri,
        headers: {
          'X-Auth-Token': cfg.sessionToken,
        },
      )
      .timeout(const Duration(seconds: 30));
  if (resp.statusCode == 401) {
    throw HttpException('登录已过期，请重新登录');
  }
  if (resp.statusCode == 404) {
    throw HttpException('该保险柜还没有备份');
  }
  if (resp.statusCode != 200) {
    throw HttpException('下载失败：HTTP ${resp.statusCode} ${resp.body}');
  }
  return resp.bodyBytes;
}
