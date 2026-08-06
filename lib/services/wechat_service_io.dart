import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class WechatService {
  static const _platform = MethodChannel('work_report_generator/platform');

  Future<bool> openEnterpriseWechat() async {
    if (Platform.isWindows) {
      for (final path in _windowsPaths) {
        if (await File(path).exists()) {
          await Process.start(path, const []);
          return true;
        }
      }
    }

    if (Platform.isAndroid) {
      try {
        final opened =
            await _platform.invokeMethod<bool>('openEnterpriseWechat');
        if (opened == true) {
          return true;
        }
      } catch (_) {}
    }

    for (final uri in _enterpriseWechatUris) {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return true;
      }
    }
    return false;
  }

  /// 一键发送到企业微信：打开企微 → 搜索群 → 进入会话 → 粘贴汇报 → 发送。
  /// Windows 用 .NET UIAutomation 操作控件树；Android 通过 MethodChannel
  /// 调用无障碍服务完成点击/输入。
  /// [message] 是要发送的汇报正文，[groupName] 是目标群名。
  /// 返回值：
  /// - "sent"：发送成功
  /// - "no_accessibility"：Android 未开启无障碍服务，需调用方引导授权
  /// - "failed"：其他失败，调用方提示手动粘贴
  Future<String> sendToEnterpriseWechatWithStatus({
    required String message,
    required String groupName,
  }) async {
    final target = groupName.trim().isEmpty ? '文件传输助手' : groupName.trim();

    if (Platform.isAndroid) {
      try {
        final result = await _platform.invokeMethod<String>(
          'sendToEnterpriseWechat',
          <String, dynamic>{
            'message': message,
            'groupName': target,
          },
        );
        return result ?? 'failed';
      } catch (_) {
        return 'failed';
      }
    }

    if (Platform.isWindows) {
      final ok = await _windowsSend(target, message);
      return ok ? 'sent' : 'failed';
    }

    // 其他平台暂不支持全自动，退化为打开企微+复制内容。
    await Clipboard.setData(ClipboardData(text: message));
    await openEnterpriseWechat();
    return 'failed';
  }

  /// 兼容旧调用：返回是否发送成功。Android 端若未开启无障碍服务，
  /// 调用方无法收到引导提示，建议改用 [sendToEnterpriseWechatWithStatus]。
  Future<bool> sendToEnterpriseWechat({
    required String message,
    required String groupName,
  }) async {
    final status = await sendToEnterpriseWechatWithStatus(
      message: message,
      groupName: groupName,
    );
    return status == 'sent';
  }

  /// Android：检查无障碍服务是否已启用。
  Future<bool> isAccessibilityEnabled() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _platform.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android：打开系统无障碍设置页。
  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _platform.invokeMethod<bool>('openAccessibilitySettings');
    } catch (_) {}
  }

  Future<bool> _windowsSend(String groupName, String message) async {
    // 优先用独立 exe（PyInstaller 打包，含 OCR 模型和所有依赖），
    // 用户的机器不需要装 Python。开发时 fallback 到 python 脚本。
    final helperPath = _resolveHelperPath();
    if (helperPath != null) {
      try {
        final env = Map<String, String>.from(Platform.environment)
          ..['WECHAT_GROUP'] = groupName
          ..['WECHAT_MESSAGE'] = message;
        final isExe = helperPath.endsWith('.exe');
        final result = await Process.run(
          isExe ? helperPath : 'python',
          isExe ? <String>[] : <String>[helperPath],
          environment: env,
          stdoutEncoding: null,
          stderrEncoding: null,
        );
        if (result.exitCode == 0) {
          return true;
        }
        // exe/脚本失败（找不到窗口等），继续走兜底。
      } catch (_) {
        // exe 不存在或脚本异常，继续走兜底。
      }
    }

    // 兜底：启动企微 + 复制到剪贴板，提示用户手动粘贴发送。
    String? exePath;
    for (final path in _windowsPaths) {
      if (await File(path).exists()) {
        exePath = path;
        break;
      }
    }
    await Clipboard.setData(ClipboardData(text: message));
    if (exePath != null) {
      try {
        await Process.start(exePath, const []);
      } catch (_) {}
    }
    return false;
  }

  /// 查找企微发送助手路径。优先找打包后的独立 exe（不需要 Python），
  /// 开发时 fallback 到 python 脚本。
  /// 打包后：可执行文件同级 scripts/send_to_wework.exe
  /// 开发时：cwd/scripts/send_to_wework.py
  String? _resolveHelperPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      // 打包后：独立 exe（PyInstaller 打包，含所有依赖）
      '$exeDir\\scripts\\send_to_wework.exe',
      // 开发时：python 脚本
      '${Directory.current.path}\\scripts\\send_to_wework.py',
      // 打包后 fallback：python 脚本（开发者机器）
      '$exeDir\\scripts\\send_to_wework.py',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  static final _enterpriseWechatUris = [
    Uri.parse('wxwork://'),
    Uri.parse('wxworklocal://'),
    Uri.parse('weixin://wxwork/'),
  ];

  static const _windowsPaths = [
    r'C:\Program Files\WXWork\WXWork.exe',
    r'C:\Program Files (x86)\WXWork\WXWork.exe',
    r'D:\Program Files\WXWork\WXWork.exe',
    r'D:\Program Files (x86)\WXWork\WXWork.exe',
  ];
}
