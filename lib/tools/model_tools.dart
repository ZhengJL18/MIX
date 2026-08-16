/// 对应 `ref/hermes-agent/model_tools.py`（像素级复刻，核心数据流）。
///
/// 工具注册中心之上的薄编排层。每个 tools/ 工具文件通过
/// tools/registry.dart 的 registry.register() 自注册 schema、handler 和元数据。
/// 本模块提供 run_agent / cli / batch_runner 消费的公开 API。
///
/// ## Dart 适配（外围留接口）
/// - async bridging（asyncio 事件循环）：Dart async 原生，省略。
/// - 钩子/中间件链（hermes_cli.middleware、plugins pre_tool_call hook、ACP
///   edit_approval）：App 无插件系统，留接口。核心数据流完整保留。
/// - Tool Search bridge（tools/tool_search.py 渐进式披露）：未复刻，留
///   [skipToolSearchAssembly] 开关占位。核心工具从不延迟。
/// - execute_code / discord 动态 schema 重建：未复刻（App 无这些工具）。
/// - `_resolve_active_context_length`：App 用 model_metadata 估算，留 0。
library;

import 'dart:convert';

import 'registry.dart';
import 'schema_sanitizer.dart';
import 'tool_result_pruner.dart';
import 'toolsets.dart';

/// 进程内缓存：getToolDefinitions 的 memoized 结果。
final Map<Object?, List<Map<String, dynamic>>> _toolDefsCache = {};
const int _toolDefsCacheMax = 64;

/// 最近一次解析出的工具名（下游 schema 引用其他工具时用）。
List<String> _lastResolvedToolNames = [];
List<String> get lastResolvedToolNames => List.of(_lastResolvedToolNames);

/// 工具搜索 bridge 开关（未实现 Tool Search，恒 true 跳过组装）。
bool skipToolSearchAssemblyFlag = true;

/// 按 toolset 过滤获取工具定义，供模型 API 调用。
///
/// 所有工具必须是某 toolset 的一部分才可访问。
List<Map<String, dynamic>> getToolDefinitions({
  List<String>? enabledToolsets,
  List<String>? disabledToolsets,
  bool quietMode = false,
}) {
  // Fast path：memoized 结果（quiet 模式）。缓存键捕获参数级输入；registry
  // generation 捕获 registry 变更。
  // 键用字符串（join 后值相等），Dart List== 是引用相等，record 键会 100% miss。
  Object? cacheKey;
  if (quietMode) {
    final en = enabledToolsets != null
        ? (enabledToolsets.toSet().toList()..sort()).join(',')
        : null;
    final dis = (disabledToolsets != null && disabledToolsets.isNotEmpty)
        ? (disabledToolsets.toSet().toList()..sort()).join(',')
        : null;
    cacheKey = '$en|$dis|${registry.generation}';
    final cached = _toolDefsCache[cacheKey];
    if (cached != null) {
      _lastResolvedToolNames = [
        for (final t in cached) (t['function'] as Map)['name'] as String,
      ];
      return List.of(cached);
    }
  }

  final result = _computeToolDefinitions(enabledToolsets, disabledToolsets, quietMode);
  if (quietMode && cacheKey != null) {
    if (_toolDefsCache.length >= _toolDefsCacheMax) {
      _toolDefsCache.remove(_toolDefsCache.keys.first);
    }
    _toolDefsCache[cacheKey] = result;
    return List.of(result);
  }
  return result;
}

