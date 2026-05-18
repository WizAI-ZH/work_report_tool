import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_report_generator/main.dart';
import 'package:work_report_generator/services/storage_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('work_report_widget_test_');
    StorageService.debugBaseDirectory = tempDir;
    StorageService.skipLegacyImport = true;
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    StorageService.debugBaseDirectory = null;
    StorageService.skipLegacyImport = false;
  });

  testWidgets('home page starts and shows top-level actions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    await tester.pumpWidget(const WorkReportApp());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump();

    expect(find.text('威智工作汇报器'), findsOneWidget);
    expect(find.text('v1.1.9'), findsOneWidget);
    expect(find.byIcon(Icons.settings_suggest_outlined), findsOneWidget);
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
