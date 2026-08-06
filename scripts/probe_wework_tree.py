"""探测企微搜索结果列表的控件树结构。
激活企微 → Ctrl+F → 输入测试词 → 遍历控件树打印有文本的节点。"""
import time
import uiautomation as ua

# 找企微主窗口
wechat = None
for w in ua.GetRootControl().GetChildren():
    name = w.Name
    if name and "企业微信" in name:
        wechat = w
        break
if not wechat:
    print("NO_WINDOW")
    exit(2)

print(f"window: {wechat.Name} class={wechat.ClassName}")
wechat.SetFocus()
time.sleep(0.5)

# Ctrl+F 搜索
import pyautogui
pyautogui.hotkey("ctrl", "f")
time.sleep(0.9)
pyautogui.hotkey("ctrl", "a")
time.sleep(0.1)
import pyperclip
pyperclip.copy("文件传输助手")
time.sleep(0.15)
pyautogui.hotkey("ctrl", "v")
print("searched, waiting for results...")
time.sleep(2.5)

# 遍历控件树，打印有文本的节点
print("=== 控件树（有文本的节点）===")
def walk(ctrl, depth=0, max_depth=10):
    if depth > max_depth:
        return
    try:
        name = ctrl.Name
        ctype = ctrl.ControlTypeName
        cls = ctrl.ClassName
        if name and name.strip():
            rect = ctrl.BoundingRectangle
            print(f"{'  '*depth}[{ctype}] cls={cls} name={name!r} rect=({rect.left},{rect.top},{rect.right},{rect.bottom})")
    except Exception:
        pass
    try:
        for child in ctrl.GetChildren():
            walk(child, depth+1, max_depth)
    except Exception:
        pass

walk(wechat)
print("=== done ===")
