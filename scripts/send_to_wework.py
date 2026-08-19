"""企业微信自动发送脚本（OCR 版）。

被 Flutter 端 wechat_service_io.dart 调用。流程：
1. 找企微窗口并激活（找不到则启动 WXWork.exe 后等待）。
2. Ctrl+F 聚焦搜索框 → 粘贴群名。
3. 截图企微窗口 → OCR 识别 → 找到群名对应的搜索结果项 → 点击进入会话。
4. 粘贴汇报正文 → 回车发送。

参数通过环境变量传入（避免中文命令行编码问题）：
- WECHAT_GROUP：目标群名
- WECHAT_MESSAGE：汇报正文（多行）

退出码：
- 0：发送成功
- 2：找不到企微窗口（未安装/启动失败）
- 3：Python 缺少依赖
- 4：OCR 未找到匹配群名的搜索结果
"""

import ctypes
import os
import subprocess
import sys
import time
from datetime import datetime

# 必须在导入 pyautogui/pygetwindow/mss 之前设置 DPI 感知。
# 否则高 DPI 缩放（125%/150%/200%）下三者坐标系不一致：
#   - mss 截图始终用物理像素
#   - pygetwindow/pyautogui 在非感知进程里用逻辑像素
# 导致 OCR 算出的坐标传给 click 时整体偏移，搜索框这种小区域就会
# "差一点才点中"。设置为 PER_MONITOR_AWARE 后三者统一用物理像素。
try:
    # PROCESS_PER_MONITOR_DPI_AWARE = 2
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except (AttributeError, OSError):
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except (AttributeError, OSError):
        pass

try:
    import pyautogui
    import pygetwindow as gw
    import pyperclip
    from mss import mss
    from PIL import Image
    from rapidocr_onnxruntime import RapidOCR
except ImportError as exc:
    print(f"MISSING_DEP: {exc}", file=sys.stderr)
    sys.exit(3)

# 企微窗口可能在副屏（负坐标），pyautogui fail-safe 会误触发，禁用。
pyautogui.FAILSAFE = False


def get_dpi_scale():
    """获取主屏 DPI 缩放比例（1.0=100%, 1.25=125%, 1.5=150%）。
    仅用于日志记录，便于排查坐标偏移。"""
    try:
        hdc = ctypes.windll.user32.GetDC(0)
        dpi = ctypes.windll.gdi32.GetDeviceCaps(hdc, 88)  # LOGPIXELSX
        ctypes.windll.user32.ReleaseDC(0, hdc)
        return round(dpi / 96.0, 3)
    except Exception:
        return 1.0


def get_window_dpi_scale(win):
    """获取窗口所在屏幕的 DPI 缩放比例（PER_MONITOR_AWARE 下副屏可能不同）。
    用于计算搜索入口等固定 UI 元素的物理像素偏移。"""
    try:
        hwnd = getattr(win, '_h', None) or getattr(win, '_hWnd', None)
        if not hwnd:
            return get_dpi_scale()
        # MONITOR_DEFAULTTONEAREST = 2
        monitor = ctypes.windll.user32.MonitorFromWindow(hwnd, 2)
        dpi_x = ctypes.c_uint()
        dpi_y = ctypes.c_uint()
        # MDT_EFFECTIVE_DPI = 0
        ctypes.windll.shcore.GetDpiForMonitor(
            monitor, 0, ctypes.byref(dpi_x), ctypes.byref(dpi_y))
        return round(dpi_x.value / 96.0, 3)
    except Exception:
        return get_dpi_scale()


class _RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


def get_foreground_window_rect():
    """返回前台窗口 (left, top, right, bottom) 或 None。
    点击企微搜索入口后，"全局搜索"浮层会成为前台窗口；即使浮层被拖到
    副屏，它仍是前台窗口，故取其 rect 作为 OCR 区域即可适配任意位置。
    用 ctypes 调 user32，不引入 pywin32 依赖。"""
    try:
        hwnd = ctypes.windll.user32.GetForegroundWindow()
        if not hwnd:
            return None
        rect = _RECT()
        if not ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            return None
        # 过滤掉异常尺寸（<100 或负宽高，避免误判）。
        if rect.right - rect.left < 100 or rect.bottom - rect.top < 100:
            return None
        return (rect.left, rect.top, rect.right, rect.bottom)
    except Exception:
        return None


