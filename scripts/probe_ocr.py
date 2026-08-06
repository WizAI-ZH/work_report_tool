"""OCR 探测：激活企微 → 搜索 → 截图 → OCR 识别，打印所有文本及坐标。"""
import time
import pyautogui
import pyperclip
import pygetwindow as gw
from mss import mss
from rapidocr_onnxruntime import RapidOCR

# 找企微窗口
win = None
for w in gw.getAllWindows():
    if w.title and "企业微信" in w.title and w.width > 200 and w.height > 200:
        win = w
        break
if not win:
    print("NO_WINDOW")
    exit(2)

# 激活
try:
    win.minimize(); time.sleep(0.15); win.restore(); time.sleep(0.15)
except Exception:
    pass
try:
    win.activate()
except Exception:
    pass
pyautogui.press("alt"); time.sleep(0.05); pyautogui.press("alt")
try:
    win.activate()
except Exception:
    pass
time.sleep(0.5)

# 搜索
pyautogui.hotkey("ctrl", "f")
time.sleep(0.9)
pyautogui.hotkey("ctrl", "a")
time.sleep(0.1)
pyperclip.copy("文件传输助手")
time.sleep(0.15)
pyautogui.hotkey("ctrl", "v")
print("searched, waiting...")
time.sleep(2.5)

# 截图企微窗口区域
left, top = win.left, win.top
right, bottom = win.right, win.bottom
print(f"window rect: ({left},{top},{right},{bottom})")

sct = mss()
monitor = {"top": top, "left": left, "width": right-left, "height": bottom-top}
shot = sct.grab(monitor)
# mss 返回 BGRA，转成 PIL Image 给 rapidocr
from PIL import Image
img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
img.save(r"C:\威智工作汇报器测试\scripts\debug_search_screenshot.png")
print("screenshot saved")

# OCR
ocr = RapidOCR()
result, elapse = ocr(img)
print(f"OCR elapse: {elapse}")
if result:
    for box, text, score in result:
        # box 是 4 个点的坐标 [[x1,y1],[x2,y2],[x3,y3],[x4,y4]]（相对图片左上角）
        cx = sum(p[0] for p in box) / 4 + left
        cy = sum(p[1] for p in box) / 4 + top
        print(f"  text={text!r} score={score:.2f} center=({int(cx)},{int(cy)})")
print("=== done ===")
