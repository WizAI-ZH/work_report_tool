import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_report_generator/main.dart';
import 'package:work_report_generator/models/report_models.dart';
import 'package:work_report_generator/services/storage_service.dart';
import 'package:work_report_generator/services/update_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('work_report_widget_test_');
    StorageService.debugBaseDirectory = tempDir;
    StorageService.skipLegacyImport = true;
    UpdateService.debugSkipNetwork = true;
    await StorageService(baseDirectory: tempDir).saveAiConfig(
      const AiConfig(
        apiKey: 'test-key',
        apiUrl: 'https://example.test/v1/chat/completions',
        model: 'test-model',
        availableModels: ['test-model'],
      ),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    StorageService.debugBaseDirectory = null;
    StorageService.skipLegacyImport = false;
    UpdateService.debugSkipNetwork = false;
  });

  testWidgets('home page starts and shows top-level actions', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const WorkReportApp());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump();

    expect(find.text('威智工作汇报器'), findsOneWidget);
    expect(find.text('v1.2.6'), findsOneWidget);
    expect(find.byIcon(Icons.settings_suggest_outlined), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
  });

  testWidgets('compact top bar keeps title visible and moves tools to menu',
      (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const WorkReportApp());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump();

    expect(find.text('威智工作汇报器'), findsOneWidget);
    expect(find.text('v1.2.6'), findsOneWidget);
    expect(find.byIcon(Icons.system_update_alt), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('同步'), findsOneWidget);
    expect(find.text('模板'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
  });
}
