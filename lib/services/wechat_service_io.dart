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
      // 企微风控限制自动化发送，Windows 端只打开企微+复制到剪贴板，
      // 由用户手动粘贴发送。返回 'manual' 让调用方显示友好提示。
      await _windowsSend(target, message);
      return 'manual';
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
    // 企微对自动化操作有风控，全自动发送会被限制（账号可能被禁言/封禁）。
    // 故 Windows 端只做：启动企微 + 复制汇报到剪贴板，由用户手动粘贴发送。
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
