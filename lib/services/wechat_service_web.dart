class WechatService {
  Future<bool> openEnterpriseWechat() async {
    return false;
  }

  Future<String> sendToEnterpriseWechatWithStatus({
    required String message,
    required String groupName,
  }) async {
    return 'failed';
  }

  Future<bool> sendToEnterpriseWechat({
    required String message,
    required String groupName,
  }) async {
    return false;
  }

  Future<bool> isAccessibilityEnabled() async => false;

  Future<void> openAccessibilitySettings() async {}
}
