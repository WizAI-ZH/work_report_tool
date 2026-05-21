import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/report_models.dart';
import 'services/ai_service.dart';
import 'services/report_service.dart';
import 'services/storage_service.dart';
import 'services/sync_service.dart';
import 'services/update_service.dart';
import 'services/wechat_service.dart';

const _freeApiKeyUrl = 'https://github.com/chatanywhere/GPT_API_free';
const _appName = '威智工作汇报器';
const _appVersion = '1.2.2';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WorkReportApp());
}

class WorkReportApp extends StatelessWidget {
  const WorkReportApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: _appName,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2563eb)),
        useMaterial3: true,
      ),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'CN'),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _storage = StorageService();
  final _reports = ReportService();
  final _ai = AiService();
  final _wechat = WechatService();
  final _updates = UpdateService();
  final _sync = SyncService();

  final _userController = TextEditingController();
  final _deptController = TextEditingController();
  final _dateController = TextEditingController();
  final _outputController = TextEditingController();
  final _fieldControllers = <String, TextEditingController>{};
  final _compactMoreKey = GlobalKey();

  var _template = ReportService.defaultTemplate;
  var _aiConfig = AiConfig.defaults;
  var _historyTokens = <String>[];
  var _busy = true;
  var _checkingUpdate = false;
  var _draftListenersAttached = false;

  @override
  void initState() {
    super.initState();
    _dateController.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    _bootstrap();
  }

  @override
  void dispose() {
    _userController.dispose();
    _deptController.dispose();
    _dateController.dispose();
    _outputController.dispose();
    for (final controller in _fieldControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      await _storage.importLegacyDataIfPresent();
      final template = await _storage.loadTemplate();
      final aiConfig = await _storage.loadAiConfig();
      final draft = await _storage.loadDraft();
      final history = await _storage.loadHistoryTokens();
      final pendingTasks = await _storage.loadPendingTasks();
      for (final item in template) {
        _fieldControllers.putIfAbsent(item.key, () => TextEditingController());
      }
      final preparedDraft = _reports.rollDraftToTodayIfNeeded(draft);
      _applyDraft(preparedDraft, template);
      final hasSavedTomorrowPlan =
          preparedDraft.containsKey('field_tomorrow_plan');
      if (!hasSavedTomorrowPlan &&
          (_fieldControllers['tomorrow_plan']?.text.trim().isEmpty ?? false) &&
          pendingTasks.isNotEmpty) {
        _fieldControllers['tomorrow_plan']?.text = pendingTasks
            .map((task) =>
                '${task.name}（0%，无，${task.planned.isEmpty ? task.name : task.planned}）')
            .join('\n');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _template = template;
        _aiConfig = aiConfig;
        _historyTokens = history;
        _busy = false;
      });
      _attachDraftAutosave();
      if (!identical(preparedDraft, draft)) {
        await _saveDraftQuietly();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) {
          return;
        }
        if (aiConfig.apiKey.trim().isEmpty) {
          await _configureAi(firstTime: true);
        }
        if (mounted) {
          await _checkForUpdates(silent: true);
        }
      });
    } catch (error) {
      for (final item in ReportService.defaultTemplate) {
        _fieldControllers.putIfAbsent(item.key, () => TextEditingController());
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _template = ReportService.defaultTemplate;
        _aiConfig = AiConfig.defaults;
        _historyTokens = [];
        _busy = false;
      });
      _attachDraftAutosave();
      _showSnack('本地数据初始化失败，已使用默认配置');
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          await _configureAi(firstTime: true);
          if (mounted) {
            await _checkForUpdates(silent: true);
          }
        }
      });
    }
  }

  void _applyDraft(
      Map<String, String> draft, List<ReportTemplateItem> template) {
    _userController.text = draft['user'] ?? _userController.text;
    _deptController.text = draft['department'] ?? _deptController.text;
    _dateController.text = draft['date'] ?? _dateController.text;
    for (final item in template) {
      final value = draft['field_${item.key}'];
      if (value != null) {
        _fieldControllers[item.key]?.text = value;
      }
    }
  }

  void _attachDraftAutosave() {
    if (_draftListenersAttached) {
      return;
    }
    _draftListenersAttached = true;
    _userController.addListener(_onDraftChanged);
    _deptController.addListener(_onDraftChanged);
    _dateController.addListener(_onDraftChanged);
    for (final controller in _fieldControllers.values) {
      controller.addListener(_onDraftChanged);
    }
  }

  void _onDraftChanged() {
    _saveDraftQuietly();
  }

  Future<void> _saveDraftQuietly() async {
    try {
      await _storage.saveDraft({
        'user': _userController.text,
        'department': _deptController.text,
        'date': _dateController.text,
        for (final entry in _fieldControllers.entries)
          'field_${entry.key}': entry.value.text,
      });
    } catch (_) {}
  }

  Future<void> _generateReport({bool copy = false}) async {
    final user = _userController.text.trim();
    final department = _deptController.text.trim();
    final date = _dateController.text.trim();
    if (user.isEmpty || department.isEmpty || date.isEmpty) {
      _showSnack('请填写姓名、部门和日期');
      return;
    }

    final lastTomorrow = await _storage.loadLastTomorrow('${user}_$department');
    final fields = {
      for (final item in _template)
        item.key: _fieldControllers[item.key]?.text.trim() ?? '',
    };
    final record = _reports.buildReport(
      user: user,
      department: department,
      date: date,
      template: _template,
      fields: fields,
      lastTomorrow: lastTomorrow,
    );
    await _storage.saveReport(
        _reports.reportToken(user, department, date), record);
    await _saveParsedTasks(fields, date);
    await _saveDraftQuietly();
    final history = await _storage.loadHistoryTokens();
    _outputController.text = record.report;
    if (copy) {
      await Clipboard.setData(ClipboardData(text: record.report));
    }
    if (!mounted) {
      return;
    }
    setState(() => _historyTokens = history);
    _showSnack(copy ? '汇报已生成并复制' : '汇报已生成');
  }

  Future<void> _copyOutput() async {
    final text = _outputController.text.trim();
    if (text.isEmpty) {
      _showSnack('没有可复制的汇报内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('已复制到剪贴板');
  }

  Future<void> _saveParsedTasks(Map<String, String> fields, String date) async {
    for (final value in fields.values) {
      for (final line in value.split('\n')) {
        final task = _reports.parseTaskInput(line);
        if (task != null) {
          final name = task['name']?.trim() ?? '';
          final progress = task['progress']?.trim() ?? '0%';
          final planned = task['planned']?.trim() ?? '';
          if (name.isEmpty ||
              (_isCompleteProgress(progress) && planned.isEmpty)) {
            continue;
          }
          await _storage.addTask(
            name: name,
            progress: progress,
            completed: task['completed']?.trim() ?? '',
            planned: planned,
            createdAt: date,
          );
        }
      }
    }
  }

  bool _isCompleteProgress(String progress) {
    final normalized = progress.replaceAll(RegExp(r'\s+'), '');
    return normalized == '100%' ||
        normalized == '预计100%' ||
        normalized == '预计完成100%';
  }

  Future<void> _sendToWechat() async {
    await _generateReport(copy: true);
    final opened = await _wechat.openEnterpriseWechat();
    _showSnack(opened ? '已复制内容并尝试打开企业微信' : '已复制内容，请手动打开企业微信粘贴');
  }

  Future<void> _showHistory() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: _historyTokens.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final token = _historyTokens[index];
            return ListTile(
              leading: const Icon(Icons.history),
              title: Text(token, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () async {
                final record = await _storage.loadHistoryDetail(token);
                if (!mounted || record == null) {
                  return;
                }
                _userController.text = record.user;
                _deptController.text = record.department;
                _dateController.text = record.date;
                for (final entry in record.fields.entries) {
                  _fieldControllers[entry.key]?.text = entry.value;
                }
                _outputController.text = record.report;
                await _saveDraftQuietly();
                if (!context.mounted) {
                  return;
                }
                Navigator.of(context).pop();
                _showSnack('历史记录已导入');
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _showSyncTools() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入与同步'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('导出同步文件'),
                subtitle: const Text('包含当前草稿和历史记录'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _exportSyncFile();
                },
              ),
              ListTile(
                leading: const Icon(Icons.file_open),
                title: const Text('导入同步文件'),
                subtitle: const Text('支持 .wizsync.json 和历史 JSON'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _importSyncFile();
                },
              ),
              ListTile(
                leading: const Icon(Icons.qr_code_2),
                title: const Text('生成同步二维码'),
                subtitle: const Text('仅同步当前编辑内容'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _showDraftQr();
                },
              ),
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('扫码导入'),
                subtitle: const Text('读取电脑端生成的草稿二维码'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _scanDraftQr();
                },
              ),
              ListTile(
                leading: const Icon(Icons.content_paste),
                title: const Text('从剪贴板导入汇报'),
                subtitle: const Text('粘贴已生成汇报文本'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _importFromClipboard();
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  SyncDraft _currentSyncDraft() {
    return SyncDraft(
      user: _userController.text.trim(),
      department: _deptController.text.trim(),
      date: _dateController.text.trim(),
      fields: {
        for (final entry in _fieldControllers.entries)
          entry.key: entry.value.text,
      },
      report: _outputController.text,
    );
  }

  Future<List<ReportRecord>> _loadAllHistoryRecords() async {
    final records = <ReportRecord>[];
    for (final token in await _storage.loadHistoryTokens()) {
      final record = await _storage.loadHistoryDetail(token);
      if (record != null) {
        records.add(record);
      }
    }
    return records;
  }

  Future<void> _exportSyncFile() async {
    try {
      final document = SyncDocument(
        kind: 'full',
        draft: _currentSyncDraft(),
        history: await _loadAllHistoryRecords(),
        appVersion: _appVersion,
        createdAt: DateTime.now(),
      );
      final now = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = 'WizWorkReportSync_$now.wizsync.json';
      final savedPath = await FilePicker.saveFile(
        dialogTitle: '保存同步文件',
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(_sync.encodeDocument(document))),
      );
      if (!mounted) {
        return;
      }
      _showSnack(savedPath == null ? '已取消导出' : '同步文件已导出');
    } catch (error) {
      if (mounted) {
        _showSnack('导出同步文件失败：$error');
      }
    }
  }

  Future<void> _importSyncFile() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择同步文件',
        type: FileType.custom,
        allowedExtensions: ['json', 'wizsync'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final bytes = result.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('未读取到文件内容');
      }
      await _importRawSyncContent(utf8.decode(bytes));
    } catch (error) {
      if (mounted) {
        _showSnack('导入失败：$error');
      }
    }
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showSnack('剪贴板没有可导入的文本');
      return;
    }
    try {
      await _importRawSyncContent(text);
    } catch (error) {
      if (mounted) {
        _showSnack('导入失败：$error');
      }
    }
  }

  Future<void> _importRawSyncContent(String raw) async {
    final result = _sync.importAny(raw, template: _template);
    await _applySyncImport(result);
  }

  Future<void> _applySyncImport(SyncImportResult result) async {
    for (final key in result.draft.fields.keys) {
      _fieldControllers.putIfAbsent(key, () {
        final controller = TextEditingController();
        if (_draftListenersAttached) {
          controller.addListener(_onDraftChanged);
        }
        return controller;
      });
    }
    _userController.text = result.draft.user;
    _deptController.text = result.draft.department;
    _dateController.text = result.draft.date;
    for (final entry in result.draft.fields.entries) {
      _fieldControllers[entry.key]?.text = entry.value;
    }
    _outputController.text = result.draft.report;
    await _storage.saveImportedHistory(
      result.history,
      (record) =>
          _reports.reportToken(record.user, record.department, record.date),
    );
    await _saveDraftQuietly();
    final history = await _storage.loadHistoryTokens();
    if (!mounted) {
      return;
    }
    setState(() => _historyTokens = history);
    final suffix =
        result.history.isEmpty ? '' : '，已合并 ${result.history.length} 条历史';
    _showSnack('${result.message}$suffix');
  }

  Future<void> _showDraftQr() async {
    try {
      final qrValue = _sync.encodeQrDraft(_currentSyncDraft(), _appVersion);
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('同步二维码'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                QrImageView(data: qrValue, size: 260),
                const SizedBox(height: 12),
                const Text('手机端点击“扫码导入”读取当前编辑内容'),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭')),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        _showSnack('$error');
      }
    }
  }

  Future<void> _scanDraftQr() async {
    var captured = false;
    String? rawValue;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('扫码导入'),
        content: SizedBox(
          width: 360,
          height: 420,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: MobileScanner(
              onDetect: (capture) {
                if (captured) {
                  return;
                }
                String? value;
                for (final barcode in capture.barcodes) {
                  if (barcode.rawValue != null) {
                    value = barcode.rawValue;
                    break;
                  }
                }
                if (value == null) {
                  return;
                }
                captured = true;
                rawValue = value;
                Navigator.pop(context);
              },
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ],
      ),
    );
    if (rawValue == null) {
      return;
    }
    try {
      await _importRawSyncContent(rawValue!);
    } catch (error) {
      if (mounted) {
        _showSnack('扫码导入失败：$error');
      }
    }
  }

  Future<void> _editTemplate() async {
    final controller = TextEditingController(
        text: _template.map((item) => '${item.title}|${item.key}').join('\n'));
    final result = await showDialog<List<ReportTemplateItem>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('模板定制'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            minLines: 8,
            maxLines: 14,
            decoration: const InputDecoration(
                helperText: '每行格式：标题|字段key', border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final items = controller.text
                  .split('\n')
                  .map((line) => line.trim())
                  .where((line) => line.isNotEmpty)
                  .map((line) {
                    final parts = line.split('|');
                    if (parts.length < 2) {
                      return null;
                    }
                    return ReportTemplateItem(
                        title: parts.first.trim(), key: parts[1].trim());
                  })
                  .whereType<ReportTemplateItem>()
                  .toList();
              if (items.isNotEmpty) {
                Navigator.pop(context, items);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) {
      return;
    }
    await _storage.saveTemplate(result);
    for (final item in result) {
      _fieldControllers.putIfAbsent(item.key, () {
        final controller = TextEditingController();
        if (_draftListenersAttached) {
          controller.addListener(_onDraftChanged);
        }
        return controller;
      });
    }
    if (!mounted) {
      return;
    }
    setState(() => _template = result);
    _showSnack('模板已保存');
  }

  Future<void> _configureAi({bool firstTime = false}) async {
    final result = await showDialog<AiConfig>(
      context: context,
      builder: (context) => _AiConfigDialog(
          initialConfig: _aiConfig, ai: _ai, firstTime: firstTime),
    );
    if (result == null) {
      return;
    }
    try {
      await _storage.saveAiConfig(result);
      if (!mounted) {
        return;
      }
      setState(() => _aiConfig = result);
      _showSnack('AI 配置已保存');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('AI 配置保存失败：$error');
    }
  }

  DateTime? _selectedReportDate() {
    try {
      return DateFormat('yyyy-MM-dd').parseStrict(_dateController.text.trim());
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickReportDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedReportDate() ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
      helpText: '选择汇报日期',
      cancelText: '取消',
      confirmText: '确定',
      locale: const Locale('zh', 'CN'),
    );
    if (picked == null) {
      return;
    }
    _dateController.text = DateFormat('yyyy-MM-dd').format(picked);
  }

  bool _tomorrowMayBeRestDay() {
    final date = _selectedReportDate();
    if (date == null) {
      return false;
    }
    final tomorrow = date.add(const Duration(days: 1));
    return tomorrow.weekday == DateTime.saturday ||
        tomorrow.weekday == DateTime.sunday;
  }

  Future<bool> _confirmTomorrowRestDay() async {
    final date = _selectedReportDate();
    final tomorrow = date?.add(const Duration(days: 1));
    final tomorrowText =
        tomorrow == null ? '明天' : DateFormat('yyyy-MM-dd').format(tomorrow);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认明日计划'),
        content: Text('$tomorrowText 可能是休息日，是否将“明日工作计划”填写为休息？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续生成建议')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('填写休息')),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _aiSuggest() async {
    final today = _fieldControllers['today_work']?.text.trim() ?? '';
    var tomorrow = _fieldControllers['tomorrow_plan']?.text.trim() ?? '';
    if (today.isEmpty && tomorrow.isEmpty) {
      _showSnack('请先填写今日工作或明日计划');
      return;
    }
    final tomorrowMayBeRestDay = _tomorrowMayBeRestDay();
    if (tomorrow.isEmpty && tomorrowMayBeRestDay) {
      final useRest = await _confirmTomorrowRestDay();
      if (!mounted) {
        return;
      }
      if (useRest) {
        tomorrow = '休息';
        _fieldControllers['tomorrow_plan']?.text = tomorrow;
        await _saveDraftQuietly();
      }
    }
    setState(() => _busy = true);
    late final String suggestion;
    try {
      suggestion = await _requestAiSuggestion(
        today: today,
        tomorrow: tomorrow,
        tomorrowMayBeRestDay: tomorrowMayBeRestDay,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (!mounted) {
      return;
    }
    final accepted = await showDialog<String>(
      context: context,
      builder: (context) => _AiSuggestionDialog(
        initialSuggestion: suggestion,
        onRegenerate: (feedback) => _requestAiSuggestion(
          today: today,
          tomorrow: tomorrow,
          tomorrowMayBeRestDay: tomorrowMayBeRestDay,
          feedback: feedback,
        ),
      ),
    );
    if (accepted != null && mounted) {
      _applySuggestion(accepted);
    }
  }

  Future<String> _requestAiSuggestion({
    required String today,
    required String tomorrow,
    required bool tomorrowMayBeRestDay,
    String feedback = '',
  }) {
    return _ai.suggest(
      config: _aiConfig,
      todayContent: today,
      tomorrowContent: tomorrow,
      reportDate: _dateController.text.trim(),
      tomorrowMayBeRestDay: tomorrowMayBeRestDay,
      userFeedback: feedback,
    );
  }

  void _applySuggestion(String suggestion) {
    final todayMatch =
        RegExp(r'1[、.]今日工作完成情况[；:]?\s*([\s\S]*?)(?=2[、.]明日工作计划|$)')
            .firstMatch(suggestion);
    final tomorrowMatch =
        RegExp(r'2[、.]明日工作计划[；:]?\s*([\s\S]*)').firstMatch(suggestion);
    if (todayMatch != null) {
      _fieldControllers['today_work']?.text =
          _reports.cleanSuggestedSection(todayMatch.group(1)!);
    }
    if (tomorrowMatch != null) {
      _fieldControllers['tomorrow_plan']?.text =
          _reports.cleanSuggestedSection(tomorrowMatch.group(1)!);
    }
    _showSnack('建议已应用');
  }

  void _clearInputs() {
    for (final controller in _fieldControllers.values) {
      controller.clear();
    }
    _outputController.clear();
    _saveDraftQuietly();
    _showSnack('已清空工作内容');
  }

  void _showSnack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _checkForUpdates({bool silent = false}) async {
    if (_checkingUpdate) {
      return;
    }
    setState(() => _checkingUpdate = true);
    try {
      final update = await _updates.fetchLatest(currentVersion: _appVersion);
      if (!mounted) {
        return;
      }
      if (update == null) {
        if (!silent) {
          _showSnack('当前已是最新版本');
        }
        return;
      }
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('发现新版本 v${update.version}'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('当前版本：v$_appVersion'),
                const SizedBox(height: 8),
                Text('安装包：${update.assetName}'),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Text(
                      update.notes.trim().isEmpty
                          ? '暂无更新说明。'
                          : update.notes.trim(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(_updates.installPrompt()),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.system_update_alt),
              label: const Text('更新'),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) {
        await _installUpdate(update);
      }
    } catch (error) {
      if (mounted && !silent) {
        _showSnack('$error');
      }
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  Future<void> _installUpdate(UpdateInfo update) async {
    final progress = ValueNotifier<_UpdateInstallProgress>(
      const _UpdateInstallProgress(null, '准备下载更新...'),
    );
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _UpdateProgressDialog(progress: progress),
    ));
    try {
      final result = await _updates.downloadAndInstall(
        update,
        onProgress: (value, message) {
          progress.value = _UpdateInstallProgress(value, message);
        },
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      switch (result) {
        case 'install_started':
          _showSnack('安装包已下载，请在系统安装页确认更新');
        case 'installer_started':
          _showSnack('安装包已下载并启动，请按提示完成安装');
        case 'downloaded_only':
          _showSnack('安装包已下载，请在打开的位置手动运行安装');
        case 'unknown_sources':
          _showSnack('已打开安装权限设置，允许后请回到应用重新点击更新');
        case 'unsupported_platform':
          _showSnack('当前平台暂不支持自动安装，请手动下载更新');
        default:
          _showSnack('无法自动打开安装包，请到 Release 页面手动下载');
      }
    } catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showSnack('更新失败：$error');
      }
    } finally {
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final compactTopBar = width < 700;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: compactTopBar ? 12 : null,
        title: compactTopBar
            ? _compactTitleBar()
            : const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_appName, maxLines: 1, overflow: TextOverflow.visible),
                  Text('v$_appVersion', style: TextStyle(fontSize: 12)),
                ],
              ),
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        actions: compactTopBar ? const [] : _wideAppBarActions(),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _HeaderFields(
                    userController: _userController,
                    deptController: _deptController,
                    dateController: _dateController,
                    onPickDate: _pickReportDate,
                  ),
                  const SizedBox(height: 16),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                            child: _InputFields(
                                template: _template,
                                controllers: _fieldControllers)),
                        const SizedBox(width: 16),
                        Expanded(
                            child: _OutputField(controller: _outputController)),
                      ],
                    )
                  else ...[
                    _InputFields(
                        template: _template, controllers: _fieldControllers),
                    const SizedBox(height: 16),
                    _OutputField(controller: _outputController),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                          onPressed: _sendToWechat,
                          icon: const Icon(Icons.send_outlined),
                          label: const Text('发送到企微')),
                      OutlinedButton.icon(
                          onPressed: _aiSuggest,
                          icon: const Icon(Icons.lightbulb_outline),
                          label: const Text('AI 建议')),
                      FilledButton.icon(
                          onPressed: () => _generateReport(),
                          icon: const Icon(Icons.article_outlined),
                          label: const Text('生成汇报')),
                      OutlinedButton.icon(
                          onPressed: _copyOutput,
                          icon: const Icon(Icons.copy),
                          label: const Text('复制')),
                      TextButton.icon(
                          onPressed: _clearInputs,
                          icon: const Icon(Icons.cleaning_services_outlined),
                          label: const Text('清空')),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  List<Widget> _wideAppBarActions() => [
        TextButton.icon(
            onPressed:
                _checkingUpdate ? null : () => _checkForUpdates(silent: false),
            icon: _checkingUpdate
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update_alt),
            label: const Text('更新')),
        TextButton.icon(
            onPressed: _configureAi,
            icon: const Icon(Icons.settings_suggest_outlined),
            label: const Text('AI')),
        TextButton.icon(
            onPressed: _showSyncTools,
            icon: const Icon(Icons.sync),
            label: const Text('同步')),
        TextButton.icon(
            onPressed: _editTemplate,
            icon: const Icon(Icons.tune),
            label: const Text('模板')),
        TextButton.icon(
            onPressed: _historyTokens.isEmpty ? null : _showHistory,
            icon: const Icon(Icons.history),
            label: const Text('历史')),
      ];

  Widget _compactTitleBar() => Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_appName, maxLines: 1, overflow: TextOverflow.visible),
                Text('v$_appVersion', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          ..._compactAppBarActions(),
        ],
      );

  List<Widget> _compactAppBarActions() => [
        IconButton(
          tooltip: '检查更新',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 42, height: 48),
          onPressed:
              _checkingUpdate ? null : () => _checkForUpdates(silent: false),
          icon: _checkingUpdate
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update_alt),
        ),
        IconButton(
          key: _compactMoreKey,
          tooltip: '更多',
          icon: const Icon(Icons.more_vert),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 42, height: 48),
          onPressed: _showCompactTopBarMenu,
        ),
      ];

  Future<void> _showCompactTopBarMenu() async {
    final menuContext = _compactMoreKey.currentContext;
    if (menuContext == null) {
      return;
    }
    final button = menuContext.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(menuContext).context.findRenderObject() as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = button
        .localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay);
    final selected = await showMenu<_TopBarMenuAction>(
      context: menuContext,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: _TopBarMenuAction.ai,
          child: ListTile(
            leading: Icon(Icons.settings_suggest_outlined),
            title: Text('AI'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: _TopBarMenuAction.sync,
          child: ListTile(
            leading: Icon(Icons.sync),
            title: Text('同步'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: _TopBarMenuAction.template,
          child: ListTile(
            leading: Icon(Icons.tune),
            title: Text('模板'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: _TopBarMenuAction.history,
          enabled: _historyTokens.isNotEmpty,
          child: const ListTile(
            leading: Icon(Icons.history),
            title: Text('历史'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
    switch (selected) {
      case _TopBarMenuAction.ai:
        _configureAi();
      case _TopBarMenuAction.sync:
        _showSyncTools();
      case _TopBarMenuAction.template:
        _editTemplate();
      case _TopBarMenuAction.history:
        _showHistory();
      case null:
        break;
    }
  }
}

enum _TopBarMenuAction { ai, sync, template, history }

class _UpdateInstallProgress {
  const _UpdateInstallProgress(this.progress, this.message);

  final double? progress;
  final String message;
}

class _UpdateProgressDialog extends StatelessWidget {
  const _UpdateProgressDialog({required this.progress});

  final ValueNotifier<_UpdateInstallProgress> progress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在更新'),
        content: ValueListenableBuilder<_UpdateInstallProgress>(
          valueListenable: progress,
          builder: (context, value, _) {
            final percent = value.progress == null
                ? ''
                : '${(value.progress!.clamp(0, 1) * 100).toStringAsFixed(0)}%';
            return SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: value.progress),
                  const SizedBox(height: 12),
                  Text(value.message),
                  if (percent.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(percent,
                        style: Theme.of(context).textTheme.titleSmall),
                  ],
                  const SizedBox(height: 12),
                  const Text('下载完成后会自动启动安装流程，请按系统提示确认。'),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AiConfigDialog extends StatefulWidget {
  const _AiConfigDialog({
    required this.initialConfig,
    required this.ai,
    required this.firstTime,
  });

  final AiConfig initialConfig;
  final AiService ai;
  final bool firstTime;

  @override
  State<_AiConfigDialog> createState() => _AiConfigDialogState();
}

class _AiConfigDialogState extends State<_AiConfigDialog> {
  late final TextEditingController _apiKey;
  late final TextEditingController _apiUrl;
  late final TextEditingController _model;
  late List<String> _models;
  var _loadingModels = false;
  var _testingConnection = false;
  var _hideApiKey = true;
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _apiKey = TextEditingController(text: widget.initialConfig.apiKey);
    _apiUrl = TextEditingController(text: widget.initialConfig.apiUrl);
    _model = TextEditingController(text: widget.initialConfig.model);
    _models = List<String>.from(widget.initialConfig.availableModels);
    _apiKey.addListener(_refreshApiKeyMask);
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _apiKey.removeListener(_refreshApiKeyMask);
    _apiKey.dispose();
    _apiUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  void _refreshApiKeyMask() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pasteFromClipboard(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) {
      return;
    }
    if (text == null || text.isEmpty) {
      _showSnack('剪贴板没有可粘贴的文本');
      return;
    }
    controller.value = TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  Future<void> _fetchModels() async {
    setState(() => _loadingModels = true);
    try {
      final fetched = await widget.ai.fetchModels(_currentConfig());
      if (!mounted) {
        return;
      }
      setState(() => _models = fetched);
      _showSnack(fetched.isEmpty ? '未获取到可用模型' : '已获取 ${fetched.length} 个模型');
    } catch (error) {
      if (mounted) {
        _showSnack('$error');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingModels = false);
      }
    }
  }

  Future<void> _testConnection() async {
    setState(() => _testingConnection = true);
    try {
      await widget.ai.testConnection(_currentConfig());
      if (mounted) {
        _showSnack('连接测试成功');
      }
    } catch (error) {
      if (mounted) {
        _showSnack('$error');
      }
    } finally {
      if (mounted) {
        setState(() => _testingConnection = false);
      }
    }
  }

  AiConfig _currentConfig() => AiConfig(
        apiKey: _apiKey.text.trim(),
        apiUrl: _apiUrl.text.trim().isEmpty
            ? AiConfig.defaults.apiUrl
            : _apiUrl.text.trim(),
        model: _model.text.trim().isEmpty
            ? AiConfig.defaults.model
            : _model.text.trim(),
        availableModels: _models,
      );

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    _toastEntry = OverlayEntry(
      builder: (context) {
        final theme = Theme.of(context);
        return Positioned(
          left: 16,
          right: 16,
          bottom: 20,
          child: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: theme.colorScheme.inverseSurface,
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(
                    message,
                    style: TextStyle(color: theme.colorScheme.onInverseSurface),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_toastEntry!);
    _toastTimer = Timer(const Duration(seconds: 3), () {
      _toastEntry?.remove();
      _toastEntry = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _loadingModels || _testingConnection;
    return AlertDialog(
      title: Text(widget.firstTime ? '欢迎使用 - 配置 AI' : 'AI 配置'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.firstTime) ...[
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('首次使用需要填写 API Key，保存后即可使用 AI 建议。'),
                ),
                const SizedBox(height: 12),
              ],
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('免费 API Key 获取',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      const SelectableText(_freeApiKeyUrl),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: busy ? null : _openFreeApiUrl,
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('打开网址'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy ? null : _copyFreeApiUrl,
                            icon: const Icon(Icons.copy),
                            label: const Text('复制网址'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _buildApiKeyField(busy),
              const SizedBox(height: 12),
              TextField(
                controller: _apiUrl,
                decoration: InputDecoration(
                  labelText: 'API URL',
                  suffixIcon: IconButton(
                    tooltip: '粘贴',
                    onPressed: busy ? null : () => _pasteFromClipboard(_apiUrl),
                    icon: const Icon(Icons.content_paste),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                decoration: InputDecoration(
                  labelText: '模型',
                  suffixIcon: SizedBox(
                    width: _models.isEmpty ? 48 : 96,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '粘贴',
                          onPressed:
                              busy ? null : () => _pasteFromClipboard(_model),
                          icon: const Icon(Icons.content_paste),
                        ),
                        if (_models.isNotEmpty)
                          PopupMenuButton<String>(
                            tooltip: '选择模型',
                            icon: const Icon(Icons.arrow_drop_down),
                            onSelected:
                                busy ? null : (value) => _model.text = value,
                            itemBuilder: (context) => [
                              for (final item in _models)
                                PopupMenuItem(value: item, child: Text(item)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : _fetchModels,
                    icon: _loadingModels
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_download_outlined),
                    label: Text(_loadingModels ? '获取中...' : '获取模型'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : _testConnection,
                    icon: _testingConnection
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: Text(_testingConnection ? '测试中...' : '测试连接'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(onPressed: busy ? null : _save, child: const Text('保存')),
      ],
    );
  }

  Widget _buildApiKeyField(bool busy) {
    final mask = '*' * _apiKey.text.characters.length;
    final color = Theme.of(context).colorScheme.onSurface;
    final transparentText =
        _hideApiKey ? const TextStyle(color: Colors.transparent) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            TextField(
              controller: _apiKey,
              keyboardType: TextInputType.text,
              obscureText: false,
              autocorrect: false,
              enableSuggestions: true,
              enableInteractiveSelection: true,
              textCapitalization: TextCapitalization.none,
              style: transparentText,
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            if (_hideApiKey && mask.isNotEmpty)
              Positioned.fill(
                left: 12,
                right: 12,
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        mask,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(color: color),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.filledTonal(
                tooltip: _hideApiKey ? '显示' : '隐藏',
                onPressed: busy
                    ? null
                    : () => setState(() => _hideApiKey = !_hideApiKey),
                icon: Icon(_hideApiKey
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
              ),
              IconButton.filledTonal(
                tooltip: '粘贴',
                onPressed: busy ? null : () => _pasteFromClipboard(_apiKey),
                icon: const Icon(Icons.content_paste),
              ),
              IconButton.filledTonal(
                tooltip: '清空',
                onPressed: busy || _apiKey.text.isEmpty ? null : _apiKey.clear,
                icon: const Icon(Icons.clear),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openFreeApiUrl() async {
    final opened = await launchUrl(Uri.parse(_freeApiKeyUrl),
        mode: LaunchMode.externalApplication);
    if (mounted && !opened) {
      _showSnack('无法打开网址，请复制后在浏览器访问');
    }
  }

  Future<void> _copyFreeApiUrl() async {
    await Clipboard.setData(const ClipboardData(text: _freeApiKeyUrl));
    if (mounted) {
      _showSnack('网址已复制');
    }
  }

  void _save() {
    if (_apiKey.text.trim().isEmpty) {
      _showSnack('请先填写 API Key');
      return;
    }
    Navigator.pop(context, _currentConfig());
  }
}

class _AiSuggestionDialog extends StatefulWidget {
  const _AiSuggestionDialog({
    required this.initialSuggestion,
    required this.onRegenerate,
  });

  final String initialSuggestion;
  final Future<String> Function(String feedback) onRegenerate;

  @override
  State<_AiSuggestionDialog> createState() => _AiSuggestionDialogState();
}

class _AiSuggestionDialogState extends State<_AiSuggestionDialog> {
  late String _suggestion;
  final _feedbackController = TextEditingController();
  var _regenerating = false;

  @override
  void initState() {
    super.initState();
    _suggestion = widget.initialSuggestion;
  }

  @override
  void dispose() {
    _feedbackController.dispose();
    super.dispose();
  }

  Future<void> _regenerate() async {
    FocusScope.of(context).unfocus();
    setState(() => _regenerating = true);
    try {
      final next = await widget.onRegenerate(_feedbackController.text.trim());
      if (!mounted) {
        return;
      }
      setState(() => _suggestion = next);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重新生成失败：$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _regenerating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.viewInsets.bottom - 180;
    final contentHeight = availableHeight.clamp(260.0, 520.0);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: AlertDialog(
        title: const Text('AI 建议'),
        content: SizedBox(
          width: 640,
          height: contentHeight,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: SelectableText(_suggestion),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('重新生成时可填写的调整要求（可选）',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _feedbackController,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                decoration: const InputDecoration(
                  hintText: '不满意时再填，例如：明日计划更具体；不要使用“推进”这类词',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: _regenerating ? null : () => Navigator.pop(context),
              child: const Text('关闭')),
          OutlinedButton.icon(
            onPressed: _regenerating ? null : _regenerate,
            icon: _regenerating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(_regenerating ? '生成中...' : '重新生成'),
          ),
          FilledButton(
            onPressed: _regenerating
                ? null
                : () => Navigator.pop(context, _suggestion),
            child: const Text('应用建议'),
          ),
        ],
      ),
    );
  }
}

class _HeaderFields extends StatelessWidget {
  const _HeaderFields({
    required this.userController,
    required this.deptController,
    required this.dateController,
    required this.onPickDate,
  });

  final TextEditingController userController;
  final TextEditingController deptController;
  final TextEditingController dateController;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        SizedBox(
            width: 220,
            child: TextField(
                controller: userController,
                decoration: const InputDecoration(
                    labelText: '姓名', border: OutlineInputBorder()))),
        SizedBox(
            width: 220,
            child: TextField(
                controller: deptController,
                decoration: const InputDecoration(
                    labelText: '部门', border: OutlineInputBorder()))),
        SizedBox(
          width: 240,
          child: TextField(
            controller: dateController,
            readOnly: true,
            onTap: onPickDate,
            decoration: InputDecoration(
              labelText: '汇报日期',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '选择日期',
                onPressed: onPickDate,
                icon: const Icon(Icons.calendar_today_outlined),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _InputFields extends StatelessWidget {
  const _InputFields({required this.template, required this.controllers});

  final List<ReportTemplateItem> template;
  final Map<String, TextEditingController> controllers;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('工作内容填写区', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final item in template) ...[
          TextField(
            controller: controllers[item.key],
            minLines: 5,
            maxLines: 8,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
                labelText: item.title,
                alignLabelWithHint: true,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _OutputField extends StatelessWidget {
  const _OutputField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('生成的汇报内容', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
            controller: controller,
            readOnly: true,
            minLines: 14,
            maxLines: 20,
            decoration: const InputDecoration(border: OutlineInputBorder())),
      ],
    );
  }
}