def get_window_title(hwnd):
    """用 ctypes 取窗口标题，用于判断前台窗口是否为企微主窗口。"""
    try:
        length = ctypes.windll.user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return ""
        buf = ctypes.create_unicode_buffer(length + 1)
        ctypes.windll.user32.GetWindowTextW(hwnd, buf, length + 1)
        return buf.value
    except Exception:
        return ""


def wait_for(predicate, timeout=30, interval=0.5, desc="condition"):
    """轮询等待条件成立。返回 predicate() 的真值或 None（超时）。
    指数退避 interval（上限 2s）减少冷启动期无效轮询。"""
    start = time.time()
    delay = interval
    while time.time() - start < timeout:
        try:
            result = predicate()
            if result:
                return result
        except Exception as exc:
            log(f"wait_for({desc}) predicate error: {exc}")
        time.sleep(delay)
        delay = min(delay * 1.5, 2.0)
    log(f"wait_for({desc}) TIMEOUT after {timeout}s")
    return None


WXWORK_PATHS = [
    r"C:\Program Files\WXWork\WXWork.exe",
    r"C:\Program Files (x86)\WXWork\WXWork.exe",
    r"D:\Program Files\WXWork\WXWork.exe",
    r"D:\Program Files (x86)\WXWork\WXWork.exe",
]

# OCR 模型懒加载（首次调用约 2-3 秒）。
_ocr_instance = None


def get_ocr():
    global _ocr_instance
    if _ocr_instance is None:
        _ocr_instance = RapidOCR()
    return _ocr_instance


# ---- 调试日志与截图 ----
# 日志和截图保存到 C:\威智工作汇报器测试\scripts\debug\（用户指定的可写路径）。
_DEBUG_DIR = r"C:\威智工作汇报器测试\scripts\debug"
_log_lines = []


def log(msg):
    """记录日志，同时打印到 stdout。"""
    line = f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] {msg}"
    print(line, flush=True)
    _log_lines.append(line)


def save_debug_log():
    """把累计日志写入文件。"""
    os.makedirs(_DEBUG_DIR, exist_ok=True)
    path = os.path.join(_DEBUG_DIR, "run.log")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(_log_lines))
    print(f"LOG_SAVED: {path}", flush=True)


def screenshot(tag, win=None):
    """截图保存到 debug 目录，文件名带时间戳和标签。
    win 传入时只截企微窗口区域，否则全屏。"""
    os.makedirs(_DEBUG_DIR, exist_ok=True)
    ts = datetime.now().strftime("%H%M%S_%f")[:-3]
    path = os.path.join(_DEBUG_DIR, f"{ts}_{tag}.png")
    try:
        if win is not None:
            sct = mss()
            monitor = {
                "top": win.top,
                "left": win.left,
                "width": win.right - win.left,
                "height": win.bottom - win.top,
            }
            shot = sct.grab(monitor)
            img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
            img.save(path)
        else:
            pyautogui.screenshot(path)
        log(f"SCREENSHOT: {tag} -> {path}")
    except Exception as exc:
        log(f"SCREENSHOT_FAILED: {tag} {exc}")
    return path


def find_wework_window():
    """查找企微主窗口。要求标题含"企业微信"、尺寸足够大（宽高>400，排除小闪屏）、
    且窗口句柄仍有效（能读到 rect）。标题用包含而非严格相等，因为企微不同版本
    主窗口标题可能是"企业微信"或带后缀。"""
    for w in gw.getAllWindows():
        if not w.title or "企业微信" not in w.title:
            continue
        try:
            # 访问 rect 属性，句柄失效会抛 1400 异常。
            if w.width > 400 and w.height > 400 and w.left is not None:
                return w
        except Exception:
            continue
    return None


