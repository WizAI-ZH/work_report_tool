import os
import subprocess
import json
from version import get_version_string, increment_version, load_version, save_version

# 项目配置
PROJECT_NAME = "WorkReportGenerator"
MAIN_SCRIPT = "main.py"
ICON_FILE = "wiz_logo.png"
RESOURCES = ["wiz_logo.png", "version.json"]


def run_command(cmd, cwd=None):
    """运行命令并返回结果"""
    try:
        result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
        print(f"执行命令: {cmd}")
        print(f"返回码: {result.returncode}")
        if result.stdout:
            print(f"输出: {result.stdout}")
        if result.stderr:
            print(f"错误: {result.stderr}")
        return result.returncode == 0
    except Exception as e:
        print(f"执行命令出错: {e}")
        return False


def update_spec_file():
    """更新spec文件以包含版本号"""
    version = get_version_string()
    spec_content = """# -*- mode: python ; coding: utf-8 -*-

a = Analysis(
    ['{MAIN_SCRIPT}'],
    pathex=[],
    binaries=[],
    datas={datas_list},
    hiddenimports=[],
    hookspath=[],
    hooksconfig={{}},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='{PROJECT_NAME}_{version_str}',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['{ICON_FILE}'],
)
""".format(
        MAIN_SCRIPT=MAIN_SCRIPT,
        datas_list=str([(res, ".") for res in RESOURCES]),
        PROJECT_NAME=PROJECT_NAME,
        version_str=version.replace("v", ""),
        ICON_FILE=ICON_FILE
    )
    
    with open('build.spec', 'w', encoding='utf-8') as f:
        f.write(spec_content)
    print("更新spec文件完成")


def git_commit():
    """执行git commit来更新版本"""
    version = get_version_string()
    commit_message = f"Update version to {version}"
    
    # 检查是否有git环境
    if not os.path.exists('.git'):
        print("未检测到git环境，跳过git commit")
        return False
    
    # 添加文件
    if not run_command("git add .", cwd=os.getcwd()):
        return False
    
    # 提交更改
    if not run_command(f'git commit -m "{commit_message}"', cwd=os.getcwd()):
        return False
    
    print(f"Git commit成功: {commit_message}")
    return True


def build():
    """执行打包流程"""
    # 1. 递增版本号
    version_info = increment_version()
    version = get_version_string()
    print(f"当前版本: {version}")
    
    # 2. 更新spec文件
    update_spec_file()
    
    # 3. 执行PyInstaller打包
    print("开始打包...")
    success = run_command(f"pyinstaller build.spec --clean")
    
    if success:
        # 4. 复制打包产物到发布目录
        dist_dir = "dist"
        release_dir = os.path.join("releases", version)
        
        if not os.path.exists(release_dir):
            os.makedirs(release_dir)
        
        # 复制可执行文件
        exe_name = f"{PROJECT_NAME}_{version.replace('v', '')}.exe"
        src_exe = os.path.join(dist_dir, exe_name)
        dst_exe = os.path.join(release_dir, exe_name)
        
        if os.path.exists(src_exe):
            import shutil
            shutil.copy2(src_exe, dst_exe)
            print(f"已复制可执行文件到: {dst_exe}")
        
        # 5. 生成发布说明
        generate_release_notes(release_dir, version_info)
        
        # 6. 执行git commit
        git_commit()
        
        print("\n打包完成！")
        print(f"版本: {version}")
        print(f"发布目录: {release_dir}")
    else:
        print("打包失败！")


def generate_release_notes(release_dir, version_info):
    """生成发布说明文件"""
    version_str = f"v{version_info['major']}.{version_info['minor']}.{version_info['patch']}.{version_info['build']}"
    notes = f"""# {PROJECT_NAME} 发布说明

## 版本信息
- 版本: {version_str}
- 发布日期: {get_current_date()}

## 功能特性
- 工作汇报生成功能
- 历史记录管理
- 智能建议
- 模板定制
- 数据统计分析

## 使用说明
1. 填写姓名、部门和日期
2. 填写工作内容
3. 点击生成汇报
4. 复制或导出汇报内容

## 系统要求
- Windows 7 及以上
- .NET Framework 4.0 及以上
"""
    
    with open(os.path.join(release_dir, "RELEASE_NOTES.md"), 'w', encoding='utf-8') as f:
        f.write(notes)


def get_current_date():
    """获取当前日期"""
    from datetime import datetime
    return datetime.now().strftime("%Y-%m-%d")


def batch_build(versions=3):
    """批量构建多个版本"""
    for i in range(versions):
        print(f"\n=== 构建版本 {i+1}/{versions} ===")
        build()


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="工作汇报输出器打包脚本")
    parser.add_argument('--batch', type=int, default=1, help='批量构建的版本数量')
    parser.add_argument('--version', action='store_true', help='显示当前版本')
    
    args = parser.parse_args()
    
    if args.version:
        print(f"当前版本: {get_version_string()}")
    elif args.batch > 1:
        batch_build(args.batch)
    else:
        build()