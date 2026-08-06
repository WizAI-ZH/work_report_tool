import 'dart:convert';

import 'package:web/web.dart' as web;

import '../models/report_models.dart';
import 'report_service.dart';

class StorageService {
  static bool skipLegacyImport = false;

  Future<void> importLegacyDataIfPresent() async {}

  Future<List<ReportTemplateItem>> loadTemplate() async {
    final decoded = _readJson('report_template');
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((item) =>
              ReportTemplateItem.fromJson(item.cast<String, dynamic>()))
          .where((item) => item.key.isNotEmpty)
          .toList();
    }
    return ReportService.defaultTemplate;
  }

  Future<void> saveTemplate(List<ReportTemplateItem> template) async {
    _writeJson(
        'report_template', template.map((item) => item.toJson()).toList());
  }

  Future<AiConfig> loadAiConfig() async {
    final decoded = _readJson('ai_config');
    if (decoded is Map) {
      return AiConfig.fromJson(decoded.cast<String, dynamic>());
    }
    return AiConfig.defaults;
  }

  Future<void> saveAiConfig(AiConfig config) async {
    _writeJson('ai_config', config.toJson());
  }

  Future<Map<String, String>> loadDraft() async {
    final decoded = _readJson('draft');
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    }
    return {};
  }

  Future<void> saveDraft(Map<String, String> draft) async {
    _writeJson('draft', draft);
  }

  Future<void> saveReport(String token, ReportRecord record) async {
    _writeJson('history_$token', record.toJson());
    final tokens = await loadHistoryTokens();
    final nextTokens = [token, ...tokens.where((item) => item != token)];
    _writeJson('history_tokens', nextTokens);
    await saveLastTomorrow('${record.user}_${record.department}',
        record.fields['tomorrow_plan'] ?? '');
  }

  Future<void> saveImportedHistory(Iterable<ReportRecord> records,
      String Function(ReportRecord) tokenFor) async {
    for (final record in records) {
      await saveReport(tokenFor(record), record);
    }
  }

  Future<List<String>> loadHistoryTokens() async {
    final decoded = _readJson('history_tokens');
    if (decoded is List) {
      return decoded.map((item) => '$item').toList();
    }
    return [];
  }

  Future<ReportRecord?> loadHistoryDetail(String token) async {
    final decoded = _readJson('history_$token');
    if (decoded is Map) {
      return ReportRecord.fromJson(decoded.cast<String, dynamic>());
    }
    return null;
  }

  Future<List<TaskItem>> loadTasks() async {
    final document = _readTaskDocument();
    final rawTasks = document['tasks'];
    if (rawTasks is! List) {
      return [];
    }
    return rawTasks
        .whereType<Map>()
        .map((item) => TaskItem.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<List<TaskItem>> loadPendingTasks() async {
    final tasks = await loadTasks();
    final unique = <String, TaskItem>{};
    for (final task in tasks.where((task) => task.status == 'in_progress')) {
      unique['${task.name.trim()}|${task.planned.trim()}'] = task;
    }
    return unique.values.toList();
  }

  Future<void> addTask({
    required String name,
    required String progress,
    required String completed,
    required String planned,
    required String createdAt,
  }) async {
    final document = _readTaskDocument();
    final tasks = await loadTasks();
    final taskName = name.trim();
    final taskPlanned = planned.trim();
    final existingIndex = tasks.indexWhere((task) =>
        task.status == 'in_progress' &&
        task.name.trim() == taskName &&
        task.planned.trim() == taskPlanned);
    final task = TaskItem(
      id: existingIndex >= 0
          ? tasks[existingIndex].id
          : 'task_${DateTime.now().microsecondsSinceEpoch}',
      name: taskName,
      progress: progress.trim(),
      completed: completed.trim(),
      planned: taskPlanned,
      createdAt: createdAt,
      status: 'in_progress',
    );
    if (existingIndex >= 0) {
      tasks[existingIndex] = task;
    } else {
      tasks.add(task);
    }
    _writeJson('task_tracker', {
      'tasks': tasks.map((item) => item.toJson()).toList(),
      'completed': document['completed'] is List ? document['completed'] : [],
    });
  }

  Future<String> loadLastTomorrow(String userKey) async {
    final config = _readReportConfig();
    final tomorrow = config['tomorrow'];
    if (tomorrow is Map) {
      return tomorrow[userKey]?.toString() ?? '';
    }
    return '';
  }

  Future<void> saveLastTomorrow(String userKey, String tomorrowPlan) async {
    final config = _readReportConfig();
    final tomorrow =
        (config['tomorrow'] as Map?)?.cast<String, dynamic>() ?? {};
    tomorrow[userKey] = tomorrowPlan;
    config['tomorrow'] = tomorrow;
    _writeJson('report_config', config);
  }

  Future<String> loadWechatTarget() async {
    final config = _readReportConfig();
    final target = config['wechat_target']?.toString().trim() ?? '';
    return target.isEmpty ? '文件传输助手' : target;
  }

  Future<void> saveWechatTarget(String groupName) async {
    final config = _readReportConfig();
    config['wechat_target'] = groupName.trim();
    _writeJson('report_config', config);
  }

  Map<String, dynamic> _readReportConfig() {
    final decoded = _readJson('report_config');
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    return {};
  }

  Map<String, dynamic> _readTaskDocument() {
    final decoded = _readJson('task_tracker');
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    return {'tasks': [], 'completed': []};
  }

  Object? _readJson(String key) {
    final raw = web.window.localStorage.getItem(_key(key));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  void _writeJson(String key, Object value) {
    web.window.localStorage.setItem(_key(key), jsonEncode(value));
  }

  String _key(String key) => 'work_report_generator_$key';
}
