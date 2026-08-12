/// GitHub 服务：PAT token 持久化 + GitHub REST API 客户端。
///
/// agent 通过 GitHub 功能区管理远程仓库（列/克隆/推送）。
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String _tokenKey = 'github_pat_token';
const String _usernameKey = 'github_username';

/// GitHub 凭据。
class GitHubCredentials {
  final String token;
  final String username;

  const GitHubCredentials({required this.token, required this.username});

  bool get isConfigured => token.isNotEmpty;
}

/// 读取已保存的 GitHub 凭据。
Future<GitHubCredentials?> loadGitHubCredentials() async {
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString(_tokenKey) ?? '';
  if (token.isEmpty) return null;
  final username = prefs.getString(_usernameKey) ?? '';
  return GitHubCredentials(token: token, username: username);
}

/// 保存 GitHub 凭据。
Future<void> saveGitHubCredentials({
  required String token,
  String? username,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_tokenKey, token);
  if (username != null && username.isNotEmpty) {
    await prefs.setString(_usernameKey, username);
  }
}

/// 清除 GitHub 凭据。
Future<void> clearGitHubCredentials() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_tokenKey);
  await prefs.remove(_usernameKey);
}

/// GitHub 仓库信息。
class GitHubRepo {
  final String fullName;
  final String name;
  final String description;
  final String? cloneUrl;
  final String? sshUrl;
  final int stars;
  final bool isFork;
  final String? language;
  final String? updatedAt;

  const GitHubRepo({
    required this.fullName,
    required this.name,
    this.description = '',
    this.cloneUrl,
    this.sshUrl,
    this.stars = 0,
    this.isFork = false,
    this.language,
    this.updatedAt,
  });

  factory GitHubRepo.fromJson(Map<String, dynamic> j) {
    return GitHubRepo(
      fullName: j['full_name'] as String? ?? '',
      name: j['name'] as String? ?? '',
      description: j['description'] as String? ?? '',
      cloneUrl: j['clone_url'] as String?,
      sshUrl: j['ssh_url'] as String?,
      stars: j['stargazers_count'] as int? ?? 0,
      isFork: j['fork'] as bool? ?? false,
      language: j['language'] as String?,
      updatedAt: j['updated_at'] as String?,
    );
  }
}

/// 拉取当前用户可见的仓库列表。
Future<List<GitHubRepo>> fetchUserRepos(String token) async {
  const perPage = 100;
  final uri = Uri.parse(
      'https://api.github.com/user/repos?per_page=$perPage&sort=updated');
  final resp = await http.get(uri, headers: {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'hermes-agent',
  }).timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) {
    throw GitHubApiException(
        'Failed to list repos: HTTP ${resp.statusCode} ${resp.body.substring(0, resp.body.length > 120 ? 120 : resp.body.length)}');
  }
  final data = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
  return [
    for (final r in data)
      if (r is Map<String, dynamic>) GitHubRepo.fromJson(r),
  ];
}

/// 拉取仓库最近的 CI workflow 运行。
Future<List<Map<String, dynamic>>> fetchWorkflowRuns(
  String token,
  String repo, {
  int perPage = 5,
}) async {
  final uri = Uri.parse(
      'https://api.github.com/repos/$repo/actions/runs?per_page=$perPage');
  final resp = await http.get(uri, headers: {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'mix-agent',
  }).timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) {
    throw GitHubApiException(
        '读取 CI 运行失败: HTTP ${resp.statusCode} ${resp.body.substring(0, resp.body.length > 120 ? 120 : resp.body.length)}');
  }
  final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  final runs = data['workflow_runs'] as List? ?? const [];
  return [
    for (final r in runs)
      if (r is Map<String, dynamic>)
        {
          'run_id': r['id'],
          'name': r['name'],
          'status': r['status'],
          'conclusion': r['conclusion'],
          'head_sha': (r['head_sha'] as String? ?? '').substring(0, 7),
          'created_at': r['created_at'],
          'html_url': r['html_url'],
        },
  ];
}

/// 拉取某次运行的所有 job（含每步结论），用于定位失败的 job/step。
Future<List<Map<String, dynamic>>> fetchRunJobs(
  String token,
  String repo,
  int runId,
) async {
  final uri = Uri.parse(
      'https://api.github.com/repos/$repo/actions/runs/$runId/jobs');
  final resp = await http.get(uri, headers: {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'mix-agent',
  }).timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) {
    throw GitHubApiException('读取 job 失败: HTTP ${resp.statusCode}');
  }
  final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  final jobs = data['jobs'] as List? ?? const [];
  return [
    for (final j in jobs)
      if (j is Map<String, dynamic>)
        {
          'name': j['name'],
          'conclusion': j['conclusion'],
          'status': j['status'],
          'steps': [
            for (final s in (j['steps'] as List? ?? const []))
              if (s is Map<String, dynamic>)
                {'name': s['name'], 'conclusion': s['conclusion']},
          ],
        },
  ];
}

/// 下载某次运行的日志 zip，解压后提取指定 job/step 的文本（失败定位）。
Future<String> fetchRunStepLog(
  String token,
  String repo,
  int runId,
  String jobName,
  String stepName,
) async {
  final uri = Uri.parse(
      'https://api.github.com/repos/$repo/actions/runs/$runId/logs');
  final resp = await http.get(uri, headers: {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'mix-agent',
  }).timeout(const Duration(minutes: 2));
  if (resp.statusCode != 200) {
    throw GitHubApiException('下载 CI 日志失败: HTTP ${resp.statusCode}');
  }
  final archive = ZipDecoder().decodeBytes(resp.bodyBytes);
  // zip 内文件形如 "<job>/<step>.txt"。
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final name = f.name.replaceAll('\\', '/');
    if (name == '$jobName/$stepName.txt' ||
        name.endsWith('/$stepName.txt')) {
      return utf8.decode(f.content as List<int>, allowMalformed: true);
    }
  }
  return '（在日志包中未找到 $jobName/$stepName.txt）';
}

/// 校验 token 并返回用户名。
Future<String> fetchGitHubUsername(String token) async {
  final uri = Uri.parse('https://api.github.com/user');
  final resp = await http.get(uri, headers: {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'hermes-agent',
  }).timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) {
    throw GitHubApiException('Token invalid: HTTP ${resp.statusCode}');
  }
  final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  return data['login'] as String? ?? '';
}

/// GitHub API 异常。
class GitHubApiException implements Exception {
  final String message;
  GitHubApiException(this.message);
  @override
  String toString() => message;
}
