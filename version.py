import json
import os
import sys

VERSION_FILE = 'version.json'

# 默认版本号（当无法读取version.json时使用）
DEFAULT_VERSION = {
    'major': 1,
    'minor': 0,
    'patch': 11,
    'build': 0,
    'description': '工作汇报输出器'
}


def load_version():
    """加载版本信息"""
    # 尝试多个路径查找version.json
    possible_paths = [
        VERSION_FILE,  # 当前目录
        os.path.join(os.path.dirname(sys.executable), VERSION_FILE),  # exe所在目录
        os.path.join(os.path.dirname(__file__), VERSION_FILE),  # 脚本所在目录
    ]
    
    for path in possible_paths:
        if os.path.exists(path):
            try:
                with open(path, 'r', encoding='utf-8') as f:
                    return json.load(f)
            except Exception:
                continue
    
    # 如果都找不到，返回默认版本
    return DEFAULT_VERSION


def save_version(version):
    """保存版本信息"""
    try:
        with open(VERSION_FILE, 'w', encoding='utf-8') as f:
            json.dump(version, f, indent=4, ensure_ascii=False)
        return True
    except Exception:
        return False


def get_version_string():
    """获取版本号字符串"""
    version = load_version()
    return f"v{version['major']}.{version['minor']}.{version['patch']}.{version['build']}"


def increment_version(part='patch'):
    """递增版本号"""
    version = load_version()
    
    if part == 'major':
        version['major'] += 1
        version['minor'] = 0
        version['patch'] = 0
        version['build'] = 0
    elif part == 'minor':
        version['minor'] += 1
        version['patch'] = 0
        version['build'] = 0
    elif part == 'patch':
        version['patch'] += 1
        version['build'] = 0
    else:  # build
        version['build'] += 1
    
    save_version(version)
    return version


def get_version_info():
    """获取完整的版本信息"""
    version = load_version()
    return {
        'version': get_version_string(),
        'major': version['major'],
        'minor': version['minor'],
        'patch': version['patch'],
        'build': version['build'],
        'description': version['description']
    }