import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/report_models.dart';
import 'report_service.dart';

class StorageService {
  StorageService({Directory? baseDirectory}) : _baseDirectory = baseDirectory;

  static bool skipLegacyImport = false;
  static Directory? debugBaseDirectory;

  final Directory? _baseDirectory;

  Future<Directory> get dataDirectory async {
    final explicitDirectory = _baseDirectory ?? debugBaseDirectory;
    if (explicitDirectory != null) {
      await explicitDirectory.create(recursive: true);
      return explicitDirectory;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, '工作汇报记录'));
    await Directory(p.join(dir.path, 'report_history')).create(recursive: true);
    return dir;
  }

  Future<void> importLegacyDataIfPresent() async {
    if (skipLegacyImport) {
      return;
    }
    final target = await dataDirectory;
    final legacy = Directory(p.join(Directory.current.path, '工作汇报记录'));
    if (!await legacy.exists()) {
      return;
    }
    if (await _hasExistingData(target)) {
      return;
    }
    await _copyDirectory(legacy, target);
  }

  Future<List<ReportTemplateItem>> loadTemplate() async {
    final file = await _file('report_template.json');
    if (!await file.exists()) {
      return ReportService.defaultTemplate;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((item) =>
                ReportTemplateItem.fromJson(item.cast<String, dynamic>()))
            .where((item) => item.key.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return ReportService.defaultTemplate;
  }

  Future<void> saveTemplate(List<ReportTemplateItem> template) async {
    final file = await _file('report_template.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ')
        .convert(template.map((item) => item.toJson()).toList()));
  }

  Future<AiConfig> loadAiConfig() async {
    final file = await _file('ai_config.json');
    if (!await file.exists()) {
      return AiConfig.defaults;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return AiConfig.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return AiConfig.defaults;
  }

  Future<void> saveAiConfig(AiConfig config) async {
    final file = await _file('ai_config.json');
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config.toJson()));
  }

  Future<Map<String, String>> loadDraft() async {
    final config = await _loadReportConfig();
    final draft = config['draft'];
    if (draft is Map) {
      return draft.map((key, value) => MapEntry('$key', '$value'));
    }
    return {};
  }

  Future<void> saveDraft(Map<String, String> draft) async {
    final config = await _loadReportConfig();
    config['draft'] = draft;
    final file = await _file('report_config.json');
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(config));
  }

  Future<void> saveReport(String token, ReportRecord record) async {
    final dir = await _historyDirectory();
    await File(p.join(dir.path, '$token.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(record.toJson()));
    await saveLastTomorrow('${record.user}_${record.department}',
        record.fields['tomorrow_plan'] ?? '');
  }

  Future<List<TaskItem>> loadTasks() async {
    final document = await _loadTaskDocument();
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
    final document = await _loadTaskDocument();
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
    final file = await _file('task_tracker.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'tasks': tasks.map((item) => item.toJson()).toList(),
      'completed': document['completed'] is List ? document['completed'] : [],
    }));
  }

  Future<List<String>> loadHistoryTokens() async {
    final dir = await _historyDirectory();
    final files = await dir
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files.map((file) => p.basenameWithoutExtension(file.path)).toList();
  }

  Future<ReportRecord?> loadHistoryDetail(String token) async {
    final dir = await _historyDirectory();
    final file = File(p.join(dir.path, '$token.json'));
    if (!await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return ReportRecord.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }

  Future<String> loadLastTomorrow(String userKey) async {
    final config = await _loadReportConfig();
    final tomorrow = config['tomorrow'];
    if (tomorrow is Map) {
      return tomorrow[userKey]?.toString() ?? '';
    }
    return '';
  }

  Future<void> saveLastTomorrow(String userKey, String tomorrowPlan) async {
    final config = await _loadReportConfig();
    final tomorrow =
        (config['tomorrow'] as Map?)?.cast<String, dynamic>() ?? {};
    tomorrow[userKey] = tomorrowPlan;
    config['tomorrow'] = tomorrow;
    final file = await _file('report_config.json');
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(config));
  }

  Future<Map<String, dynamic>> _loadReportConfig() async {
    final file = await _file('report_config.json');
    if (!await file.exists()) {
      return {};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    return {};
  }

  Future<Map<String, dynamic>> _loadTaskDocument() async {
    final file = await _file('task_tracker.json');
    if (!await file.exists()) {
      return {'tasks': [], 'completed': []};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    return {'tasks': [], 'completed': []};
  }

  Future<File> _file(String name) async =>
      File(p.join((await dataDirectory).path, name));

  Future<Directory> _historyDirectory() async {
    final history =
        Directory(p.join((await dataDirectory).path, 'report_history'));
    await history.create(recursive: true);
    return history;
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final newPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }

  Future<bool> _hasExistingData(Directory target) async {
    await for (final entity in target.list(recursive: false)) {
      if (entity is File) {
        return true;
      }
      if (entity is Directory && p.basename(entity.path) == 'report_history') {
        if ((await entity.list().take(1).toList()).isNotEmpty) {
          return true;
        }
      } else if (entity is Directory) {
        return true;
      }
    }
    return false;
  }
}