def log_all_wework_windows():
    """诊断：列出所有含'微信'/'企微'/'WXWork'的窗口信息，排查冷启动找不到窗口的原因。"""
    try:
        for w in gw.getAllWindows():
            if not w.title:
                continue
            if "微信" in w.title or "企微" in w.title or "WXWork" in w.title or "wework" in w.title.lower():
                try:
                    log(f"  WIN_DIAG: title={w.title!r} rect=({w.left},{w.top},{w.right},{w.bottom}) w={w.width} h={w.height}")
                except Exception as exc:
                    log(f"  WIN_DIAG: title={w.title!r} <handle invalid: {exc}>")
    except Exception as exc:
        log(f"WIN_DIAG error: {exc}")


def find_wework_hwnd():
    """用 ctypes 按标题查找企微主窗口的 hwnd（窗口句柄）。
    比 pygetwindow 更底层，可直接拿到稳定的 hwnd 用于比较。
    返回 hwnd 或 0。"""
    EnumWindows = ctypes.windll.user32.EnumWindows
    GetWindowTextW = ctypes.windll.user32.GetWindowTextW
    IsWindowVisible = ctypes.windll.user32.IsWindowVisible
    GetWindowTextLengthW = ctypes.windll.user32.GetWindowTextLengthW

    WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_long)
    found_hwnd = 0

    def _enum_cb(hwnd, lparam):
        nonlocal found_hwnd
        if not IsWindowVisible(hwnd):
            return True
        length = GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        buf = ctypes.create_unicode_buffer(length + 1)
        GetWindowTextW(hwnd, buf, length + 1)
        if buf.value == "企业微信":
            found_hwnd = hwnd
            return False  # 找到即停
        return True

    EnumWindows(WNDENUMPROC(_enum_cb), 0)
    return found_hwnd


def wait_window_stable(timeout=60, interval=1.0):
    """轮询等待企微窗口稳定出现。冷启动时窗口会重建，用 hwnd（窗口句柄）
    比较：找到窗口后记录 hwnd，等 1.5s 再查一次，若 hwnd 相同且句柄仍有效
    （GetWindowText 能读到标题）则视为稳定。返回稳定窗口或 None。"""
    start = time.time()
    delay = interval
    last_hwnd = 0
    while time.time() - start < timeout:
        hwnd = find_wework_hwnd()
        if hwnd:
            if hwnd == last_hwnd:
                # 同一 hwnd，验证句柄仍有效。
                if ctypes.windll.user32.IsWindow(hwnd):
                    win = find_wework_window()
                    if win:
                        try:
                            log(f"window stable: hwnd={hwnd} rect=({win.left},{win.top},{win.right},{win.bottom})")
                            return win
                        except Exception as exc:
                            log(f"window stable but rect read failed: {exc}")
            else:
                last_hwnd = hwnd
                log(f"window candidate: hwnd={hwnd}, waiting to confirm stability")
        time.sleep(delay)
        delay = min(delay * 1.5, 2.0)
    log(f"wait_window_stable TIMEOUT after {timeout}s")
    log("diagnosing: listing all wechat/wework windows")
    log_all_wework_windows()
    return None


def find_search_popup():
    """查找已打开的"全局搜索"弹窗窗口。
    用户可能之前手动打开过且输入了内容，此时弹窗作为独立窗口存在。
    返回窗口对象或 None。"""
    for w in gw.getAllWindows():
        if w.title == "全局搜索" and w.width > 100 and w.height > 100:
            return w
    return None


def activate_window(win):
    """激活窗口。返回 True/False 表示是否成为前台窗口。
    窗口句柄可能失效（冷启动期），所有访问加 try 保护。"""
    try:
        win.minimize()
        time.sleep(0.1)
        win.restore()
        time.sleep(0.1)
    except Exception:
        pass
    for _ in range(3):
        try:
            win.activate()
        except Exception:
            pass
        pyautogui.press("alt")
        time.sleep(0.03)
        pyautogui.press("alt")
        time.sleep(0.3)
        # 验证是否成为前台窗口。
        try:
            hwnd = ctypes.windll.user32.GetForegroundWindow()
            if hwnd:
                title = get_window_title(hwnd)
                if title and ("企业微信" in title or "全局搜索" in title):
                    return True
        except Exception:
            pass
    return False


