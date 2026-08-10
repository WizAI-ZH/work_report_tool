import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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

  static bool debugSkipNetwork = false;

  static const _channel = MethodChannel('work_report_generator/platform');
  static const _latestReleaseUrl =
      'https://api.github.com/repos/WizAI-ZH/work_report_tool/releases/latest';

  final http.Client _client;

  Future<UpdateInfo?> fetchLatest({required String currentVersion}) async {
    if (debugSkipNetwork) {
      return null;
    }
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
    final asset = await _preferredAsset(assets);
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

  Future<Map<String, dynamic>?> _preferredAsset(
      List<Map<String, dynamic>> assets) async {
    final androidAbiFragments = await _androidAbiFragments();
    // 产物命名格式：WorkReportGenerator_<platform>_<version>.<ext>
    // 版本号插在平台关键词和扩展名之间，纯 endsWith('_windows.zip') 匹配不到
    // WorkReportGenerator_windows_1.2.21.zip，因此用 contains 匹配。
    final rules = <({String keyword, String fragment})>[
      if (Platform.isAndroid) ...[
        // split APK 文件名格式：WorkReportGenerator_android_<abi>_<version>.apk
        // 版本号在 abi 后面，不能纯用 endsWith，改用 contains 匹配 abi 片段
        for (final abi in androidAbiFragments)
          (keyword: 'android', fragment: abi),
        (keyword: 'android', fragment: '.apk'),
        (keyword: '', fragment: '.apk'),
      ],
      if (Platform.isWindows) ...[
        (keyword: 'windows', fragment: '.exe'),
        (keyword: 'windows', fragment: '.zip'),
        (keyword: 'windows', fragment: '.msix'),
      ],
      if (Platform.isMacOS) ...[
        (keyword: 'macos', fragment: '.dmg'),
        (keyword: 'macos', fragment: '.pkg'),
        (keyword: '', fragment: '.dmg'),
      ],
    ];

    for (final rule in rules) {
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.contains(rule.fragment) &&
            (rule.keyword.isEmpty || name.contains(rule.keyword))) {
          return asset;
        }
      }
    }
    return null;
  }

  /// 返回当前设备支持的 ABI 对应的文件名片段（如 '_arm64-v8a_'）。
  /// 用于匹配 split APK 文件名 WorkReportGenerator_android_<abi>_<version>.apk。
  Future<List<String>> _androidAbiFragments() async {
    if (!Platform.isAndroid) {
      return const [];
    }
    try {
      final abis = await _channel.invokeListMethod<String>('getSupportedAbis');
      final supported = abis ?? const [];
      const knownAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];
      return [
        for (final abi in knownAbis)
          if (supported.contains(abi)) '_${abi}_',
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<String> downloadAndInstall(
    UpdateInfo update, {
    void Function(double? progress, String message)? onProgress,
  }) async {
    final file = await _downloadAsset(update, onProgress: onProgress);

    if (Platform.isWindows) {
      if (file.path.toLowerCase().endsWith('.exe')) {
        onProgress?.call(1, '下载完成，正在启动安装器...');
        await Process.start(
          file.path,
          const ['/S'],
          mode: ProcessStartMode.detached,
        );
        return 'installer_started';
      }
      onProgress?.call(1, '下载完成，正在打开文件所在位置...');
      await Process.start(
        'explorer.exe',
        ['/select,${file.path}'],
        mode: ProcessStartMode.detached,
      );
      return 'downloaded_only';
    }

    if (Platform.isMacOS) {
      onProgress?.call(1, '下载完成，正在打开安装包...');
      await Process.start('open', [file.path], mode: ProcessStartMode.detached);
      return 'installer_started';
    }

    if (!Platform.isAndroid) {
      return 'unsupported_platform';
    }

    onProgress?.call(1, '下载完成，正在打开系统安装页...');
    final result = await _channel.invokeMethod<String>(
      'installApk',
      {'path': file.path},
    );
    return result ?? 'unknown';
  }

  Future<File> _downloadAsset(
    UpdateInfo update, {
    void Function(double? progress, String message)? onProgress,
  }) async {
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/${update.assetName}');
    if (await file.exists()) {
      await file.delete();
    }
    onProgress?.call(0, '正在连接下载服务器...');
    final request = http.Request('GET', Uri.parse(update.assetUrl));
    request.headers['User-Agent'] = 'WizWorkReportUpdater';
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw Exception('下载安装包失败：HTTP ${response.statusCode}');
    }
    final totalBytes = response.contentLength;
    var receivedBytes = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        final progress = totalBytes == null || totalBytes <= 0
            ? null
            : receivedBytes / totalBytes;
        final receivedMb = (receivedBytes / 1024 / 1024).toStringAsFixed(1);
        final totalText = totalBytes == null || totalBytes <= 0
            ? ''
            : ' / ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB';
        onProgress?.call(
            progress, '正在下载 ${update.assetName}：$receivedMb$totalText');
      }
    } finally {
      await sink.close();
    }
    return file;
  }

  String installPrompt() {
    if (Platform.isAndroid) {
      return 'Android 会自动下载 APK 并打开系统安装页，请按系统提示确认安装。';
    }
    if (Platform.isWindows) {
      return 'Windows 会自动下载安装包并启动安装器，请按安装器和系统权限提示完成更新。';
    }
    if (Platform.isMacOS) {
      return 'macOS 会自动下载安装包并打开，请按系统提示完成安装。';
    }
    return '当前平台暂不支持应用内自动安装，请到 Release 页面手动下载。';
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
