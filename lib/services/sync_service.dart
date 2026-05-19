import 'dart:convert';

import '../models/report_models.dart';

class SyncDraft {
  const SyncDraft({
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

  factory SyncDraft.fromJson(Map<String, dynamic> json) {
    final rawFields = json['fields'];
    return SyncDraft(
      user: json['user'] as String? ?? '',
      department: (json['department'] ?? json['dept']) as String? ?? '',
      date: json['date'] as String? ?? '',
      fields: rawFields is Map
          ? rawFields.map((key, value) => MapEntry('$key', '$value'))
          : const {},
      report: json['report'] as String? ?? '',
    );
  }

  factory SyncDraft.fromRecord(ReportRecord record) {
    return SyncDraft(
      user: record.user,
      department: record.department,
      date: record.date,
      fields: record.fields,
      report: record.report,
    );
  }

  Map<String, dynamic> toJson() => {
        'user': user,
        'department': department,
        'date': date,
        'fields': fields,
        'report': report,
      };

  ReportRecord toRecord() => ReportRecord(
        user: user,
        department: department,
        date: date,
        fields: fields,
        report: report,
      );
}

class SyncDocument {
  const SyncDocument({
    required this.kind,
    required this.draft,
    required this.history,
    required this.appVersion,
    required this.createdAt,
  });

  static const schema = 'wiz_work_report_sync';
  static const schemaVersion = 1;

  final String kind;
  final SyncDraft draft;
  final List<ReportRecord> history;
  final String appVersion;
  final DateTime createdAt;

  factory SyncDocument.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != schema || json['schema_version'] != schemaVersion) {
      throw const FormatException('不是有效的威智工作汇报器同步文件');
    }
    final draft = json['draft'];
    if (draft is! Map) {
      throw const FormatException('同步文件缺少当前草稿');
    }
    final rawHistory = json['history'];
    return SyncDocument(
      kind: json['kind'] as String? ?? 'draft',
      draft: SyncDraft.fromJson(draft.cast<String, dynamic>()),
      history: rawHistory is List
          ? rawHistory
              .whereType<Map>()
              .map(
                  (item) => ReportRecord.fromJson(item.cast<String, dynamic>()))
              .toList()
          : const [],
      appVersion: json['app_version'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'schema_version': schemaVersion,
        'app_version': appVersion,
        'created_at': createdAt.toIso8601String(),
        'kind': kind,
        'draft': draft.toJson(),
        if (kind == 'full')
          'history': history.map((record) => record.toJson()).toList(),
      };
}

class SyncImportResult {
  const SyncImportResult({
    required this.draft,
    required this.history,
    required this.message,
  });

  final SyncDraft draft;
  final List<ReportRecord> history;
  final String message;
}

class SyncService {
  static const qrPrefix = 'wizsync:';
  static const maxQrPayloadLength = 2800;

  String encodeDocument(SyncDocument document) {
    return const JsonEncoder.withIndent('  ').convert(document.toJson());
  }

  SyncDocument decodeDocument(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('同步内容格式无效');
    }
    return SyncDocument.fromJson(decoded.cast<String, dynamic>());
  }

  String encodeQrDraft(SyncDraft draft, String appVersion) {
    final document = SyncDocument(
      kind: 'draft',
      draft: draft,
      history: const [],
      appVersion: appVersion,
      createdAt: DateTime.now(),
    );
    final payload = base64UrlEncode(utf8.encode(jsonEncode(document.toJson())));
    final value = '$qrPrefix$payload';
    if (value.length > maxQrPayloadLength) {
      throw const FormatException('二维码内容过长，请改用同步文件');
    }
    return value;
  }

  SyncDocument decodeQr(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith(qrPrefix)) {
      throw const FormatException('不是威智工作汇报器同步二维码');
    }
    final payload = trimmed.substring(qrPrefix.length);
    final raw = utf8.decode(base64Url.decode(payload));
    return decodeDocument(raw);
  }

  SyncImportResult importAny(
    String raw, {
    required List<ReportTemplateItem> template,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('导入内容为空');
    }
    if (trimmed.startsWith(qrPrefix)) {
      final document = decodeQr(trimmed);
      return SyncImportResult(
        draft: document.draft,
        history: document.history,
        message: document.kind == 'full' ? '同步文件已导入' : '二维码内容已导入',
      );
    }
    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        throw const FormatException('JSON 内容格式无效');
      }
      final json = decoded.cast<String, dynamic>();
      if (json['schema'] == SyncDocument.schema) {
        final document = SyncDocument.fromJson(json);
        return SyncImportResult(
          draft: document.draft,
          history: document.history,
          message: document.kind == 'full' ? '同步文件已导入' : '二维码内容已导入',
        );
      }
      final record = ReportRecord.fromJson(json);
      if (_isEmptyRecord(record)) {
        throw const FormatException('未识别到可导入的汇报内容');
      }
      return SyncImportResult(
        draft: SyncDraft.fromRecord(record),
        history: const [],
        message: '历史记录 JSON 已导入',
      );
    }

    final record = parseGeneratedReport(trimmed, template: template);
    return SyncImportResult(
      draft: SyncDraft.fromRecord(record),
      history: const [],
      message: '汇报文本已导入',
    );
  }

  ReportRecord parseGeneratedReport(
    String raw, {
    required List<ReportTemplateItem> template,
  }) {
    final header =
        RegExp(r'姓名：(.+?)\s+部门：(.+?)\s+汇报日期：([0-9]{4}-[0-9]{2}-[0-9]{2})')
            .firstMatch(raw);
    if (header == null) {
      throw const FormatException('未找到汇报表头');
    }
    final fields = <String, String>{};
    String? currentKey;
    final sectionLines = <String>[];

    void flush() {
      if (currentKey != null) {
        fields[currentKey] = _cleanSection(sectionLines.join('\n'));
      }
      sectionLines.clear();
    }

    final normalizedTitles = {
      for (final item in template) _normalizeTitle(item.title): item.key,
    };
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trimRight();
      final normalized = _normalizeTitle(line);
      final matchedKey = normalizedTitles[normalized];
      if (matchedKey != null) {
        flush();
        currentKey = matchedKey;
        continue;
      }
      if (currentKey != null && !RegExp(r'^=+$').hasMatch(line.trim())) {
        sectionLines.add(line);
      }
    }
    flush();

    if (fields.isEmpty) {
      throw const FormatException('未找到汇报内容段落');
    }
    return ReportRecord(
      user: header.group(1)?.trim() ?? '',
      department: header.group(2)?.trim() ?? '',
      date: header.group(3)?.trim() ?? '',
      fields: fields,
      report: raw,
    );
  }

  bool _isEmptyRecord(ReportRecord record) {
    return record.user.trim().isEmpty &&
        record.department.trim().isEmpty &&
        record.date.trim().isEmpty &&
        record.fields.isEmpty &&
        record.report.trim().isEmpty;
  }

  String _normalizeTitle(String value) {
    return value
        .trim()
        .replaceAll(RegExp(r'[：:；;]\s*$'), '')
        .replaceAll(RegExp(r'\s+'), '');
  }

  String _cleanSection(String value) {
    return value.split('\n').map((line) => line.trimRight()).join('\n').trim();
  }
}