def safe_win_rect(win):
    """安全获取窗口 rect。句柄失效返回 None。"""
    try:
        return (win.left, win.top, win.right, win.bottom)
    except Exception:
        return None


def edit_distance(s1, s2):
    """计算两个字符串的 Levenshtein 编辑距离。
    用于容错 OCR 识别的错别字、漏字（如"赛事"→"赛中"、"赛事平台"→"事平台"）。"""
    if len(s1) < len(s2):
        s1, s2 = s2, s1
    if len(s2) == 0:
        return len(s1)
    prev = list(range(len(s2) + 1))
    for i, c1 in enumerate(s1):
        curr = [i + 1]
        for j, c2 in enumerate(s2):
            curr.append(min(prev[j + 1] + 1, curr[j] + 1, prev[j] + (c1 != c2)))
        prev = curr
    return prev[-1]


def similarity(s1, s2):
    """返回 0-1 相似度，1=完全相同。基于编辑距离归一化。"""
    if not s1 and not s2:
        return 1.0
    m = max(len(s1), len(s2))
    if m == 0:
        return 1.0
    return 1.0 - edit_distance(s1, s2) / m


def ocr_find_group(region, group):
    """在指定屏幕区域 OCR 识别，找到群名对应的搜索结果项坐标。

    region=(left, top, right, bottom)，通常是"全局搜索"浮层窗口区域。
    浮层是独立窗口，可能被拖到任意屏幕，故由调用方传入实际位置，
    不再硬编码企微主窗口。

    加速策略：
    1. 只截浮层左 55% 宽度（搜索结果列表在此区域，右侧是详情预览不需要）。
    2. 截图 resize 到 50% 再喂给 OCR。
    3. cls=False 跳过方向分类（企微文字都是正向的，不需要分类）。
    坐标换算：OCR 返回的是缩小后图片的坐标，需 /scale 还原 + 截图偏移。

    排除搜索框区域（顶部 150px）。优先选字号最大的命中项。"""
    left, top, right, bottom = region
    full_width = right - left
    # 只截浮层左 55% 宽度，搜索结果列表在此区域。
    crop_left = left
    crop_top = top
    crop_right = left + int(full_width * 0.55)
    crop_bottom = bottom
    crop_width = crop_right - crop_left
    log(f"OCR crop rect: ({crop_left},{crop_top},{crop_right},{crop_bottom}) w={crop_width} (55% of {full_width})")

    sct = mss()
    monitor = {
        "top": crop_top,
        "left": crop_left,
        "width": crop_right - crop_left,
        "height": crop_bottom - crop_top,
    }
    shot = sct.grab(monitor)
    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    # resize 到 50% 加速 OCR。
    scale = 0.5
    small = img.resize(
        (int(img.width * scale), int(img.height * scale)), Image.LANCZOS
    )
    log(f"OCR resized: {img.width}x{img.height} -> {small.width}x{small.height}")

    ocr = get_ocr()
    # cls=False 跳过方向分类，企微文字都是正向的，省约 30% OCR 耗时。
    result, _ = ocr(small, cls=False)
    if not result:
        log("OCR returned no results")
        return None
    log(f"OCR found {len(result)} text blocks")

    candidates = []
    for idx, (box, text, score) in enumerate(result):
        if score < 0.5:
            continue
        # box 是缩小后图片的坐标，还原到屏幕绝对坐标。
        xs = [p[0] / scale for p in box]
        ys = [p[1] / scale for p in box]
        height = max(ys) - min(ys)
        width = max(xs) - min(xs)
        cx = sum(xs) / 4 + crop_left
        cy = sum(ys) / 4 + crop_top
        log(f"  [{idx}] text={text!r} score={score:.2f} h={int(height)} w={int(width)} center=({int(cx)},{int(cy)})")
        # 去除 OCR 文本中常见的群成员数后缀（如"（22）"）再匹配，避免后缀干扰相似度。
        import re
        text_clean = re.sub(r'[（(]\d+[)）]', '', text).strip()
        # 匹配策略：子串包含 OR 编辑距离模糊匹配（容错 OCR 错别字/漏字，如"赛事"→"赛中"）。
        matched = False
        match_reason = ""
        if group in text_clean or text_clean in group:
            if min(len(text_clean), len(group)) >= len(group) * 0.6:
                matched = True
                match_reason = "substring"
        if not matched:
            sim = similarity(group, text_clean)
            if sim >= 0.85:
                matched = True
                match_reason = f"fuzzy(sim={sim:.2f})"
        if matched:
            if cy < top + 150:
                log(f"    -> matched({match_reason}) but in search box area, skip")
                continue
            candidates.append((height, cx, cy, text, score))
            log(f"    -> MATCHED candidate (h={int(height)}, {match_reason})")

    if not candidates:
        log("NO_MATCHED_CANDIDATES")
        return None

    candidates.sort(reverse=True)
    for i, (h, cx, cy, txt, sc) in enumerate(candidates):
        log(f"  candidate rank {i}: h={int(h)} center=({int(cx)},{int(cy)}) text={txt!r}")
    best = candidates[0]
    log(f"OCR_PICK: center=({int(best[1])},{int(best[2])}) text={best[3]!r} h={int(best[0])}")
    return (int(best[1]), int(best[2]))