List<Map<String, dynamic>> _computeToolDefinitions(
  List<String>? enabledToolsets,
  List<String>? disabledToolsets,
  bool quietMode,
) {
  final toolsToInclude = <String>{};

  if (enabledToolsets != null) {
    final effectiveEnabled = List<String>.of(enabledToolsets);
    for (final toolsetName in effectiveEnabled) {
      if (validateToolset(toolsetName)) {
        toolsToInclude.addAll(resolveToolset(toolsetName));
      }
    }
  } else {
    // 默认：从所有工具集开始。
    for (final tsName in getToolsetNames()) {
      toolsToInclude.addAll(resolveToolset(tsName));
    }
  }

  // 始终把 disabled toolsets 作为末尾减法步骤应用。
  if (disabledToolsets != null && disabledToolsets.isNotEmpty) {
    for (final toolsetName in disabledToolsets) {
      if (validateToolset(toolsetName)) {
        final isPosture = getToolset(toolsetName)?.posture == true;
        if (toolsetName.startsWith('hermes-') || isPosture) {
          // Platform bundles（hermes-*）与 posture 工具集（如 coding）含
          // _HERMES_CORE_TOOLS，减整个会剥离 core。只减非 core 差集。
          final toRemove = bundleNonCoreTools(toolsetName);
          toolsToInclude.removeAll(toRemove);
        } else {
          toolsToInclude.removeAll(resolveToolset(toolsetName));
        }
      }
    }
  }

  // 向 registry 要 schema（只返回 check_fn 通过的工具）。
  var filteredTools = registry.getDefinitions(toolsToInclude, quiet: quietMode);

  _lastResolvedToolNames =
      filteredTools.map((t) => (t['function'] as Map)['name'] as String).toList();

  // 清洗 schema 兼容各家后端。
  filteredTools = sanitizeToolSchemas(filteredTools);

  // Tool Search bridge：未实现，直接返回。
  return filteredTools;
}

// =============================================================================
// Argument coercion
// =============================================================================

/// 把工具调用参数强制到其 JSON Schema 类型。
///
/// LLM 频繁把数字作为字符串（``"42"`` 而非 ``42``）、布尔作为字符串（``"true"``
/// 而非 ``true``）。当值是字符串但 schema 期望不同类型时尝试安全强制。强制失败
/// 保留原始值。
///
/// 处理 ``"type": "integer"``、``"type": "number"``、``"type": "boolean"`` 和
/// 联合类型（``"type": ["integer", "string"]``）。
///
/// 当 schema 声明 ``"type": "array"`` 时也把裸标量值包装进单元素列表。
Map<String, dynamic>? coerceToolArgs(String toolName, Map<String, dynamic>? args) {
  if (args == null || args.isEmpty) {
    return args;
  }
  var a = args;

  final schema = registry.getSchema(toolName);
  if (schema == null) {
    return args;
  }

  final parameters = schema['parameters'];
  if (parameters is! Map<String, dynamic>) {
    return args;
  }
  final properties = parameters['properties'];
  if (properties is! Map<String, dynamic>) {
    return args;
  }

  // 模型看到的是 SANITIZED schema —— 违反 provider 模式的属性键（如
  // Cloudflare 的 ``issue_class~neq``）在请求前被重命名。先把任何净化键映射回
  // registry 原始 wire 名，再查 schema / dispatch。
  // Python 版包 try/except: pass —— unrename 异常绝不断 dispatch。
  try {
    final renamed = unrenameToolArgs(parameters, a);
    if (renamed is Map<String, dynamic>) {
      a = renamed;
    }
  } catch (_) {
    // unrename 失败 → 用原始 a。
  }

  for (final key in a.keys.toList()) {
    final value = a[key];
    final propSchema = properties[key];
    if (propSchema is! Map<String, dynamic>) {
      continue;
    }
    final expected = propSchema['type'];

    // schema 声明 ``array`` 时包装裸非列表值。
    if (expected == 'array' && value != null && value is! List) {
      if (value is String) {
        final coerced = _coerceValue(value, expected, schema: propSchema);
        if (!identical(coerced, value)) {
          // _coerce_value 处理了（JSON 解析列表或可空 "null" → null）。
          a[key] = coerced;
          continue;
        }
        // 字符串看起来像 JSON 数组但解析失败 —— 警告而非静默包装。
        if (value.trim().startsWith('[')) {
          // logger.warning(...)
        }
        a[key] = [value];
        continue;
      }
      a[key] = [value];
      continue;
    }

    if (value is! String) {
      // 递归进已原生容器，使 JSON 编码*元素*（数组项）和*子字段*（嵌套对象
      // 属性）也被归一化。
      if (expected == 'array' && value is List) {
        a[key] = _normalizeJsonStringsForSchema(value, propSchema);
      } else if (expected == 'object' && value is Map<String, dynamic>) {
        a[key] = _normalizeJsonStringsForSchema(value, propSchema);
      }
      continue;
    }
    if (expected == null && !_schemaAllowsNull(propSchema)) {
      continue;
    }
    final coerced = _coerceValue(value, expected, schema: propSchema);
    if (!identical(coerced, value)) {
      a[key] = coerced;
      if (coerced is List || coerced is Map) {
        a[key] = _normalizeJsonStringsForSchema(coerced, propSchema);
      }
    }
  }

  return a;
}

