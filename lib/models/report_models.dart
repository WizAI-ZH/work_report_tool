class ReportTemplateItem {
  const ReportTemplateItem({required this.title, required this.key});

  final String title;
  final String key;

  factory ReportTemplateItem.fromJson(Map<String, dynamic> json) {
    return ReportTemplateItem(
      title: json['title'] as String? ?? '',
      key: json['key'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'title': title, 'key': key};
}

class ReportRecord {
  const ReportRecord({
    required this.user,
    required this.department,
    required this.date,
    required this.fields,
    required this.report,
  });

  final String user;
  final String department;
  final String date;
  final Map<String, String> fields;
  final String report;

  factory ReportRecord.fromJson(Map<String, dynamic> json) {
    final fields = <String, String>{};
    for (final entry in json.entries) {
      if (!{'user', 'dept', 'department', 'date', 'report', 'fields'}.contains(entry.key)) {
        fields[entry.key] = entry.value?.toString() ?? '';
      }
    }
    final rawFields = json['fields'];
    if (rawFields is Map) {
      fields.addAll(rawFields.map((key, value) => MapEntry('$key', '$value')));
    }

    return ReportRecord(
      user: json['user'] as String? ?? '',
      department: (json['department'] ?? json['dept']) as String? ?? '',
      date: json['date'] as String? ?? '',
      fields: fields,
      report: json['report'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'user': user,
        'department': department,
        'date': date,
        'fields': fields,
        'report': report,
      };
}

class AiConfig {
  const AiConfig({
    required this.apiKey,
    required this.apiUrl,
    required this.model,
    required this.availableModels,
  });

  final String apiKey;
  final String apiUrl;
  final String model;
  final List<String> availableModels;

  static const defaults = AiConfig(
    apiKey: '',
    apiUrl: 'https://api.chatanywhere.tech/v1/chat/completions',
    model: 'deepseek-v3.2',
    availableModels: ['deepseek-v3.2', 'deepseek-chat', 'gpt-3.5-turbo', 'gpt-4o', 'gpt-4o-mini'],
  );

  factory AiConfig.fromJson(Map<String, dynamic> json) {
    final rawModels = json['available_models'];
    return AiConfig(
      apiKey: json['api_key'] as String? ?? defaults.apiKey,
      apiUrl: json['api_url'] as String? ?? defaults.apiUrl,
      model: json['model'] as String? ?? defaults.model,
      availableModels: rawModels is List
          ? rawModels.map((value) => '$value').toList()
          : defaults.availableModels,
    );
  }

  Map<String, dynamic> toJson() => {
        'api_key': apiKey,
        'api_url': apiUrl,
        'model': model,
        'available_models': availableModels,
      };
}

class TaskItem {
  const TaskItem({
    required this.id,
    required this.name,
    required this.progress,
    required this.completed,
    required this.planned,
    required this.createdAt,
    required this.status,
  });

  final String id;
  final String name;
  final String progress;
  final String completed;
  final String planned;
  final String createdAt;
  final String status;

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    return TaskItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      progress: json['progress'] as String? ?? '0%',
      completed: json['completed'] as String? ?? '',
      planned: json['planned'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      status: json['status'] as String? ?? 'in_progress',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'progress': progress,
        'completed': completed,
        'planned': planned,
        'created_at': createdAt,
        'status': status,
      };
}