def verify_conversation(win, group):
    """发送前检查：截窗口顶部会话标题区域，OCR 识别，确认当前会话标题
    等于目标群名。防止搜索点错导致发错群。

    严格匹配：OCR 文本必须与群名高度一致（text==group 或去标点后相等），
    不用宽松包含，避免"企微有文件传输助手的"这类误匹配。

    加速策略：
    1. 会话标题在窗口顶部居中，只截中间 40% 宽度 + 顶部 80px 高度。
    2. resize 50% 缩小图片。
    3. cls=False 跳过方向分类。"""
    left, top = win.left, win.top
    win_width = win.right - win.left
    # 会话标题在窗口顶部居中，截中间 40% 宽度 + 顶部 80px。
    crop_left = left + int(win_width * 0.3)
    crop_right = left + int(win_width * 0.7)
    crop_top = top
    crop_bottom = top + 80
    log(f"VERIFY crop: ({crop_left},{crop_top},{crop_right},{crop_bottom}) w={crop_right-crop_left}")

    sct = mss()
    monitor = {
        "top": crop_top,
        "left": crop_left,
        "width": crop_right - crop_left,
        "height": crop_bottom - crop_top,
    }
    shot = sct.grab(monitor)
    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    # resize 50% 加速。
    scale = 0.5
    small = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
    ocr = get_ocr()
    # cls=False 跳过方向分类。
    result, _ = ocr(small, cls=False)
    if not result:
        log("VERIFY: OCR no results")
        return False

    # 去标点空格的规范化函数，便于严格比较。
    import re
    def norm(s):
        return re.sub(r"[\s\W_]+", "", s)

    group_norm = norm(group)
    found = False
    for box, text, score in result:
        log(f"  VERIFY text={text!r} score={score:.2f}")
        if score < 0.5:
            continue
        t_norm = norm(text)
        # 严格匹配：规范化后相等，或一方完全包含另一方且长度接近。
        if t_norm == group_norm:
            found = True
            log(f"  VERIFY MATCHED (exact): {text!r} == {group!r}")
        elif group_norm in t_norm and len(t_norm) <= len(group_norm) + 4:
            # 允许 OCR 多识别少量字符（如群成员数），但差距不能太大。
            found = True
            log(f"  VERIFY MATCHED (near): {text!r} contains {group!r}")
        else:
            # 模糊匹配兜底：容错 OCR 漏字/错别字（如"赛事平台"→"事平台"）。
            sim = similarity(group_norm, t_norm)
            if sim >= 0.85:
                found = True
                log(f"  VERIFY MATCHED (fuzzy): {text!r} sim={sim:.2f} vs {group!r}")

    if not found:
        log(f"VERIFY FAILED: target {group!r} not in conversation title")
    return found