bool _schemaAcceptsKind(dynamic schema, String kind) {
  if (schema is! Map<String, dynamic>) {
    return false;
  }
  final t = schema['type'];
  if (t == kind || (t is List && t.contains(kind))) {
    return true;
  }
  for (final unionKey in ['anyOf', 'oneOf', 'allOf']) {
    final branches = schema[unionKey];
    if (branches is List &&
        branches.any((b) => _schemaAcceptsKind(b, kind))) {
      return true;
    }
  }
  return false;
}

/// 递归解析 schema 期望为数组或对象的 JSON 编码字符串值。
dynamic _normalizeJsonStringsForSchema(dynamic value, dynamic schema) {
  if (schema is! Map<String, dynamic>) {
    return value;
  }

  // 把 JSON 编码字符串解析进 schema 期望的容器。
  if (value is String) {
    final trimmed = value.trim();
    final expectsArray = _schemaAcceptsKind(schema, 'array');
    final expectsObject = _schemaAcceptsKind(schema, 'object');
    if ((expectsArray && trimmed.startsWith('[')) ||
        (expectsObject && trimmed.startsWith('{'))) {
      dynamic parsed;
      try {
        parsed = jsonDecode(trimmed);
      } catch (_) {
        return value;
      }
      if (parsed is List && expectsArray) {
        value = parsed;
      } else if (parsed is Map<String, dynamic> && expectsObject) {
        value = parsed;
      } else {
        return value;
      }
    } else {
      return value;
    }
  }

  // 用 ``items`` schema 递归进列表项。
  if (value is List) {
    final itemsSchema = schema['items'];
    if (itemsSchema is! Map<String, dynamic>) {
      return value;
    }
    var changed = false;
    final out = <dynamic>[];
    for (final item in value) {
      final nxt = _normalizeJsonStringsForSchema(item, itemsSchema);
      changed = changed || !identical(nxt, item);
      out.add(nxt);
    }
    return changed ? out : value;
  }

  // 用每个属性的 schema 递归进对象属性。
  if (value is Map<String, dynamic>) {
    final props = schema['properties'];
    if (props is! Map<String, dynamic>) {
      return value;
    }
    var changed = false;
    final out = Map<String, dynamic>.from(value);
    props.forEach((k, propSchema) {
      if (!value.containsKey(k) || propSchema is! Map<String, dynamic>) {
        return;
      }
      final nxt = _normalizeJsonStringsForSchema(value[k], propSchema);
      if (!identical(nxt, value[k])) {
        out[k] = nxt;
        changed = true;
      }
    });
    return changed ? out : value;
  }

  return value;
}

dynamic _coerceValue(String value, dynamic expectedType, {Map<String, dynamic>? schema}) {
  if (_schemaAllowsNull(schema) && value.trim().toLowerCase() == 'null') {
    return null;
  }

  if (expectedType is List) {
    // 联合类型 —— 按序尝试，返回首个成功强制。
    for (final t in expectedType) {
      final result = _coerceValue(value, t, schema: schema);
      if (!identical(result, value)) {
        return result;
      }
    }
    return value;
  }

  if (expectedType == 'integer' || expectedType == 'number') {
    return _coerceNumber(value, integerOnly: expectedType == 'integer');
  }
  if (expectedType == 'boolean') {
    return _coerceBoolean(value);
  }
  if (expectedType == 'array') {
    return _coerceJson(value, (v) => v is List);
  }
  if (expectedType == 'object') {
    return _coerceJson(value, (v) => v is Map<String, dynamic>);
  }
  if (expectedType == 'null' && value.trim().toLowerCase() == 'null') {
    return null;
  }
  return value;
}

