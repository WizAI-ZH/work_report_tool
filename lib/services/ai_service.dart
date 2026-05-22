import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/report_models.dart';
import 'report_service.dart';

class AiService {
  AiService({http.Client? client, ReportService? reportService})
      : _client = client ?? http.Client(),
        _reportService = reportService ?? ReportService();

  final http.Client _client;
  final ReportService _reportService;

  Future<List<String>> fetchModels(AiConfig config) async {
    final response = await _client.get(
      Uri.parse('https://api.chatanywhere.tech/v1/models'),
      headers: {'Authorization': 'Bearer ${config.apiKey}'},
    );
    if (response.statusCode != 200) {
      throw AiException('获取模型列表失败：HTTP ${response.statusCode}');
    }
    final decoded = _decodeJsonResponse(response);
    if (decoded is! Map || decoded['data'] is! List) {
      throw const AiException('获取模型列表失败：API 返回格式错误');
    }
    final models = <String>[];
    for (final item in decoded['data'] as List) {
      if (item is Map && item['id'] != null) {
        final id = '${item['id']}';
        final lower = id.toLowerCase();
        if ([
          'gpt',
          'claude',
          'deepseek',
          'qwen',
          'glm',
          'chat',
          'llama',
          'mistral'
        ].any((keyword) => lower.contains(keyword))) {
          models.add(id);
        }
      }
    }
    return models;
  }

  Future<void> testConnection(AiConfig config) async {
    final response = await _client.post(
      Uri.parse(config.apiUrl),
      headers: _headers(config),
      body: jsonEncode({
        'model': config.model,
        'messages': [
          {'role': 'user', 'content': '请回复：连接成功'},
        ],
        'max_tokens': 20,
      }),
    );
    if (response.statusCode != 200) {
      throw AiException(_errorMessage(response, '连接测试失败'));
    }
  }

