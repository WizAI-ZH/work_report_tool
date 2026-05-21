import 'package:intl/intl.dart';

import '../models/report_models.dart';

class ReportService {
  static const defaultTemplate = [
    ReportTemplateItem(title: '1、今日工作完成情况', key: 'today_work'),
    ReportTemplateItem(title: '2、明日工作计划', key: 'tomorrow_plan'),
  ];

  String logicalToday([DateTime? now]) =>
      DateFormat('yyyy-MM-dd').format(now ?? DateTime.now());

  Map<String, String> rollDraftToTodayIfNeeded(
    Map<String, String> draft, {
    DateTime? now,
  }) {
    final draftDate = draft['date']?.trim() ?? '';
    if (draftDate.isEmpty) {
      return draft;
    }
    final today = logicalToday(now);
    final draftDay = DateTime.tryParse(draftDate);
    final todayDay = DateTime.tryParse(today);
    if (draftDay == null || todayDay == null || !draftDay.isBefore(todayDay)) {
      return draft;
    }
    return {
      'user': draft['user'] ?? '',
      'department': draft['department'] ?? '',
      'date': today,
      if ((draft['field_tomorrow_plan']?.trim().isNotEmpty ?? false))
        'field_today_work': draft['field_tomorrow_plan']!,
      'field_tomorrow_plan': '',
    };
  }

  String excelLetters(int index) {
    var n = index;
    var result = '';
    while (true) {
      final r = n % 26;
      result = String.fromCharCode(97 + r) + result;
      n = n ~/ 26;
      if (n == 0) {
        break;
      }
      n -= 1;
    }
    return '$result.';
  }

  String properBullet(String line, int index) {
    final trimmed = line.trim();
    if (RegExp(r'^[a-zA-Z]{1,2}\.\s?.*').hasMatch(trimmed) ||
        RegExp(r'^\d+\.\s?.*').hasMatch(trimmed) ||
        RegExp(r'^[①②③④⑤⑥⑦⑧⑨⑩]').hasMatch(trimmed)) {
      return trimmed;
    }
    if (index < 36) {
      return '${excelLetters(index)} $trimmed';
    }
    const circled = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
    return '${circled[index % circled.length]} $trimmed';
  }

  String formatWithBullets(String text) {
    final lines = text
        .trim()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return [for (var i = 0; i < lines.length; i++) properBullet(lines[i], i)]
        .join('\n');
  }

  String cleanSuggestedSection(String text) {
    final cleaned = text
        .trim()
        .replaceFirst(RegExp(r'^[：:；;，,\s]+'), '')
        .split('\n')
        .map((line) => line.trim())
        .where(
            (line) => line.isNotEmpty && !RegExp(r'^[：:；;，,]+$').hasMatch(line))
        .join('\n')
        .trim();
    return cleaned.replaceFirst(RegExp(r'^[：:；;，,\s]+'), '');
  }

  String reportToken(String user, String department, String date) {
    return '${_safeTokenPart(user)}_${_safeTokenPart(department)}_${_safeTokenPart(date)}';
  }

  ReportRecord buildReport({
    required String user,
    required String department,
    required String date,
    required List<ReportTemplateItem> template,
    required Map<String, String> fields,
    String lastTomorrow = '',
  }) {
    final output = <String>[];
    final storedFields = <String, String>{};

    for (final item in template) {
      var value = fields[item.key]?.trim() ?? '';
      if (item.key == 'today_work' && value.isEmpty) {
        value = lastTomorrow;
      }
      if (item.key == 'today_work' || item.key == 'tomorrow_plan') {
        value = value.isEmpty && item.key == 'tomorrow_plan'
            ? 'a. 休息'
            : formatWithBullets(value);
      }
      storedFields[item.key] = value;
      output.add('${item.title}：\n$value\n');
    }

    final header = '姓名：$user  部门：$department  汇报日期：$date\n';
    final report = '$header${''.padRight(52, '=')}\n${output.join()}';
    return ReportRecord(
        user: user,
        department: department,
        date: date,
        fields: storedFields,
        report: report);
  }

  Map<String, String>? parseTaskInput(String input) {
    final match =
        RegExp(r'^(.*?)\s*[（(]([^）)]*)[）)]$').firstMatch(input.trim());
    if (match == null) {
      return null;
    }
    final parts = match
        .group(2)!
        .split(RegExp(r'[,，]'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2) {
      return null;
    }
    return {
      'name': match
          .group(1)!
          .replaceFirst(RegExp(r'^[a-zA-Z]{1,2}\.\s*'), '')
          .trim(),
      'progress': parts[0],
      'completed': parts[1],
      'planned': parts.length >= 3 ? parts.sublist(2).join('，') : '',
    };
  }

  String makeLocalSuggestion(String content) {
    final advice = <String>[];
    final lines = content.split('\n');
    if (lines.any((line) => line.contains('完成') && !line.contains('%'))) {
      advice.add('建议补充百分比或数量，让完成情况更可衡量。');
    }
    if (content.trim().isEmpty) {
      advice.add('内容较少，建议补充具体任务、结果和下一步。');
    }
    advice.addAll(content.length < 100
        ? ['建议使用简洁短句，条理清晰。', '适当量化工作成效，例如“完成XX模块开发80%”。']
        : ['明日计划建议明确到具体任务或目标。', '如有困难，建议在汇报中注明需要协助的资源。']);
    return advice.join('\n');
  }

  String _safeTokenPart(String value) =>
      value.trim().replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
}