def find_search_box(win):
    """用 DPI 定位企微搜索入口位置（自适应分辨率，无需 OCR）。

    企微左侧导航栏顶部第一个入口即"全局搜索"，位置固定：
    - x: 100% DPI 下约 135 逻辑像素，× DPI 得物理像素。
         实测 DPI 1.5→202、DPI 1.25→168，均命中。
    - y: 100% DPI 下约 73 逻辑像素，× DPI 得物理像素。
         实测 DPI 1.5 窗口顶+109、DPI 1.25 窗口顶+91，73×1.5=110、73×1.25=91 均命中。
         之前用窗口高度比例 0.075 在不同高度下偏差大，改用固定 DPI 缩放更稳。"""
    dpi = get_window_dpi_scale(win)
    win_width = win.right - win.left
    win_height = win.bottom - win.top
    # x: 100% DPI 下约 135 逻辑像素，× DPI 得物理像素。
    cx = win.left + int(135 * dpi)
    # y: 100% DPI 下约 73 逻辑像素，× DPI 得物理像素。
    cy = win.top + int(73 * dpi)
    log(f"SEARCH_BOX_POS: ({cx},{cy}) [x=win.left+{int(135*dpi)}(135*{dpi}), y=win.top+{int(73*dpi)}(73*{dpi}), win={win_width}x{win_height}]")
    return (cx, cy)


def find_search_box_ocr(win):
    """OCR 兜底定位搜索入口（比例定位失败时用）。
    只截窗口左 20% 宽度 + 顶部 15% 高度的小区域，resize 50% + cls=False，
    比全屏 OCR 快很多。返回中心坐标或 None。"""
    dpi = get_window_dpi_scale(win)
    left, top = win.left, win.top
    win_width = win.right - win.left
    win_height = win.bottom - win.top
    crop_left = left
    crop_top = top
    crop_right = left + int(win_width * 0.20)
    crop_bottom = top + int(win_height * 0.15)
    log(f"SEARCH_BOX_OCR crop: ({crop_left},{crop_top},{crop_right},{crop_bottom})")

    sct = mss()
    monitor = {
        "top": crop_top, "left": crop_left,
        "width": crop_right - crop_left, "height": crop_bottom - crop_top,
    }
    shot = sct.grab(monitor)
    img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
    scale = 0.5
    small = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
    ocr = get_ocr()
    result, _ = ocr(small, cls=False)
    if not result:
        log("SEARCH_BOX_OCR: no results")
        return None

    keywords = ["查找所有聊天", "查找", "搜索"]
    best_hit = None
    for box, text, score in result:
        log(f"  SEARCH_BOX_OCR text={text!r} score={score:.2f}")
        if score < 0.5:
            continue
        for kw in keywords:
            if kw in text:
                xs = [p[0] / scale for p in box]
                ys = [p[1] / scale for p in box]
                cx = sum(xs) / 4 + crop_left
                cy = sum(ys) / 4 + crop_top
                rank = len(text)
                log(f"SEARCH_BOX_OCR HIT: {text!r} -> ({int(cx)},{int(cy)})")
                if best_hit is None or rank > best_hit[0]:
                    best_hit = (rank, int(cx), int(cy), text)
    if best_hit:
        log(f"SEARCH_BOX_OCR PICK: {best_hit[3]!r} -> ({best_hit[1]},{best_hit[2]})")
        return (best_hit[1], best_hit[2])
    log("SEARCH_BOX_OCR: not found")
    return None