  Future<String> suggest({
    required AiConfig config,
    required String todayContent,
    required String tomorrowContent,
    required String reportDate,
    required bool tomorrowMayBeRestDay,
    String userFeedback = '',
  }) async {
    if (config.apiKey.trim().isEmpty) {
      return _reportService
          .makeLocalSuggestion('$todayContent\n$tomorrowContent');
    }

    final restDayInstruction = tomorrowMayBeRestDay
        ? '汇报日期是 $reportDate，明天可能是周末或休息日。如果用户已确认或填写明日休息，“2、明日工作计划”只能输出“休息”，不要添加编号、括号或任何工作计划。'
        : '汇报日期是 $reportDate。';
    final feedbackInstruction = userFeedback.trim().isEmpty
        ? ''
        : '''
用户对上一版建议不满意，原因或新要求是：
${userFeedback.trim()}

重新生成时必须优先解决上述问题，但不能违反事实约束和输出格式。
''';
    final prompt = '''
你要把用户填写的工作内容整理成固定格式的中文日报。输出必须可直接粘贴到企业微信。
$feedbackInstruction

最高优先级规则：
1. 只能输出最终汇报正文，不要解释、不要前言、不要总结、不要 Markdown、不要代码块。
2. 严格保留“1、今日工作完成情况：”和“2、明日工作计划：”两个标题，标题文字不能改。
3. 只能使用用户输入中已经出现的信息；不得编造任务、模块、客户、风险、进度、数字、成果或原因。
4. 可以润色语句、合并重复项、调整顺序，但不能改变事实含义。
5. 每条任务独占一行，编号必须从 a. 开始顺序递增。
6. 不要输出“无”“暂无”“未提及”“根据内容推测”等占位解释。
7. $restDayInstruction

处理步骤（只在心里执行，不要写出来）：
1. 先从用户输入中提取任务名、已完成内容、进度、明确的后续内容。
2. 只把“今日输入”整理到今日工作。
3. 只把“明日输入”整理到明日计划。
4. 如果明日输入为空，只有在今日输入明确写了“未完成/继续/待处理/后续/明日/下一步”或进度低于 100% 时，才允许推导明日计划。
5. 今日 100% 完成且没有明确后续表达的事项，严禁出现在明日计划。

今日工作格式：

1、今日工作完成情况：
a. 工作事项（进度，今天完成的工作）
b. 工作事项（进度，今天完成的工作，后续预计完成的工作）

今日工作括号规则：
- 括号内只能写“进度，今天完成的工作”或“进度，今天完成的工作，后续预计完成的工作”。
- 第 3 项“后续预计完成的工作”只有在用户原文明确写了后续、待处理、继续、明日、下一步时才填写。
- 100% 完成且没有明确后续的事项，只能写两项，不要写“无”“无需跟进”“明天无”等第 3 项。

明日计划格式：

2、明日工作计划：
a. 工作事项（预计进度，预计完成的内容）
b. 工作事项（预计进度，预计完成的内容）

明日工作括号规则：
- 括号内只能是“预计进度，预计完成的内容”，不要写第 3 项。
- 明日计划是预计内容，进度要写“预计XX%”或“预计完成XX%”。
- 明日计划的预计进度必须是百分比或明确数量，不允许写“预计继续”“继续”“预计推进”等非进度表达。
- 如果从今日未完成事项推导明日计划，预计进度应在今日进度基础上推进，不要倒退。
- 如果明日输入为空，且今日工作没有可推导的后续事项，“2、明日工作计划：”标题下保持空白。
- 如果明日休息，只输出“休息”，不要编号和括号。

错误示例：
- 输入“钉钉群答疑（100%，全天在线解答学员疑问）”，不能生成明日计划，因为没有明确后续。
- 输入“课程内容检查（50%，已完成前半部分质量审核，后半部分待明日继续）”，可以生成“课程内容检查（预计100%，完成后半部分质量审核）”。
- 输入“明日工作计划为空”，不要写“建议补充：请填写明日具体工作计划。”，保持空白即可。

现在开始整理。只输出下面两个标题及对应条目。

1、今日工作完成情况：
$todayContent

2、明日工作计划：
$tomorrowContent
''';

    try {
      final response = await _client.post(
        Uri.parse(config.apiUrl),
        headers: _headers(config),
        body: jsonEncode({
          'model': config.model,
          'messages': [
            {
              'role': 'system',
              'content':
                  '你是严格的工作汇报格式化引擎。只输出用户要求的两段汇报正文，不输出解释、寒暄、Markdown 或代码块。禁止虚构事实；不确定就留空。'
            },
            {'role': 'user', 'content': prompt},
          ],
          'temperature': 0.2,
        }),
      );
      if (response.statusCode != 200) {
        return _reportService
            .makeLocalSuggestion('$todayContent\n$tomorrowContent');
      }
      final decoded = _decodeJsonResponse(response);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is List && choices.isNotEmpty) {
        final message = choices.first is Map ? choices.first['message'] : null;
        final content = message is Map ? message['content'] : null;
        if (content is String && content.trim().isNotEmpty) {
          return _cleanSuggestionResponse(content);
        }
      }
    } catch (_) {
      return _reportService
          .makeLocalSuggestion('$todayContent\n$tomorrowContent');
    }
    return _reportService
        .makeLocalSuggestion('$todayContent\n$tomorrowContent');
  }

  Map<String, String> _headers(AiConfig config) => {
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
      };

  String _errorMessage(http.Response response, String fallback) {
    try {
      final decoded = _decodeJsonResponse(response);
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map && error['message'] != null) {
        return '$fallback：${error['message']}';
      }
    } catch (_) {}
    return '$fallback：HTTP ${response.statusCode}';
  }

  dynamic _decodeJsonResponse(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      return jsonDecode(response.body);
    }
  }

  String _cleanSuggestionResponse(String content) {
    var text = content.trim();
    final fence = RegExp(r'^```(?:\w+)?\s*([\s\S]*?)\s*```$');
    final fenceMatch = fence.firstMatch(text);
    if (fenceMatch != null) {
      text = fenceMatch.group(1)!.trim();
    }
    final start = text.indexOf('1、今日工作完成情况');
    if (start > 0) {
      text = text.substring(start).trim();
    }
    return text
        .replaceAll(RegExp(r'^```(?:\w+)?\s*'), '')
        .replaceAll(RegExp(r'\s*```$'), '')
        .trim();
  }
}

class AiException implements Exception {
  const AiException(this.message);

  final String message;

  @override
  String toString() => message;
}