bool _schemaAllowsNull(dynamic schema) {
  if (schema is! Map<String, dynamic>) {
    return false;
  }
  final schemaType = schema['type'];
  if (schemaType == 'null') {
    return true;
  }
  if (schemaType is List && schemaType.contains('null')) {
    return true;
  }
  if (schema['nullable'] == true) {
    return true;
  }
  for (final unionKey in ['anyOf', 'oneOf']) {
    final variants = schema[unionKey];
    if (variants is! List) {
      continue;
    }
    for (final variant in variants) {
      if (variant is Map<String, dynamic> && variant['type'] == 'null') {
        return true;
      }
    }
  }
  return false;
}

dynamic _coerceJson(String value, bool Function(dynamic) matches) {
  dynamic parsed;
  try {
    parsed = jsonDecode(value);
  } catch (_) {
    return value;
  }
  if (matches(parsed)) {
    return parsed;
  }
  return value;
}

dynamic _coerceNumber(String value, {bool integerOnly = false}) {
  // Python float() 接受前导/尾随空白和下划线（float(" 42 ")=42, float("1_0")=10）。
  final cleaned = value.trim().replaceAll('_', '');
  final f = double.tryParse(cleaned);
  if (f == null) {
    return value;
  }
  // 防 inf/nan —— 不可 JSON 序列化，保留原始字符串。
  if (f.isNaN || f.isInfinite) {
    return value;
  }
  // 看起来是整数（无小数部分），返回 int。
  if (f == f.roundToDouble()) {
    return f.toInt();
  }
  if (integerOnly) {
    // schema 要整数但值有小数 —— 保留字符串。
    return value;
  }
  return f;
}

dynamic _coerceBoolean(String value) {
  final low = value.trim().toLowerCase();
  if (low == 'true') {
    return true;
  }
  if (low == 'false') {
    return false;
  }
  return value;
}

// =============================================================================
// Dispatch
// =============================================================================

/// 工具调用的会话上下文（Python 关键字参数；Dart 版传给 middleware 接口）。
class ToolCallContext {
  final String? taskId;
  final String? toolCallId;
  final String? sessionId;
  final String? turnId;
  final String? apiRequestId;
  final String? userTask;

  const ToolCallContext({
    this.taskId,
    this.toolCallId,
    this.sessionId,
    this.turnId,
    this.apiRequestId,
    this.userTask,
  });
}

/// 主函数调用分发器，把调用路由到工具注册中心。
///
/// Python 版经 coerce → tool_search bridge → middleware → plugins hook →
/// ACP edit_approval → registry.dispatch → post hooks。Dart 版保留核心
/// coerce → dispatch；bridge/middleware/hook 为可注入接口（App 无插件系统）。
Future<String> handleFunctionCall(
  String functionName,
  Map<String, dynamic> functionArgs, {
  ToolCallContext? context,
}) async {
  // 惰性接线 sanitizeToolError（幂等；首次调用即生效）。
  _initToolErrorSanitizer();
  // 强制字符串参数到 schema 声明的类型（如 "42"→42）。
  var args = coerceToolArgs(functionName, functionArgs);
  if (args is! Map<String, dynamic>) {
    args = <String, dynamic>{};
  }

  // Tool Search bridge dispatch：未复刻（App 无 MCP/插件工具集），直接落到
  // registry.dispatch。

  final result = await registry.dispatch(functionName, args);
  final str = result is String ? result : jsonEncode(result);
  // 工具结果确定性裁剪（DSH 启示 3，v4 §7.3）：超大结果 → 结构统计摘要，
  // 防淹没上下文。未超限原样返回。
  return pruneToolResult(str);
}

/// 顶层工具错误净化器（对应 Python `model_tools._sanitize_tool_error`）。
///
/// 复用 registry.dart 的 [defaultSanitizeToolError]（同一实现）；这里是主接线点，
/// 使 model_tools 库被加载后 sanitizeToolError 即为完整实现。
/// 惰性（幂等）—— 首次 handleFunctionCall 时生效。
bool _sanitizerWired = false;
void _initToolErrorSanitizer() {
  if (_sanitizerWired) {
    return;
  }
  _sanitizerWired = true;
  sanitizeToolError = defaultSanitizeToolError;
}

