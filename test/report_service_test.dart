import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_report_generator/models/report_models.dart';
import 'package:work_report_generator/services/ai_service.dart';
import 'package:work_report_generator/services/report_service.dart';
import 'package:work_report_generator/services/storage_service.dart';
import 'package:work_report_generator/services/sync_service.dart';
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

    test('rolls older draft tomorrow plan into today work', () {
      final rolled = service.rollDraftToTodayIfNeeded(
        {
          'user': '张三',
          'department': '研发部',
          'date': '2026-05-18',
          'field_today_work': 'a. 完成 A',
          'field_tomorrow_plan': 'a. 完成 C\nb. 完成 D',
        },
        now: DateTime(2026, 5, 19),
      );

      expect(rolled['date'], '2026-05-19');
      expect(rolled['field_today_work'], 'a. 完成 C\nb. 完成 D');
      expect(rolled['field_tomorrow_plan'], '');
    });

    test('keeps same-day draft unchanged', () {
      final draft = {
        'date': '2026-05-19',
        'field_today_work': 'a. 继续编辑',
        'field_tomorrow_plan': 'a. 明天继续',
      };

      final rolled =
          service.rollDraftToTodayIfNeeded(draft, now: DateTime(2026, 5, 19));

      expect(identical(rolled, draft), isTrue);
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

    test('imports history records with generated tokens', () async {
      const record = ReportRecord(
        user: '李四',
        department: '产品部',
        date: '2026-05-19',
        fields: {'today_work': 'a. 整理需求'},
        report: 'report body',
      );

      await storage.saveImportedHistory(
        const [record],
        (item) =>
            ReportService().reportToken(item.user, item.department, item.date),
      );

      final tokens = await storage.loadHistoryTokens();
      final loaded = await storage.loadHistoryDetail(tokens.single);
      expect(tokens.single, '李四_产品部_2026-05-19');
      expect(loaded?.fields['today_work'], 'a. 整理需求');
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

  group('SyncService', () {
    final sync = SyncService();

    test('parses generated report text into draft record', () {
      final record = sync.parseGeneratedReport(
        '姓名：张三  部门：研发部  汇报日期：2026-05-19\n'
        '====================================================\n'
        '1、今日工作完成情况：\n'
        'a. 完成接口\n'
        '2、明日工作计划：\n'
        'a. 继续测试',
        template: ReportService.defaultTemplate,
      );

      expect(record.user, '张三');
      expect(record.department, '研发部');
      expect(record.date, '2026-05-19');
      expect(record.fields['today_work'], 'a. 完成接口');
      expect(record.fields['tomorrow_plan'], 'a. 继续测试');
    });

    test('encodes and decodes full sync document with history', () {
      const record = ReportRecord(
        user: '张三',
        department: '研发部',
        date: '2026-05-19',
        fields: {'today_work': 'a. 完成接口'},
        report: 'report body',
      );
      final document = SyncDocument(
        kind: 'full',
        draft: SyncDraft.fromRecord(record),
        history: const [record],
        appVersion: '1.2.0',
        createdAt: DateTime(2026, 5, 19),
      );

      final decoded = sync.decodeDocument(sync.encodeDocument(document));

      expect(decoded.kind, 'full');
      expect(decoded.draft.user, '张三');
      expect(decoded.history.single.report, 'report body');
    });

    test('encodes and imports qr draft payload', () {
      const draft = SyncDraft(
        user: '李四',
        department: '产品部',
        date: '2026-05-19',
        fields: {'tomorrow_plan': 'a. 整理需求'},
        report: 'report body',
      );

      final result = sync.importAny(
        sync.encodeQrDraft(draft, '1.2.0'),
        template: ReportService.defaultTemplate,
      );

      expect(result.draft.user, '李四');
      expect(result.draft.fields['tomorrow_plan'], 'a. 整理需求');
      expect(result.history, isEmpty);
    });

    test('rejects invalid import content', () {
      expect(
        () => sync.importAny('', template: ReportService.defaultTemplate),
        throwsFormatException,
      );
      expect(
        () => sync.importAny('not a report',
            template: ReportService.defaultTemplate),
        throwsFormatException,
      );
    });
  });
}
