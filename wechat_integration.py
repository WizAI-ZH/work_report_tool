import subprocess
import os
import winreg


def get_wechat_path():
    """获取企业微信的安装路径"""
    try:
        # 尝试从注册表获取企业微信路径
        key_path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WXWork"
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path) as key:
            install_location = winreg.QueryValueEx(key, "InstallLocation")[0]
            wechat_exe = os.path.join(install_location, "WXWork.exe")
            if os.path.exists(wechat_exe):
                return wechat_exe
    except Exception:
        pass
    
    # 常见的企业微信安装路径
    common_paths = [
        r"C:\Program Files\WXWork\WXWork.exe",
        r"C:\Program Files (x86)\WXWork\WXWork.exe",
        r"D:\Program Files\WXWork\WXWork.exe",
        r"D:\Program Files (x86)\WXWork\WXWork.exe"
    ]
    
    for path in common_paths:
        if os.path.exists(path):
            return path
    
    return None


def open_wechat():
    """打开企业微信"""
    wechat_path = get_wechat_path()
    if wechat_path:
        try:
            # 隐藏窗口运行
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            subprocess.Popen([wechat_path], startupinfo=startupinfo)
            return True
        except Exception:
            return False
    return False


def open_wechat_chat(chat_name=None):
    """打开企业微信聊天窗口
    
    Args:
        chat_name: 聊天名称（可选）
    """
    wechat_path = get_wechat_path()
    if wechat_path:
        try:
            # 隐藏窗口运行
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            # 企业微信的命令行参数
            # 注意：企业微信的命令行参数可能会随版本变化
            if chat_name:
                # 尝试打开指定聊天
                subprocess.Popen([wechat_path, f"weixin://wxwork/{chat_name}"], startupinfo=startupinfo)
            else:
                # 直接打开企业微信
                subprocess.Popen([wechat_path], startupinfo=startupinfo)
            return True
        except Exception:
            return False
    return False


def is_wechat_running():
    """检查企业微信是否正在运行"""
    try:
        # 使用tasklist命令检查企业微信进程
        result = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq WXWork.exe"],
            capture_output=True,
            text=True
        )
        return "WXWork.exe" in result.stdout
    except Exception:
        return False


def send_to_wechat(content):
    """将内容发送到企业微信
    
    该函数会：
    1. 检查企业微信是否运行
    2. 如果未运行，尝试启动
    3. 复制内容到剪贴板
    4. 打开企业微信
    """
    import pyperclip
    
    try:
        # 复制内容到剪贴板
        pyperclip.copy(content)
        
        # 检查企业微信是否运行
        if not is_wechat_running():
            # 启动企业微信
            open_wechat()
        else:
            # 打开企业微信（如果已经运行，会切换到前台）
            open_wechat()
        
        return True
    except Exception:
        return False