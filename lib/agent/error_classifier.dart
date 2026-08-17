/// 对应 `ref/hermes-agent/agent/error_classifier.py`（像素级复刻，核心）。
///
/// API 错误分类 → 恢复动作（重试/压缩/轮换凭据/放弃）。
/// 弱网手机最关键：429 限流可重试 + 退避、413 应压缩、5xx 可重试、401 认证失败。
library;

import '../llm/openai_llm.dart';

/// 失败原因。
enum FailoverReason {
  auth,
  authPermanent,
  billing,
  rateLimit,
  overloaded,
  payloadTooLarge,
  serverError,
  clientError,
  network,
  unknown,
}

/// 分类结果（含恢复动作提示）。
class ClassifiedError {
  final FailoverReason reason;
  final int? statusCode;
  final String message;

  /// 是否可重试。
  final bool retryable;

  /// 是否应压缩上下文后重试（413）。
  final bool shouldCompress;

  /// 是否应轮换凭据（401/403）。
  final bool shouldRotateCredential;

  ClassifiedError({
    required this.reason,
    this.statusCode,
    this.message = '',
    this.retryable = false,
    this.shouldCompress = false,
    this.shouldRotateCredential = false,
  });

  bool get isAuth =>
      reason == FailoverReason.auth || reason == FailoverReason.authPermanent;
}

/// 计费/额度耗尽的错误消息模式。
const List<String> billingPatterns = [
  'insufficient credits',
  'insufficient_quota',
  'insufficient balance',
  'credit balance',
  'credits exhausted',
  'credits have been exhausted',
  'no usable credits',
  'top up your credits',
  'payment required',
  'billing hard limit',
  'exceeded your current quota',
  'out of funds',
  'balance_depleted',
];

/// 限流消息模式。
const List<String> rateLimitPatterns = [
  'rate limit',
  'rate_limit',
  'too many requests',
];

/// 服务器过载消息模式。
const List<String> overloadedPatterns = [
  'overloaded',
  'temporarily overloaded',
  'service may be temporarily',
];

/// 从异常/字符串提取状态码。
int? extractStatusCode(Object? error) {
  if (error is LlmException) {
    return error.statusCode;
  }
  final text = error?.toString() ?? '';
  // 匹配 "status code 429" 或 "HTTP 429"。
  final m = RegExp(r'(?:status code|HTTP)\s*(\d{3})', caseSensitive: false)
      .firstMatch(text);
  return m != null ? int.tryParse(m.group(1)!) : null;
}

/// 从异常提取错误消息。
String _errorText(Object? error) {
  final parts = <String>[
    error?.toString() ?? '',
    if (error is LlmException) error.body ?? '',
  ];
  return parts.join(' ').toLowerCase();
}

/// 分类 API 错误。
///
/// [error] 通常是 LlmException。返回带恢复动作的分类。
ClassifiedError classifyApiError(Object error, {String? provider, String? model}) {
  final status = extractStatusCode(error);
  final text = _errorText(error);

  // 超时：模型长思考或服务端挂起，重试只会再等一轮（且可能重复消耗）。
  // 标记不可重试，让 agent 直接返回已流式内容而不是卡死 3 次重试。
  if (text.contains('timeout') || text.contains('ended without completion')) {
    return ClassifiedError(
      reason: FailoverReason.network,
      message: error.toString(),
      retryable: false,
    );
  }

  // 网络错误（无状态码）→ 可重试。
  if (status == null) {
    return ClassifiedError(
      reason: FailoverReason.unknown,
      message: error.toString(),
      retryable: true, // 未知错误保守重试。
    );
  }

  switch (status) {
    case 401:
      return ClassifiedError(
        reason: FailoverReason.auth,
        statusCode: status,
        message: error.toString(),
        retryable: false,
        shouldRotateCredential: true,
      );
    case 403:
      if (billingPatterns.any(text.contains) || text.contains('key limit exceeded')) {
        return ClassifiedError(
          reason: FailoverReason.billing,
          statusCode: status,
          message: error.toString(),
          retryable: false,
          shouldRotateCredential: true,
        );
      }
      return ClassifiedError(
        reason: FailoverReason.auth,
        statusCode: status,
        message: error.toString(),
        retryable: false,
      );
    case 413:
      return ClassifiedError(
        reason: FailoverReason.payloadTooLarge,
        statusCode: status,
        message: error.toString(),
        retryable: true,
        shouldCompress: true,
      );
    case 429:
      if (overloadedPatterns.any(text.contains)) {
        return ClassifiedError(
          reason: FailoverReason.overloaded,
          statusCode: status,
          message: error.toString(),
          retryable: true,
        );
      }
      return ClassifiedError(
        reason: FailoverReason.rateLimit,
        statusCode: status,
        message: error.toString(),
        retryable: true,
      );
    case 400:
      if (billingPatterns.any(text.contains)) {
        return ClassifiedError(
          reason: FailoverReason.billing,
          statusCode: status,
          message: error.toString(),
          retryable: false,
        );
      }
      return ClassifiedError(
        reason: FailoverReason.clientError,
        statusCode: status,
        message: error.toString(),
        retryable: false,
      );
    case 500:
    case 502:
    case 503:
      return ClassifiedError(
        reason: FailoverReason.serverError,
        statusCode: status,
        message: error.toString(),
        retryable: true,
      );
    default:
      return ClassifiedError(
        reason: FailoverReason.clientError,
        statusCode: status,
        message: error.toString(),
        retryable: false,
      );
  }
}
