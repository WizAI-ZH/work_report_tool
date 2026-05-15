import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_report_generator/models/report_models.dart';
import 'package:work_report_generator/services/ai_service.dart';
import 'package:work_report_generator/services/report_service.dart';
import 'package:work_report_generator/services/storage_service.dart';
import 'package:work_report_generator/services/update_service.dart';

void main() {
  group('ReportService', () {
    final service = ReportService();

    test('formats bullets with excel-style prefixes', () {
      expect(service.formatWithBullets('完成登录\n完成报表'), 'a. 完成登录\nb. 完成报表');
    });

    test('keeps existing bullets', () {
      expect(service.formatWithBullets('1. 已完成\nb. 明日继续'), '1. 已完成\nb. 明日继续');
    });

    test('cleans leading punctuation from ai sections', () {
      expect(service.cleanSuggestedSection('：\na. 完成答疑\nb. 继续审核'),
          'a. 完成答疑\nb. 继续审核');
    });

    test('creates safe history token', () {
      expect(service.reportToken('张 三', '研发/平台', '2026-05-11'),
          '张_三_研发_平台_2026-05-11');
    });

    test('parses task input', () {
      expect(
        service.parseTaskInput('a. 登录模块（80%，联调完成，明天测试）'),
        {
          'name': '登录模块',
          'progress': '80%',
          'completed': '联调完成',
          'planned': '明天测试',
        },
      );
    });

    test('parses tomorrow task input without follow-up field', () {
      expect(
        service.parseTaskInput('登录模块（预计90%，完成测试验证）'),
        {
          'name': '登录模块',
          'progress': '预计90%',
          'completed': '完成测试验证',
          'planned': '',
        },
      );
    });

    test('builds report with formatted fields', () {
      final record = service.buildReport(
        user: '张三',
        department: '研发部',
        date: '2026-05-11',
        template: ReportService.defaultTemplate,
        fields: {
          'today_work': '完成接口',
          'tomorrow_plan': '继续测试',
        },
      );

      expect(record.report, contains('姓名：张三  部门：研发部  汇报日期：2026-05-11'));
      expect(record.report, contains('a. 完成接口'));
      expect(record.report, contains('a. 继续测试'));
    });
  });

  group('StorageService', () {
    late Directory tempDir;
    late StorageService storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('work_report_test_');
      storage = StorageService(baseDirectory: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('saves and loads template', () async {
      const template = [
        ReportTemplateItem(title: '一、今日', key: 'today_work'),
        ReportTemplateItem(title: '二、计划', key: 'tomorrow_plan'),
      ];

      await storage.saveTemplate(template);
      final loaded = await storage.loadTemplate();

      expect(loaded.map((item) => item.key), ['today_work', 'tomorrow_plan']);
      expect(loaded.first.title, '一、今日');
    });

    test('saves and loads history record', () async {
      const record = ReportRecord(
        user: '张三',
        department: '研发部',
        date: '2026-05-11',
        fields: {'tomorrow_plan': 'a. 测试'},
        report: 'report body',
      );

      await storage.saveReport('张三_研发部_2026-05-11', record);
      final tokens = await storage.loadHistoryTokens();
      final loaded = await storage.loadHistoryDetail(tokens.single);

      expect(tokens, ['张三_研发部_2026-05-11']);
      expect(loaded?.report, 'report body');
      expect(await storage.loadLastTomorrow('张三_研发部'), 'a. 测试');
    });

    test('saves and loads pending tasks', () async {
      await storage.addTask(
        name: '登录模块',
        progress: '80%',
        completed: '联调完成',
        planned: '明天测试',
        createdAt: '2026-05-11',
      );

      final pending = await storage.loadPendingTasks();

      expect(pending.single.name, '登录模块');
      expect(pending.single.status, 'in_progress');
    });

    test('updates duplicate pending task instead of appending', () async {
      await storage.addTask(
        name: '登录模块',
        progress: '40%',
        completed: '完成接口',
        planned: '明天测试',
        createdAt: '2026-05-11',
      );
      await storage.addTask(
        name: ' 登录模块 ',
        progress: '80%',
        completed: '联调完成',
        planned: ' 明天测试 ',
        createdAt: '2026-05-12',
      );

      final pending = await storage.loadPendingTasks();

      expect(pending, hasLength(1));
      expect(pending.single.progress, '80%');
      expect(pending.single.createdAt, '2026-05-12');
    });

    test('loads unique pending tasks from existing duplicate data', () async {
      await storage.addTask(
        name: '登录模块',
        progress: '40%',
        completed: '完成接口',
        planned: '明天测试',
        createdAt: '2026-05-11',
      );
      await storage.addTask(
        name: '登录模块',
        progress: '60%',
        completed: '完成冒烟',
        planned: '继续修复',
        createdAt: '2026-05-12',
      );
      await storage.addTask(
        name: '登录模块',
        progress: '80%',
        completed: '联调完成',
        planned: '明天测试',
        createdAt: '2026-05-13',
      );

      final pending = await storage.loadPendingTasks();

      expect(pending.map((task) => task.planned), ['明天测试', '继续修复']);
    });

    test('saves and loads draft profile and fields', () async {
      await storage.saveDraft({
        'user': '张三',
        'department': '研发部',
        'date': '2026-05-13',
        'field_today_work': '完成联调',
      });

      final draft = await storage.loadDraft();

      expect(draft['user'], '张三');
      expect(draft['department'], '研发部');
      expect(draft['field_today_work'], '完成联调');
    });
  });

  group('AiService', () {
    test('falls back to local suggestion when api key is empty', () async {
      final suggestion = await AiService().suggest(
        config: AiConfig.defaults,
        todayContent: '完成接口',
        tomorrowContent: '继续测试',
        reportDate: '2026-05-13',
        tomorrowMayBeRestDay: false,
      );

      expect(suggestion, contains('建议'));
    });
  });

  group('UpdateService', () {
    test('compares semantic versions', () {
      expect(UpdateService.compareVersions('1.1.0', '1.0.9'), greaterThan(0));
      expect(UpdateService.compareVersions('1.1.0', '1.1.0'), 0);
      expect(UpdateService.compareVersions('1.0.9', '1.1.0'), lessThan(0));
    });
  });
}
