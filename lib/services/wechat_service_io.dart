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
        final opened = await _platform.invokeMethod<bool>('openEnterpriseWechat');
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