def main():
    group = os.environ.get("WECHAT_GROUP", "文件传输助手").strip()
    message = os.environ.get("WECHAT_MESSAGE", "")
    if not message:
        log("EMPTY_MESSAGE")
        save_debug_log()
        sys.exit(2)

    log(f"START group={group!r} msg_len={len(message)} dpi_scale={get_dpi_scale()}")

    # 1. 找/启动企微窗口。
    win = find_wework_window()
    if win is None:
        log("window not found, trying to launch WXWork.exe")
        launched = False
        for path in WXWORK_PATHS:
            if os.path.exists(path):
                subprocess.Popen([path])
                log(f"launched: {path}")
                launched = True
                break
        if not launched:
            log("NO_WXWORK_EXE")
            save_debug_log()
            sys.exit(2)
        # 轮询等待窗口稳定出现（冷启动时窗口会重建，需连续两次查到同一有效窗口）。
        win = wait_window_stable(timeout=60, interval=1.0)
        if win is None:
            log("NO_STABLE_WINDOW after waiting 60s")
            save_debug_log()
            sys.exit(2)

    log(f"window found: title={win.title!r} rect=({win.left},{win.top},{win.right},{win.bottom})")
    # 激活窗口，失败重试。激活可能触发窗口重建，失效则重新查找。
    if not activate_window(win):
        log("activate failed, re-finding window")
        time.sleep(1.0)
        win = find_wework_window()
        if win:
            activate_window(win)
        else:
            log("RE_FIND_AFTER_ACTIVATE_FAILED")
            save_debug_log()
            sys.exit(2)
    log("window activated")
    # 激活后再次验证窗口有效，失效则重新查找。
    if safe_win_rect(win) is None:
        log("window handle invalid after activate, re-finding")
        win = wait_for(find_wework_window, timeout=10, interval=1.0, desc="refind_after_activate")
        if win is None:
            log("RE_FIND_FAILED after activate")
            save_debug_log()
            sys.exit(2)
    screenshot("01_after_activate", win)

    # 2. 确保全局搜索弹窗已打开并聚焦输入框。
    # 策略：多轮重试，每轮后用 wait_for 轮询弹窗是否出现。
    #   轮1: DPI 比例定位点击搜索入口
    #   轮2: OCR 兜底定位点击
    #   轮3: 快捷键 Ctrl+Alt+F（企微全局搜索快捷键）
    popup = find_search_popup()
    if popup:
        log(f"search popup already open: rect=({popup.left},{popup.top},{popup.right},{popup.bottom})")
        activate_window(popup)
        input_x = popup.left + (popup.right - popup.left) // 4
        input_y = popup.top + 60
        log(f"clicking popup input area at ({input_x},{input_y})")
        pyautogui.click(input_x, input_y)
        time.sleep(0.3)
    else:
        popup_opened = False
        # 轮1: DPI 比例定位。
        log("round 1: DPI ratio positioning")
        sb_pos = find_search_box(win)
        log(f"clicking search box at ({sb_pos[0]},{sb_pos[1]})")
        pyautogui.click(sb_pos[0], sb_pos[1])
        if wait_for(find_search_popup, timeout=3, interval=0.3, desc="popup_after_ratio_click"):
            log("popup appeared after ratio click")
            popup_opened = True

        # 轮2: OCR 兜底。
        if not popup_opened:
            log("round 2: OCR fallback")
            screenshot("02a_round1_missed")
            sb_pos2 = find_search_box_ocr(win)
            if sb_pos2:
                log(f"OCR fallback clicking search box at ({sb_pos2[0]},{sb_pos2[1]})")
                pyautogui.click(sb_pos2[0], sb_pos2[1])
                if wait_for(find_search_popup, timeout=3, interval=0.3, desc="popup_after_ocr_click"):
                    log("popup appeared after OCR click")
                    popup_opened = True

        # 轮3: 快捷键 Ctrl+Alt+F。
        if not popup_opened:
            log("round 3: Ctrl+Alt+F shortcut")
            # 先确保企微主窗口是前台。
            activate_window(win)
            time.sleep(0.2)
            pyautogui.hotkey("ctrl", "alt", "f")
            if wait_for(find_search_popup, timeout=3, interval=0.3, desc="popup_after_shortcut"):
                log("popup appeared after Ctrl+Alt+F")
                popup_opened = True

        if not popup_opened:
            log("ALL_ROUNDS_FAILED: cannot open search popup, abort")
            save_debug_log()
            sys.exit(4)
    screenshot("02_after_click_search_box")

    # 3. 清空搜索输入框 → 粘贴群名 → 等搜索结果。
    # Ctrl+A 全选输入框内容（即使弹窗已打开且有旧内容也能清空）。
    log("pressing Ctrl+A to clear search box")
    pyautogui.hotkey("ctrl", "a")
    time.sleep(0.05)
    pyperclip.copy(group)
    log(f"clipboard set to group: {group!r}")
    time.sleep(0.1)
    log("pressing Ctrl+V to paste group name")
    pyautogui.hotkey("ctrl", "v")
    # 等搜索结果列表加载（企微搜索通常 1 秒内出结果）。
    log("waiting 1.5s for search results")
    time.sleep(1.5)
    screenshot("03_after_search")

    # 4. 确定搜索结果所在区域。
    # 全局搜索浮层是独立窗口，可能被用户拖到任意屏幕（含副屏）。
    # 粘贴群名后焦点在浮层输入框，故浮层=前台窗口，取其 rect 作为 OCR 区域，
    # 这样不管浮层在主屏还是副屏都能截到搜索结果。
    log("locating search popup via foreground window")
    fg_hwnd = ctypes.windll.user32.GetForegroundWindow()
    fg_rect = get_foreground_window_rect()
    fg_title = get_window_title(fg_hwnd) if fg_hwnd else ""
    log(f"foreground hwnd={fg_hwnd} title={fg_title!r} rect={fg_rect}")
    # 也尝试用 pygetwindow 找弹窗（更可靠，不依赖前台状态）。
    popup2 = find_search_popup()
    if popup2:
        search_region = (popup2.left, popup2.top, popup2.right, popup2.bottom)
        log(f"SEARCH_REGION: popup window {search_region}")
    elif fg_rect and fg_rect != (win.left, win.top, win.right, win.bottom):
        search_region = fg_rect
        log(f"SEARCH_REGION: foreground popup {search_region}")
    else:
        search_region = (win.left, win.top, win.right, win.bottom)
        log(f"SEARCH_REGION: fallback wework window {search_region}")

    # OCR 找群名，失败重试一次（搜索结果可能加载稍慢）。
    log("starting OCR (attempt 1)")
    pos = ocr_find_group(search_region, group)
    if pos is None:
        log("GROUP_NOT_FOUND attempt 1, retry after 1s")
        time.sleep(1.0)
        log("starting OCR (attempt 2)")
        pos = ocr_find_group(search_region, group)
    if pos is None:
        log("GROUP_NOT_FOUND, fallback: Down + Enter")
        screenshot("04_group_not_found")
        pyautogui.press("down")
        time.sleep(0.3)
        pyautogui.press("enter")
        time.sleep(1.0)
    else:
        log(f"clicking search result at ({pos[0]},{pos[1]})")
        pyautogui.click(pos[0], pos[1])
        log("click issued")
        time.sleep(1.0)
        screenshot("05_after_click_group", win)

    # 5. 发送前检查：OCR 确认当前会话标题 = 目标群名，防止发错群。
    # 验证失败时重试最多 3 次（会话切换可能稍慢）。
    log("pre-send check: verifying conversation title")
    verified = False
    for verify_attempt in range(3):
        screenshot(f"05b_verify_attempt{verify_attempt+1}", win)
        if verify_conversation(win, group):
            log(f"VERIFY_OK on attempt {verify_attempt+1}")
            verified = True
            break
        log(f"VERIFY_FAILED attempt {verify_attempt+1}, retry after 1s")
        time.sleep(1.0)
    if not verified:
        log("VERIFY_FAILED: conversation title does not match target group after 3 attempts, ABORT SEND")
        save_debug_log()
        sys.exit(5)

    # 6. 粘贴汇报并发送。此时焦点应在消息输入框。
    log("copying message to clipboard")
    pyperclip.copy(message)
    time.sleep(0.1)
    log("pressing Ctrl+V to paste message")
    pyautogui.hotkey("ctrl", "v")
    time.sleep(0.4)
    screenshot("06_after_paste_message", win)
    log("pressing Enter to send")
    pyautogui.press("enter")
    time.sleep(0.3)
    screenshot("07_after_send", win)
    log("SENT")
    save_debug_log()
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        import traceback
        log(f"EXCEPTION: {exc}")
        log(traceback.format_exc())
        save_debug_log()
        sys.exit(1)
