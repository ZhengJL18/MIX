/// 游标持久化：记住每个会话收到过的最新 seq。
///
/// 这是「断点重续」在客户端的一半 —— 进程被杀、断网、切后台都靠它续上传。
/// 用 SharedPreferences 而不是数据库：量极小（每会话一个 int），读写同步即可。
library;

import 'package:shared_preferences/shared_preferences.dart';

class BridgeCursorStore {
  static const String _prefix = 'bridge_cursor_';

  /// 读取会话游标（无记录返回 0，表示从会话开头补）。
  static Future<int> load(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_prefix$sessionId') ?? 0;
  }

  /// 保存游标。调用方应在每收到一条事件后调用（高频但极轻）。
  static Future<void> save(String sessionId, int seq) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_prefix$sessionId', seq);
  }

  /// 清空游标（会话被删除或需要从头重放时用）。
  static Future<void> clear(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$sessionId');
  }
}
