import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
  });

  final String version;
  final String releaseUrl;
  final String notes;
  final String assetName;
  final String assetUrl;
}

class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const _channel = MethodChannel('work_report_generator/platform');
  static const _latestReleaseUrl =
      'https://api.github.com/repos/WizAI-ZH/work_report_tool/releases/latest';

  final http.Client _client;

  Future<UpdateInfo?> fetchLatest({required String currentVersion}) async {
    final response = await _client.get(
      Uri.parse(_latestReleaseUrl),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'WizWorkReportUpdater',
      },
    );
    if (response.statusCode != 200) {
      throw Exception('检查更新失败：HTTP ${response.statusCode}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final version = (data['tag_name'] as String? ?? '')
        .trim()
        .replaceFirst(RegExp(r'^[vV]'), '');
    if (version.isEmpty || compareVersions(version, currentVersion) <= 0) {
      return null;
    }

    final assets = (data['assets'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final asset = _preferredAsset(assets);
    if (asset == null) {
      throw Exception('发现新版本，但没有找到当前平台可用的安装包');
    }

    return UpdateInfo(
      version: version,
      releaseUrl: data['html_url'] as String? ?? '',
      notes: data['body'] as String? ?? '',
      assetName: asset['name'] as String? ?? '',
      assetUrl: asset['browser_download_url'] as String? ?? '',
    );
  }

  Map<String, dynamic>? _preferredAsset(List<Map<String, dynamic>> assets) {
    bool matches(String name) {
      final lower = name.toLowerCase();
      if (Platform.isAndroid) {
        return lower.endsWith('_android.apk') || lower.endsWith('.apk');
      }
      if (Platform.isWindows) {
        return lower.endsWith('_windows_setup.exe') ||
            lower.endsWith('_windows.zip');
      }
      if (Platform.isMacOS) {
        return lower.endsWith('.dmg') || lower.endsWith('.pkg');
      }
      return false;
    }

    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (matches(name)) {
        return asset;
      }
    }
    return null;
  }

  Future<String> downloadAndInstall(UpdateInfo update) async {
    if (!Platform.isAndroid) {
      final opened = await launchUrl(
        Uri.parse(update.releaseUrl),
        mode: LaunchMode.externalApplication,
      );
      return opened ? 'opened_release' : 'open_failed';
    }

    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/${update.assetName}');
    final request = http.Request('GET', Uri.parse(update.assetUrl));
    request.headers['User-Agent'] = 'WizWorkReportUpdater';
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('下载安装包失败：HTTP ${response.statusCode}');
    }
    await response.stream.pipe(file.openWrite());

    final result = await _channel.invokeMethod<String>(
      'installApk',
      {'path': file.path},
    );
    return result ?? 'unknown';
  }

  static int compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    final maxLength = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < maxLength; i += 1) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) {
        return av.compareTo(bv);
      }
    }
    return 0;
  }

  static List<int> _versionParts(String version) {
    return version
        .split(RegExp(r'[.+-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
  }
}
