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
    final decoded = jsonDecode(response.body);
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
        : '用户对上一版建议不满意，原因或新要求是：${userFeedback.trim()}。请优先按这个反馈调整，但仍必须遵守所有事实约束和输出格式。';
    final prompt = '''
请基于用户已经填写的内容，优化下面的工作汇报。保持中文、简洁、可直接粘贴。
$feedbackInstruction

严格规则：
- 今日工作只能改写、归纳、排序用户已填写的信息，不要编造任何用户没有写过的工作、进度、数字、成果、模块名、客户名或风险。
- 如果明日工作计划为空，可以根据今日工作里明确出现的未完成、继续、待处理、后续跟进、明日继续等信息，转换成明日计划。
- 如果今日工作没有任何可推导的后续事项，明日工作计划留空或写“建议补充：请填写明日具体工作计划。”。
- 推导明日计划时，只能使用今日工作中“进度低于100%”或“明确写了后续/明日继续/待处理”的事项。
- 今日工作中 100% 完成的事项，默认视为已结束，严禁放入明日工作计划；除非该事项原文明确写了“明日继续”“每天/持续/常规继续”等后续表达。
- 不要因为某项工作看起来像日常工作，就自行判断明天还要继续；没有明确后续表达就不要加入明日计划。
- 不要增加新的任务名称。
- $restDayInstruction
- 可以改善措辞，但不能改变事实含义。
- 必须严格使用下面的输出格式，不要添加解释、前言、总结或额外说明。
- 每条任务一行，使用 a. b. c. 编号。

输出格式：

1、今日工作完成情况：
a. 工作事项（进度，今天完成的工作）
b. 工作事项（进度，今天完成的工作，后续预计完成的工作）

今日工作格式说明：
- 括号内只能是“进度，今天完成的工作，后续预计完成的工作”。
- 第 3 项“后续预计完成的工作”是可选项；只有该事项确实需要后续继续做时才填写。
- 100% 完成且无需后续跟进的事项，不要写“无”“明天无”“无需跟进”等第 3 项。

2、明日工作计划：
a. 工作事项（预计进度，预计完成的内容）
b. 工作事项（预计进度，预计完成的内容）

明日工作格式说明：
- 括号内只能是“预计进度，预计完成的内容”，不要写第 3 项。
- 明日计划是预计内容，进度要写“预计XX%”或“预计完成XX%”。
- 明日计划的预计进度必须是百分比或明确数量，不允许写“预计继续”“继续”“预计推进”等非进度表达。
- 如果从今日未完成事项推导明日计划，预计进度应在今日进度基础上推进，不要倒退。
- 如果明日休息，只输出“休息”，不要编号和括号。

错误示例：
- 今日工作是“钉钉群答疑（100%，全天在线解答学员疑问）”，因为没有明确后续，不能生成“钉钉群答疑（预计继续，预计继续在线解答学员疑问）”。
- 今日工作是“课程内容检查（50%，已完成前半部分质量审核，后半部分待明日继续）”，可以生成“课程内容检查（预计100%，完成后半部分质量审核）”。

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
                  '你是专业的工作汇报格式化助手。你必须严格遵守用户指定格式：今日工作是“工作事项（进度，今天完成的工作，（可选）后续预计完成的工作）”；明日计划是“工作事项（预计进度，预计完成的内容）”。不要虚构用户没有提供的工作。'
            },
            {'role': 'user', 'content': prompt},
          ],
          'temperature': 0.7,
        }),
      );
      if (response.statusCode != 200) {
        return _reportService
            .makeLocalSuggestion('$todayContent\n$tomorrowContent');
      }
      final decoded = jsonDecode(response.body);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is List && choices.isNotEmpty) {
        final message = choices.first is Map ? choices.first['message'] : null;
        final content = message is Map ? message['content'] : null;
        if (content is String && content.trim().isNotEmpty) {
          return content.trim();
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
      final decoded = jsonDecode(response.body);
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map && error['message'] != null) {
        return '$fallback：${error['message']}';
      }
    } catch (_) {}
    return '$fallback：HTTP ${response.statusCode}';
  }
}

class AiException implements Exception {
  const AiException(this.message);

  final String message;

  @override
  String toString() => message;
}
