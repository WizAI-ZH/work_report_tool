import tkinter as tk
from tkinter import messagebox, simpledialog, ttk
import os, json, re
from datetime import datetime, timedelta
from version import get_version_info
from task_tracker import generate_today_work, parse_task_input, add_task
from wechat_integration import send_to_wechat
import requests

ROOT_DIR = "工作汇报记录"
CFG_FILE = os.path.join(ROOT_DIR, "report_config.json")
HISTORY_DIR = os.path.join(ROOT_DIR, "report_history")
TEMPLATE_FILE = os.path.join(ROOT_DIR, "report_template.json")
AI_CONFIG_FILE = os.path.join(ROOT_DIR, "ai_config.json")
SUGGESTIONS = [
    "建议使用简洁的短句，条理清晰；",
    "适当量化工作成效，例如'完成XX模块开发50%'；",
    "明日计划建议明确到具体任务或目标；",
    "如有困难，建议在计划部分注明需协助资源；",
]

# 默认AI配置
DEFAULT_AI_CONFIG = {
    "api_key": "",
    "api_url": "https://api.chatanywhere.tech/v1/chat/completions",
    "model": "deepseek-v3.2",
    "available_models": [
        "deepseek-v3.2",
        "deepseek-chat",
        "gpt-3.5-turbo",
        "gpt-4o",
        "gpt-4o-mini"
    ]
}

def load_ai_config():
    """加载AI配置"""
    if os.path.exists(AI_CONFIG_FILE):
        try:
            with open(AI_CONFIG_FILE, 'r', encoding='utf-8') as f:
                config = json.load(f)
                # 确保所有必要字段都存在
                for key in DEFAULT_AI_CONFIG:
                    if key not in config:
                        config[key] = DEFAULT_AI_CONFIG[key]
                return config
        except Exception:
            pass
    return DEFAULT_AI_CONFIG.copy()

def save_ai_config(config):
    """保存AI配置"""
    try:
        with open(AI_CONFIG_FILE, 'w', encoding='utf-8') as f:
            json.dump(config, f, ensure_ascii=False, indent=2)
        return True
    except Exception:
        return False

def show_ai_config_dialog(first_time=False):
    """显示AI配置对话框
    
    Args:
        first_time: 是否为首次使用
    """
    config = load_ai_config()
    
    win = tk.Toplevel(root)
    win.title("AI接口配置" if not first_time else "欢迎使用 - 请配置AI接口")
    win.geometry("550x450")
    win.transient(root)
    win.grab_set()
    
    # 说明文字
    if first_time:
        tk.Label(win, text="首次使用需要配置AI接口", font=("微软雅黑", 14, "bold"), fg="blue").pack(pady=10)
    
    tk.Label(win, text="配置您的AI API信息：", font=("微软雅黑", 11)).pack(pady=5)
    
    # 免费API获取提示
    info_frame = tk.LabelFrame(win, text="免费API Key获取", font=("微软雅黑", 10))
    info_frame.pack(fill="x", padx=20, pady=10)
    
    info_text = """您可以免费获取API Key：
https://github.com/chatanywhere/GPT_API_free

推荐代理URL：https://api.chatanywhere.tech/v1/chat/completions"""
    
    info_label = tk.Label(info_frame, text=info_text, font=("Consolas", 9), justify=tk.LEFT, fg="blue")
    info_label.pack(padx=10, pady=10)
    
    # 配置表单
    form_frame = tk.Frame(win)
    form_frame.pack(fill="x", padx=20, pady=10)
    
    # API Key
    tk.Label(form_frame, text="API Key:", font=("微软雅黑", 10)).grid(row=0, column=0, sticky="w", pady=5)
    api_key_var = tk.StringVar(value=config.get("api_key", ""))
    api_key_entry = tk.Entry(form_frame, textvariable=api_key_var, font=("Consolas", 10), width=50, show="*")
    api_key_entry.grid(row=0, column=1, pady=5)
    
    # 显示/隐藏API Key
    def toggle_show_key():
        if api_key_entry.cget("show") == "*":
            api_key_entry.config(show="")
            show_btn.config(text="隐藏")
        else:
            api_key_entry.config(show="*")
            show_btn.config(text="显示")
    
    show_btn = tk.Button(form_frame, text="显示", command=toggle_show_key)
    show_btn.grid(row=0, column=2, padx=5)
    
    # API URL
    tk.Label(form_frame, text="API URL:", font=("微软雅黑", 10)).grid(row=1, column=0, sticky="w", pady=5)
    api_url_var = tk.StringVar(value=config.get("api_url", DEFAULT_AI_CONFIG["api_url"]))
    tk.Entry(form_frame, textvariable=api_url_var, font=("Consolas", 10), width=50).grid(row=1, column=1, pady=5)
    
    # 模型选择 - 使用Combobox支持自定义输入
    tk.Label(form_frame, text="模型:", font=("微软雅黑", 10)).grid(row=2, column=0, sticky="w", pady=5)
    model_var = tk.StringVar(value=config.get("model", DEFAULT_AI_CONFIG["model"]))
    # 获取保存的模型列表或使用默认值
    saved_models = config.get("available_models", DEFAULT_AI_CONFIG["available_models"])
    model_combo = ttk.Combobox(form_frame, textvariable=model_var, 
                               values=saved_models, 
                               font=("微软雅黑", 10), width=48)
    model_combo.grid(row=2, column=1, pady=5)
    # 提示用户可以输入自定义模型
    tk.Label(form_frame, text="(可手动输入或从API获取)", font=("微软雅黑", 8), fg="gray").grid(row=3, column=1, sticky="w")
    
    # 获取模型列表按钮
    def fetch_models():
        """从API获取可用模型列表"""
        api_key = api_key_var.get().strip()
        api_url = api_url_var.get().strip()
        
        if not api_key:
            messagebox.showwarning("警告", "请先输入API Key！")
            return
        
        # 显示获取窗口
        fetch_win = tk.Toplevel(win)
        fetch_win.title("获取模型列表")
        fetch_win.geometry("300x100")
        fetch_win.transient(win)
        fetch_win.grab_set()
        tk.Label(fetch_win, text="正在获取可用模型列表...", font=("微软雅黑", 11)).pack(pady=20)
        fetch_win.update()
        
        try:
            headers = {
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json"
            }
            
            # 尝试从API获取模型列表
            # OpenAI兼容的API通常使用 /v1/models 端点
            base_url = api_url.rsplit('/', 2)[0]  # 移除 /v1/chat/completions
            models_url = f"{base_url}/v1/models"
            
            response = requests.get(
                models_url,
                headers=headers,
                timeout=10
            )
            
            fetch_win.destroy()
            
            if response.status_code == 200:
                data = response.json()
                models = [m.get("id", "") for m in data.get("data", [])]
                # 过滤掉嵌入模型等不适合的模型
                chat_models = [m for m in models if any(keyword in m.lower() for keyword in 
                              ['gpt', 'claude', 'deepseek', 'qwen', 'glm', 'chat', 'llama', 'mistral'])]
                
                if chat_models:
                    model_combo['values'] = chat_models
                    messagebox.showinfo("成功", f"已获取 {len(chat_models)} 个可用模型！")
                else:
                    messagebox.showwarning("提示", "未找到合适的聊天模型，使用默认列表。")
            else:
                error_msg = response.json().get("error", {}).get("message", "未知错误")
                messagebox.showerror("失败", f"获取模型列表失败：\n{error_msg}\n\n您可以手动输入模型名称。")
        except Exception as e:
            fetch_win.destroy()
            messagebox.showerror("失败", f"获取模型列表失败：\n{str(e)}\n\n您可以手动输入模型名称。")
    
    tk.Button(form_frame, text="获取模型", command=fetch_models, font=("微软雅黑", 9), padx=5).grid(row=2, column=2, padx=5)
    
    # 按钮
    btn_frame = tk.Frame(win)
    btn_frame.pack(pady=20)
    
    def save_config():
        # 保存当前模型列表（可能是从API获取的）
        current_models = list(model_combo['values'])
        if not current_models:  # 如果为空，使用默认值
            current_models = DEFAULT_AI_CONFIG["available_models"]
        
        new_config = {
            "api_key": api_key_var.get().strip(),
            "api_url": api_url_var.get().strip(),
            "model": model_var.get(),
            "available_models": current_models
        }
        
        if not new_config["api_key"]:
            messagebox.showwarning("警告", "API Key不能为空！")
            return
        
        if save_ai_config(new_config):
            messagebox.showinfo("成功", "配置已保存！")
            win.destroy()
        else:
            messagebox.showerror("错误", "保存配置失败！")
    
    def cancel():
        if first_time:
            messagebox.showwarning("提示", "您需要配置API Key才能使用AI建议功能。")
        win.destroy()
    
    tk.Button(btn_frame, text="保存配置", command=save_config, bg="#4CAF50", fg="white", font=("微软雅黑", 10), padx=20).pack(side=tk.LEFT, padx=10)
    tk.Button(btn_frame, text="取消", command=cancel, font=("微软雅黑", 10), padx=20).pack(side=tk.LEFT, padx=10)
    
    # 测试连接按钮
    def test_connection():
        test_config = {
            "api_key": api_key_var.get().strip(),
            "api_url": api_url_var.get().strip(),
            "model": model_var.get()
        }
        
        if not test_config["api_key"]:
            messagebox.showwarning("警告", "请先输入API Key！")
            return
        
        # 显示测试窗口
        test_win = tk.Toplevel(win)
        test_win.title("测试连接")
        test_win.geometry("300x100")
        test_win.transient(win)
        test_win.grab_set()
        tk.Label(test_win, text="正在测试连接...", font=("微软雅黑", 11)).pack(pady=20)
        test_win.update()
        
        try:
            headers = {
                "Authorization": f"Bearer {test_config['api_key']}",
                "Content-Type": "application/json"
            }
            data = {
                "model": test_config["model"],
                "messages": [{"role": "user", "content": "Hello"}],
                "max_tokens": 10
            }
            
            response = requests.post(
                test_config["api_url"],
                headers=headers,
                json=data,
                timeout=10
            )
            
            test_win.destroy()
            
            if response.status_code == 200:
                messagebox.showinfo("成功", "连接测试成功！API配置正确。")
            else:
                error_msg = response.json().get("error", {}).get("message", "未知错误")
                messagebox.showerror("失败", f"连接测试失败：\n{error_msg}")
        except Exception as e:
            test_win.destroy()
            messagebox.showerror("失败", f"连接测试失败：\n{str(e)}")
    
    tk.Button(btn_frame, text="测试连接", command=test_connection, font=("微软雅黑", 10), padx=20).pack(side=tk.LEFT, padx=10)
    
    if first_time:
        win.protocol("WM_DELETE_WINDOW", cancel)

if not os.path.exists(ROOT_DIR):
    os.makedirs(ROOT_DIR)
if not os.path.exists(HISTORY_DIR):
    os.makedirs(HISTORY_DIR)

def logical_today():
    now = datetime.now()
    if now.hour < 4:
        base = now - timedelta(days=1)
    else:
        base = now
    return base.strftime("%Y-%m-%d")

def excel_letters(n):
    res = ""
    while True:
        n, r = divmod(n, 26)
        res = chr(97 + r) + res
        if n == 0:
            break
        n -= 1
    return res + "."

def proper_bullet(line, idx):
    line = line.strip()
    patterns = [
        r"^[a-zA-Z]{1,2}\.\s?.*",
        r"^\d+\.\s?.*",
        r"^①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩",
    ]
    for pat in patterns:
        if re.match(pat, line):
            return line
    if idx < 10:
        return f"{excel_letters(idx)} {line}"
    elif idx < 36:
        return f"{idx+1}. {line}"
    else:
        circled = ["①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩"]
        return f"{circled[(idx%10)]} {line}"

def format_with_bullets(text):
    lines = text.strip().split("\n")
    return "\n".join([proper_bullet(line, i) for i, line in enumerate(lines) if line.strip()])

def save_user_tomorrow(userkey, tomorrow_plan):
    allcfg = {}
    if os.path.exists(CFG_FILE):
        with open(CFG_FILE, "r", encoding="utf-8") as f:
            try:
                allcfg = json.load(f)
            except:
                allcfg = {}
    if "tomorrow" not in allcfg:
        allcfg["tomorrow"] = {}
    allcfg["tomorrow"][userkey] = tomorrow_plan
    with open(CFG_FILE, "w", encoding="utf-8") as f:
        json.dump(allcfg, f, ensure_ascii=False, indent=2)

def load_last_tomorrow(userkey):
    if os.path.exists(CFG_FILE):
        with open(CFG_FILE, "r", encoding="utf-8") as f:
            try:
                cfg = json.load(f)
            except:
                return ""
            return cfg.get("tomorrow", {}).get(userkey, "")
    return ""

def load_template():
    if os.path.exists(TEMPLATE_FILE):
        with open(TEMPLATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return [
        {"title": "1、今日工作完成情况", "key": "today_work"},
        {"title": "2、明日工作计划", "key": "tomorrow_plan"}
    ]

def save_template(template_data):
    with open(TEMPLATE_FILE, "w", encoding="utf-8") as f:
        json.dump(template_data, f, ensure_ascii=False)

def get_report_token(user, dept, date):
    return f"{user}_{dept}_{date}"

def save_report_history(token, report_data):
    path = os.path.join(HISTORY_DIR, f"{token}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(report_data, f, ensure_ascii=False, indent=2)

def load_history_list():
    return sorted([
        f.replace(".json","") for f in os.listdir(HISTORY_DIR)
        if f.endswith(".json")
    ], reverse=True)

def load_history_detail(token):
    path = os.path.join(HISTORY_DIR, f"{token}.json")
    if not os.path.exists(path): return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def analyze_report_stat():
    history = [load_history_detail(t) for t in load_history_list()]
    total = len(history)
    items_total = 0
    user_counter = {}
    for r in history:
        if r is None: continue
        user = r.get("user","")
        user_counter[user] = user_counter.get(user,0) + 1
        for k in ["today_work","tomorrow_plan","problems"]:
            items = r.get(k,"").split("\n")
            items_total += len([i for i in items if i.strip()])
    lines = [
        f"历史总汇报份数：{total} ; 事项总条数：{items_total}",
        "各用户提交量：",
    ] + [f"\t{u}: {c}" for u,c in user_counter.items()]
    return "\n".join(lines)

def make_suggestion(content):
    advice = []
    lines = content.strip().split("\n")
    if any("完成" in l and "%" not in l for l in lines):
        advice.append("建议补充具体百分比。")
    if all(not l for l in lines):
        advice.append("内容过少，建议细化每一项。")
    advice += SUGGESTIONS[:2] if len(content)<100 else SUGGESTIONS[2:]
    return "\n".join(advice)

# ========= 新的保存/恢复逻辑 =========
def get_cfg_today_key():
    return f"{user_var.get()}__{dept_var.get()}__{logical_today()}"

def save_all_inputs():
    # 姓名、部门全局；内容按业务日区分存储
    if not user_var.get() or not dept_var.get():
        return
    allcache = {}
    if os.path.exists(CFG_FILE):
        try:
            with open(CFG_FILE, 'r', encoding='utf-8') as f:
                allcache = json.load(f)
        except: pass
    today_key = get_cfg_today_key()
    allcache[today_key] = {
        "user": user_var.get(),
        "dept": dept_var.get(),
        "date": logical_today(),
        "fields": {k: input_widgets[k].get("1.0", tk.END) for k in input_widgets}
    }
    # 姓名、部门、日期全局存储一份，跨业务日也能带出
    allcache["_last_user"] = user_var.get()
    allcache["_last_dept"] = dept_var.get()
    allcache["_last_date"] = date_var.get()
    # tommorrow历史兼容
    if "tomorrow" not in allcache:
        oldtomorrow = {}
        if os.path.exists(CFG_FILE):
            try:
                with open(CFG_FILE, 'r', encoding='utf-8') as fr:
                    oldall = json.load(fr)
                    if "tomorrow" in oldall:
                        oldtomorrow = oldall["tomorrow"]
            except: pass
        allcache["tomorrow"] = oldtomorrow
    with open(CFG_FILE, 'w', encoding='utf-8') as f:
        json.dump(allcache, f, ensure_ascii=False, indent=2)

def load_all_inputs():
    if not os.path.exists(CFG_FILE): return
    with open(CFG_FILE, 'r', encoding='utf-8') as f:
        try:
            allcache = json.load(f)
        except:
            return
    last_user = allcache.get("_last_user", "")
    last_dept = allcache.get("_last_dept", "")
    last_date = allcache.get("_last_date", logical_today())
    if not user_var.get() and last_user:
        user_var.set(last_user)
    if not dept_var.get() and last_dept:
        dept_var.set(last_dept)
    if not date_var.get() and last_date:
        date_var.set(last_date)
    today_key = get_cfg_today_key()
    thisdata = allcache.get(today_key)
    if thisdata:
        user_var.set(thisdata.get("user", last_user))
        dept_var.set(thisdata.get("dept", last_dept))
        date_var.set(thisdata.get("date", logical_today()))
        for k, v in thisdata.get("fields", {}).items():
            if k in input_widgets:
                input_widgets[k].delete("1.0", tk.END)
                input_widgets[k].insert("1.0", v)
    else:
        # 新业务日：自动预填昨天的“明日工作计划”到“今日完成情况”等
        date_var.set(logical_today())
        for k in input_widgets:
            input_widgets[k].delete("1.0", tk.END)

        # ⬇⬇⬇这部分实现“跨业务日自动预填”⬇⬇⬇
        # 1. 尝试从任务跟踪系统生成今日工作内容
        today_work_content = generate_today_work()
        if today_work_content and "today_work" in input_widgets:
            input_widgets["today_work"].insert("1.0", today_work_content)
        else:
            # 2. 如果任务跟踪系统没有数据，使用旧的方式
            yesterday = (datetime.now() - timedelta(days=1) if datetime.now().hour >= 4 else datetime.now() - timedelta(days=2)).strftime('%Y-%m-%d')
            prev_key = f"{user_var.get()}__{dept_var.get()}__{yesterday}"
            prev = allcache.get(prev_key)
            if prev:
                # 把昨天的“明日计划”放到今天“今日完成情况”
                y_tomorrow = prev["fields"].get("tomorrow_plan", "")
                if y_tomorrow and "today_work" in input_widgets:
                    input_widgets["today_work"].insert("1.0", y_tomorrow)
        
        # 3. 自动填充未完成任务到明日工作计划
        from task_tracker import get_pending_tasks
        pending_tasks = get_pending_tasks()
        if pending_tasks and "tomorrow_plan" in input_widgets:
            tomorrow_plan_content = []
            for task in pending_tasks:
                # 提取任务的计划内容，如果没有则使用任务名称
                planned_content = task.get('planned', '') or task.get('name', '')
                tomorrow_plan_content.append(f"{task['name']}（0%，无，{planned_content}）")
            if tomorrow_plan_content:
                input_widgets["tomorrow_plan"].insert("1.0", "\n".join(tomorrow_plan_content))

# ================== GUI设计 ==================
root = tk.Tk()
version_info = get_version_info()
root.title(f"工作汇报全功能生成器 - {version_info['version']}")
root.geometry("950x800")
style = ttk.Style()
style.theme_use("clam")
root.config(bg="#f5f7fa")

headerframe = tk.Frame(root, bg="#f5f7fa")
headerframe.pack(fill='x', padx=16, pady=12)
tk.Label(headerframe, text="姓名：", font=("微软雅黑",12), bg="#f5f7fa").pack(side="left")
user_var = tk.StringVar()
user_entry = ttk.Entry(headerframe, textvariable=user_var, width=10)
user_entry.pack(side="left", padx=4)
tk.Label(headerframe, text="部门：", font=("微软雅黑",12), bg="#f5f7fa").pack(side="left", padx=(18,0))
dept_var = tk.StringVar()
dept_entry = ttk.Entry(headerframe, textvariable=dept_var, width=10)
dept_entry.pack(side="left", padx=4)
tk.Label(headerframe, text="日期：", font=("微软雅黑",12), bg="#f5f7fa").pack(side="left", padx=(18,0))
date_var = tk.StringVar(value=logical_today())
date_entry = ttk.Entry(headerframe, textvariable=date_var, width=12)
date_entry.pack(side="left", padx=4)
def select_date():
    sel = simpledialog.askstring("自定义日期", "格式：2024-05-19", parent=root)
    if sel: date_var.set(sel)
date_btn = ttk.Button(headerframe, text="选择日期", command=select_date)
date_btn.pack(side="left", padx=(8,0))

inputframe = tk.LabelFrame(root, text="工作内容填写区", bg="#f5f7fa", font=("微软雅黑", 13, "bold"))
inputframe.pack(fill='x', padx=14, pady=6)
template = load_template()
input_widgets = {}
for item in template:
    tk.Label(inputframe, text=item["title"], font=("微软雅黑",11,"bold"), bg="#f5f7fa").pack(anchor="w", padx=8, pady=(5,0))
    textw = tk.Text(inputframe, width=100, height=5, font=("Consolas",11), relief="solid", borderwidth=1, bg="#FFFFFF")
    textw.pack(padx=10, pady=4)
    input_widgets[item["key"]] = textw

# 持久化触发
def bind_autosave(widget):
    widget.bind("<KeyRelease>", lambda e: save_all_inputs())
    widget.bind("<FocusOut>", lambda e: save_all_inputs())
    # 添加快捷键支持
    widget.bind("<Control-Enter>", lambda e: generate_report(True))  # Ctrl+Enter 生成汇报
    widget.bind("<Control-s>", lambda e: save_all_inputs())  # Ctrl+S 保存
    widget.bind("<Control-c>", lambda e: copy_now())  # Ctrl+C 复制内容
    widget.bind("<Control-n>", lambda e: clear_inputs())  # Ctrl+N 清空内容
    widget.bind("<Control-o>", lambda e: show_history_list())  # Ctrl+O 打开历史
    widget.bind("<Control-d>", lambda e: clear_inputs())  # Ctrl+D 清空内容
    widget.bind("<Control-p>", lambda e: generate_report(False))  # Ctrl+P 预览汇报

# 任务解析功能
def parse_and_add_task(event):
    widget = event.widget
    content = widget.get("1.0", tk.END).strip()
    # 检查是否是任务格式
    task_data = parse_task_input(content)
    if task_data:
        # 添加任务到任务跟踪系统
        add_task(
            task_data["name"],
            task_data["progress"],
            task_data["completed"],
            task_data["planned"]
        )
        messagebox.showinfo("任务添加成功", f"已添加任务：{task_data['name']}")

# Tab键任务输入功能
def task_tab_input(event):
    widget = event.widget
    cursor_pos = widget.index(tk.INSERT)
    line_start = widget.index(f"{cursor_pos} linestart")
    line_end = widget.index(f"{cursor_pos} lineend")
    current_line = widget.get(line_start, line_end)
    
    # 检查当前输入状态
    if not current_line.strip():
        # 新任务开始，插入模板
        widget.insert(tk.INSERT, "任务名称（进度，完成内容，准备做的内容）")
        # 将光标定位到任务名称位置
        widget.icursor(line_start + 4)  # 定位到"任务名称"后面
    else:
        # 分析当前行的状态
        if "（" not in current_line:
            # 任务名称输入完成，添加左括号
            widget.insert(tk.INSERT, "（")
        elif "）" not in current_line:
            # 正在输入任务详情
            parts = current_line.split("，")
            if len(parts) == 1:
                # 进度输入完成，添加逗号
                widget.insert(tk.INSERT, "，")
            elif len(parts) == 2:
                # 完成内容输入完成，添加逗号
                widget.insert(tk.INSERT, "，")
            elif len(parts) == 3:
                # 准备做的内容输入完成，添加右括号
                widget.insert(tk.INSERT, "）")
    
    # 阻止默认Tab行为
    return "break"

user_var.trace_add("write", lambda *a: save_all_inputs())
dept_var.trace_add("write", lambda *a: save_all_inputs())
date_var.trace_add("write", lambda *a: save_all_inputs())
for w in input_widgets.values():
    bind_autosave(w)
    # 绑定任务解析功能
    w.bind("<Control-Return>", parse_and_add_task)
    # 绑定Tab键任务输入功能
    w.bind("<Tab>", task_tab_input)

# ===== 输出展示区 =====
outLf = tk.LabelFrame(root, text="生成的汇报内容", font=("微软雅黑", 12, "bold"), bg="#f8fcff")
outLf.pack(fill="x", expand=True, padx=15, pady=9)
output_text = tk.Text(outLf, font=("Consolas",12), width=100, height=10, bg="#fafdfe", relief="ridge")
output_text.pack(padx=10, pady=10)
output_text.config(state="disabled")

# ====== 主要按钮栏 ======
btnframe = tk.Frame(root, bg="#f5f7fa")
btnframe.pack(pady=6)
def copy_now():
    txt = output_text.get("1.0", tk.END)
    root.clipboard_clear()
    root.clipboard_append(txt)
    # 不显示消息框，直接复制
def clear_inputs():
    for t in input_widgets.values():
        t.delete("1.0", tk.END)
    save_all_inputs()
def show_stats():
    stats = analyze_report_stat()
    # 创建自动关闭的消息框
    msg_window = tk.Toplevel(root)
    msg_window.title("统计分析")
    msg_window.geometry("400x200")
    msg_window.transient(root)
    msg_window.grab_set()
    
    # 消息内容
    label = tk.Label(msg_window, text=stats, padx=20, pady=20, justify=tk.LEFT)
    label.pack()
    
    # 5秒后自动关闭
    msg_window.after(5000, msg_window.destroy)
def show_history_list():
    win = tk.Toplevel(root)
    win.title("历史汇报记录")
    win.geometry("880x460")
    lbox = tk.Listbox(win, font=("Consolas",12), width=30)
    lbox.pack(side="left", fill="y", expand=False, padx=8, pady=10)
    sbar = tk.Scrollbar(win)
    sbar.pack(side="left", fill="y")
    lbox.config(yscrollcommand=sbar.set)
    sbar.config(command=lbox.yview)
    txt = tk.Text(win, font=("Consolas",11), width=70, bg="#f5faff", relief="ridge")
    txt.pack(side="left", fill="both", expand=True, padx=8, pady=10)

    history_keys = load_history_list()
    for k in history_keys: lbox.insert(tk.END, k)
    txt.config(state="disabled")

    def onselect(e):
        sel = lbox.curselection()
        if sel:
            k = history_keys[sel[0]]
            data = load_history_detail(k)
            full = data.get("report","") if data else ""
            txt.config(state="normal")
            txt.delete("1.0", tk.END)
            txt.insert(tk.END, full)
            txt.config(state="disabled")
    lbox.bind("<<ListboxSelect>>", onselect)

    def import_to_inputs(e):
        sel = lbox.curselection()
        if not sel: return
        k = history_keys[sel[0]]
        data = load_history_detail(k)
        if not data: return
        for key in input_widgets:
            val = data.get(key, "")
            input_widgets[key].delete("1.0", tk.END)
            input_widgets[key].insert("1.0", val)
        user_var.set(data.get("user", ""))
        dept_var.set(data.get("dept", ""))
        date_var.set(data.get("date", logical_today()))
        # 创建自动关闭的消息框
        msg_window = tk.Toplevel(root)
        msg_window.title("导入成功")
        msg_window.geometry("400x100")
        msg_window.transient(root)
        msg_window.grab_set()
        
        # 消息内容
        label = tk.Label(msg_window, text="已将历史内容填入当前输入，检查无误后可直接生成或编辑。", padx=20, pady=20)
        label.pack()
        
        # 3秒后自动关闭
        msg_window.after(3000, msg_window.destroy)
        win.destroy()
    lbox.bind("<Double-Button-1>", import_to_inputs)

def open_template_editor():
    win = tk.Toplevel(root)
    win.title("自定义模板编辑")
    win.geometry("510x500")
    lsttxt = tk.Text(win, font=("微软雅黑", 12), width=60, height=20)
    lsttxt.pack(padx=8, pady=8)
    sample = json.dumps(template, ensure_ascii=False, indent=2)
    lsttxt.insert("1.0", sample)
    tk.Label(win, text="可增减/修改（如新增'其它事项'），保存后重启生效", font=("微软雅黑",10)).pack()
    def _save():
        try:
            v = json.loads(lsttxt.get("1.0", tk.END))
            save_template(v)
            # 创建自动关闭的消息框
            msg_window = tk.Toplevel(root)
            msg_window.title("成功")
            msg_window.geometry("300x100")
            msg_window.transient(root)
            msg_window.grab_set()
            
            # 消息内容
            label = tk.Label(msg_window, text="保存成功，重启软件生效！", padx=20, pady=20)
            label.pack()
            
            # 3秒后自动关闭
            msg_window.after(3000, msg_window.destroy)
            win.destroy()
        except Exception as ex:
            # 创建自动关闭的错误消息框
            msg_window = tk.Toplevel(root)
            msg_window.title("格式错误")
            msg_window.geometry("400x150")
            msg_window.transient(root)
            msg_window.grab_set()
            
            # 消息内容
            label = tk.Label(msg_window, text=f"请确保JSON格式正确！\n{str(ex)}", padx=20, pady=20, justify=tk.LEFT)
            label.pack()
            
            # 5秒后自动关闭
            msg_window.after(5000, msg_window.destroy)
    ttk.Button(win, text="保存并关闭", command=_save).pack(pady=5)

def ai_suggest():
    """使用DeepSeek API进行AI建议"""
    # 获取当前填写的内容
    today_work = input_widgets.get("today_work", None)
    tomorrow_plan = input_widgets.get("tomorrow_plan", None)
    
    today_content = today_work.get("1.0", tk.END).strip() if today_work else ""
    tomorrow_content = tomorrow_plan.get("1.0", tk.END).strip() if tomorrow_plan else ""
    
    if not today_content and not tomorrow_content:
        msg_window = tk.Toplevel(root)
        msg_window.title("提示")
        msg_window.geometry("300x100")
        msg_window.transient(root)
        msg_window.grab_set()
        label = tk.Label(msg_window, text="请先填写工作内容！", padx=20, pady=20)
        label.pack()
        msg_window.after(3000, msg_window.destroy)
        return
    
    # 加载AI配置
    ai_config = load_ai_config()
    
    # 检查是否配置了API Key
    if not ai_config.get("api_key"):
        msg_window = tk.Toplevel(root)
        msg_window.title("提示")
        msg_window.geometry("400x150")
        msg_window.transient(root)
        msg_window.grab_set()
        
        tk.Label(msg_window, text="尚未配置AI API Key！\n请先配置API Key才能使用AI建议功能。", 
                font=("微软雅黑", 11), padx=20, pady=10).pack()
        
        def open_config():
            msg_window.destroy()
            show_ai_config_dialog(first_time=True)
        
        tk.Button(msg_window, text="立即配置", command=open_config, bg="#4CAF50", fg="white", 
                 font=("微软雅黑", 10), padx=20).pack(pady=10)
        return
    
    # 检测明天是否为休息日
    def is_weekend(date):
        """判断是否为周末"""
        return date.weekday() >= 5  # 5=周六, 6=周日
    
    def get_tomorrow_date():
        """获取明天的日期"""
        return datetime.now() + timedelta(days=1)
    
    tomorrow_date = get_tomorrow_date()
    is_tomorrow_rest = is_weekend(tomorrow_date)
    force_rest = False
    
    if is_tomorrow_rest:
        # 明天是周末，询问用户是否休息
        rest_win = tk.Toplevel(root)
        rest_win.title("休息日检测")
        rest_win.geometry("400x150")
        rest_win.transient(root)
        rest_win.grab_set()
        
        rest_text = f"明天是{tomorrow_date.strftime('%Y年%m月%d日')}（{'周六' if tomorrow_date.weekday() == 5 else '周日'}），是法定休息日。"
        tk.Label(rest_win, text=rest_text, font=("微软雅黑", 11), wraplength=350).pack(pady=10)
        tk.Label(rest_win, text="您明天是否休息？", font=("微软雅黑", 12, "bold")).pack(pady=5)
        
        rest_result = tk.BooleanVar(value=True)
        
        def set_rest():
            rest_result.set(True)
            rest_win.destroy()
        
        def set_work():
            rest_result.set(False)
            rest_win.destroy()
        
        btn_frame = tk.Frame(rest_win)
        btn_frame.pack(pady=15)
        tk.Button(btn_frame, text="是，明天休息", command=set_rest, bg="#4CAF50", fg="white", 
                 font=("微软雅黑", 10), padx=20).pack(side=tk.LEFT, padx=10)
        tk.Button(btn_frame, text="否，明天工作", command=set_work, bg="#2196F3", fg="white",
                 font=("微软雅黑", 10), padx=20).pack(side=tk.LEFT, padx=10)
        
        root.wait_window(rest_win)
        force_rest = rest_result.get()
    
    # 构建提示词 - 明确说明汇报格式要求
    # 根据是否休息调整明日计划部分的提示
    if force_rest:
        tomorrow_plan_prompt = """2、明日工作计划；
a. 休息（无，无，无）

【重要格式说明】
- 今日工作：括号内格式为（实际完成进度，已完成内容，明天准备做的内容）
  示例：完成XX模块开发（50%，已完成核心功能开发，明天进行接口联调）
- 明日计划：明天是休息日，统一写"休息（无，无，无）"
- 未完成的工作顺延到下一个工作日，不需要在明日计划中体现"""
    else:
        tomorrow_plan_prompt = """2、明日工作计划；
a. 任务名称（预期进度，计划完成内容，后续安排）
b. 任务名称（预期进度，计划完成内容，后续安排）
c. ...

【重要格式说明】
- 今日工作：括号内格式为（实际完成进度，已完成内容，明天准备做的内容）
  示例：完成XX模块开发（50%，已完成核心功能开发，明天进行接口联调）
- 明日计划：括号内格式为（预期进度，计划完成内容，后续安排）
  注意：明日计划是还未开始的工作，所以应该写"预期进度"而不是确定进度
  示例：完成XX模块开发（预计50%，计划完成接口联调，进行测试验证）
- 智能处理未完成工作：如果今日工作未100%完成，请自动将其剩余部分添加到明日计划中
- 如果没有某项内容，填写"无"
- 保持简洁，每条任务一行"""
    
    prompt = f"""请优化以下工作汇报内容，使其更加专业、简洁、有条理。

【当前填写的内容】

1、今日工作完成情况：
{today_content if today_content else '无'}

2、明日工作计划：
{tomorrow_content if tomorrow_content else '无'}

【格式要求 - 必须严格遵守】

输出格式必须如下：

1、今日工作完成情况；
a. 任务名称（进度百分比，已完成的具体内容，明天准备做的内容）
b. 任务名称（进度百分比，已完成的具体内容，明天准备做的内容）
c. ...

{tomorrow_plan_prompt}

【优化要求】
- 使用简洁的短句，条理清晰
- 适当量化工作成效，例如"完成XX模块开发50%"
- 明日计划明确到具体任务或目标
- 严格保持上述格式，不要添加额外说明"""
    
    # 创建带进度条的等待窗口
    wait_window = tk.Toplevel(root)
    wait_window.title("AI建议生成中")
    wait_window.geometry("400x150")
    wait_window.transient(root)
    wait_window.grab_set()
    
    tk.Label(wait_window, text="正在生成AI建议，请稍候...", font=("微软雅黑", 12)).pack(pady=10)
    
    # 进度条
    progress = ttk.Progressbar(wait_window, length=350, mode='indeterminate')
    progress.pack(pady=10)
    progress.start(10)
    
    # 状态标签
    status_label = tk.Label(wait_window, text="正在连接AI服务...", font=("微软雅黑", 10), fg="gray")
    status_label.pack(pady=5)
    
    root.update()
    
    # 调试信息文件路径
    debug_file = os.path.join(ROOT_DIR, "ai_debug.log")
    
    try:
        # 记录调试信息
        with open(debug_file, "a", encoding="utf-8") as f:
            f.write(f"\n{'='*50}\n")
            f.write(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"开始调用AI API...\n")
        
        # 使用用户配置的API
        api_key = ai_config["api_key"]
        api_url = ai_config.get("api_url", DEFAULT_AI_CONFIG["api_url"])
        model = ai_config.get("model", DEFAULT_AI_CONFIG["model"])
        
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
        data = {
            "model": model,
            "messages": [
                {"role": "system", "content": "你是一个专业的工作汇报优化助手，擅长将工作内容转化为专业、简洁、有条理的汇报文本。你必须严格按照用户要求的格式输出，今日工作使用实际进度，明日计划使用预期进度。"},
                {"role": "user", "content": prompt}
            ],
            "temperature": 0.7,
            "max_tokens": 2000
        }
        
        with open(debug_file, "a", encoding="utf-8") as f:
            f.write(f"请求URL: {api_url}\n")
            f.write(f"请求模型: {model}\n")
        
        status_label.config(text="正在生成内容...")
        root.update()
        
        response = requests.post(
            api_url,
            headers=headers,
            json=data,
            timeout=60
        )
        
        with open(debug_file, "a", encoding="utf-8") as f:
            f.write(f"响应状态码: {response.status_code}\n")
        
        wait_window.destroy()
        
        if response.status_code == 200:
            result = response.json()
            ai_content = result["choices"][0]["message"]["content"]
            
            with open(debug_file, "a", encoding="utf-8") as f:
                f.write(f"API调用成功！\n")
                f.write(f"AI回复内容:\n{ai_content[:500]}...\n")
            
            # 显示AI建议窗口，传入重新生成回调
            def regenerate():
                # 重新调用ai_suggest函数
                ai_suggest()
            
            show_ai_suggestion_window(ai_content, today_work, tomorrow_plan, regenerate_callback=regenerate)
        else:
            error_msg = f"API调用失败: HTTP {response.status_code}"
            try:
                error_detail = response.json()
                error_msg += f", 详情: {error_detail}"
            except:
                error_msg += f", 响应内容: {response.text[:200]}"
            
            with open(debug_file, "a", encoding="utf-8") as f:
                f.write(f"{error_msg}\n")
            
            # API调用失败，使用本地建议
            fallback_suggestion(error_msg)
            
    except Exception as e:
        wait_window.destroy()
        error_msg = f"API调用异常: {str(e)}"
        
        with open(debug_file, "a", encoding="utf-8") as f:
            f.write(f"{error_msg}\n")
        
        # API调用失败，使用本地建议
        fallback_suggestion(error_msg)

def fallback_suggestion(error_msg=""):
    """API失败时的本地建议"""
    content = []
    for k in ["today_work","tomorrow_plan"]:
        v = input_widgets[k].get("1.0", tk.END)
        content.append(v)
    fulltext = "\n".join(content)
    advice = make_suggestion(fulltext)
    
    # 显示错误信息和本地建议
    win = tk.Toplevel(root)
    win.title("AI建议（本地模式）")
    win.geometry("500x350")
    win.transient(root)
    win.grab_set()
    
    # 错误信息区域
    if error_msg:
        error_frame = tk.LabelFrame(win, text="API调用失败原因（调试信息）", font=("微软雅黑", 10))
        error_frame.pack(fill="x", padx=20, pady=10)
        
        error_text = tk.Text(error_frame, font=("Consolas", 9), height=4, wrap=tk.WORD)
        error_text.pack(fill="x", padx=5, pady=5)
        error_text.insert("1.0", error_msg)
        error_text.config(state="disabled")
    
    # 本地建议区域
    advice_frame = tk.LabelFrame(win, text="本地建议", font=("微软雅黑", 10))
    advice_frame.pack(fill="both", expand=True, padx=20, pady=10)
    
    advice_label = tk.Label(advice_frame, text=advice, padx=10, pady=10, justify=tk.LEFT, wraplength=400)
    advice_label.pack(fill="both", expand=True)
    
    # 调试文件提示
    debug_file = os.path.join(ROOT_DIR, "ai_debug.log")
    tk.Label(win, text=f"详细调试信息已保存到: {debug_file}", font=("微软雅黑", 9), fg="gray").pack(pady=5)
    
    # 关闭按钮
    ttk.Button(win, text="关闭", command=win.destroy).pack(pady=10)

def show_ai_suggestion_window(ai_content, today_widget, tomorrow_widget, regenerate_callback=None):
    """显示AI建议窗口，用户可以接受、拒绝或重新生成
    
    Args:
        ai_content: AI生成的内容
        today_widget: 今日工作输入框
        tomorrow_widget: 明日计划输入框
        regenerate_callback: 重新生成回调函数
    """
    win = tk.Toplevel(root)
    win.title("AI建议 - 工作汇报优化")
    win.geometry("750x550")
    win.transient(root)
    win.grab_set()
    
    # 说明标签
    header_frame = tk.Frame(win)
    header_frame.pack(fill="x", padx=20, pady=10)
    tk.Label(header_frame, text="AI生成的优化建议：", font=("微软雅黑", 12, "bold")).pack(side=tk.LEFT)
    
    # 显示AI建议内容
    text_frame = tk.Frame(win)
    text_frame.pack(fill="both", expand=True, padx=20, pady=10)
    
    scrollbar = tk.Scrollbar(text_frame)
    scrollbar.pack(side="right", fill="y")
    
    ai_text = tk.Text(text_frame, font=("Consolas", 11), wrap=tk.WORD, yscrollcommand=scrollbar.set)
    ai_text.pack(side="left", fill="both", expand=True)
    scrollbar.config(command=ai_text.yview)
    
    ai_text.insert("1.0", ai_content)
    ai_text.config(state="disabled")
    
    # 按钮框架
    btn_frame = tk.Frame(win)
    btn_frame.pack(pady=15)
    
    def accept_suggestion():
        """接受AI建议，将内容填充到输入框"""
        # 解析AI生成的内容
        content = ai_content
        
        # 尝试提取今日工作和明日计划
        today_match = re.search(r'1[、.]今日工作完成情况[；:]?(.*?)(?=2[、.]明日工作计划|$)', content, re.DOTALL)
        tomorrow_match = re.search(r'2[、.]明日工作计划[；:]?(.*)', content, re.DOTALL)
        
        if today_match and today_widget:
            today_text = today_match.group(1).strip()
            # 清理编号
            today_text = re.sub(r'^[a-zA-Z][.．、]\s*', '', today_text, flags=re.MULTILINE)
            today_widget.delete("1.0", tk.END)
            today_widget.insert("1.0", today_text)
        
        if tomorrow_match and tomorrow_widget:
            tomorrow_text = tomorrow_match.group(1).strip()
            # 清理编号
            tomorrow_text = re.sub(r'^[a-zA-Z][.．、]\s*', '', tomorrow_text, flags=re.MULTILINE)
            tomorrow_widget.delete("1.0", tk.END)
            tomorrow_widget.insert("1.0", tomorrow_text)
        
        # 保存输入
        save_all_inputs()
        
        win.destroy()
        
        # 显示成功消息
        msg_window = tk.Toplevel(root)
        msg_window.title("成功")
        msg_window.geometry("300x100")
        msg_window.transient(root)
        msg_window.grab_set()
        label = tk.Label(msg_window, text="AI建议已应用到输入框！", padx=20, pady=20)
        label.pack()
        msg_window.after(2000, msg_window.destroy)
    
    def cancel_suggestion():
        """取消，关闭窗口"""
        win.destroy()
    
    def regenerate_suggestion():
        """重新生成建议"""
        win.destroy()
        if regenerate_callback:
            regenerate_callback()
    
    # 按钮样式
    btn_style = {"font": ("微软雅黑", 10), "padx": 15, "pady": 5}
    
    # 同意应用按钮 - 绿色
    tk.Button(btn_frame, text="✓ 同意应用", command=accept_suggestion, 
             bg="#4CAF50", fg="white", **btn_style).pack(side=tk.LEFT, padx=5)
    
    # 重新生成按钮 - 蓝色
    tk.Button(btn_frame, text="↻ 重新生成", command=regenerate_suggestion,
             bg="#2196F3", fg="white", **btn_style).pack(side=tk.LEFT, padx=5)
    
    # 取消按钮 - 灰色
    tk.Button(btn_frame, text="✗ 取消", command=cancel_suggestion,
             bg="#9E9E9E", fg="white", **btn_style).pack(side=tk.LEFT, padx=5)

def send_to_wechat_wrapper():
    """发送到企微的包装函数，确保先有内容再发送"""
    # 先检查是否有内容
    content = output_text.get("1.0", tk.END).strip()
    if not content:
        # 如果没有内容，先生成汇报
        generate_report(False)
        content = output_text.get("1.0", tk.END).strip()
    
    if content:
        success = send_to_wechat(content)
        if success:
            # 创建自动关闭的消息框
            msg_window = tk.Toplevel(root)
            msg_window.title("发送成功")
            msg_window.geometry("300x100")
            msg_window.transient(root)
            msg_window.grab_set()
            
            # 消息内容
            label = tk.Label(msg_window, text="已复制内容并打开企业微信！", padx=20, pady=20)
            label.pack()
            
            # 3秒后自动关闭
            msg_window.after(3000, msg_window.destroy)
        else:
            # 创建自动关闭的错误消息框
            msg_window = tk.Toplevel(root)
            msg_window.title("发送失败")
            msg_window.geometry("300x100")
            msg_window.transient(root)
            msg_window.grab_set()
            
            # 消息内容
            label = tk.Label(msg_window, text="发送到企微失败，请检查企微是否安装！", padx=20, pady=20)
            label.pack()
            
            # 3秒后自动关闭
            msg_window.after(3000, msg_window.destroy)

# 主按钮 - 所有按钮放在同一行
main_buttons = tk.Frame(btnframe, bg="#f5f7fa")
main_buttons.pack(pady=5)

# 核心功能按钮（同一行）
ttk.Button(main_buttons, text="发送到企微", command=send_to_wechat_wrapper, style="Primary.TButton").pack(side=tk.LEFT, padx=5)
ttk.Button(main_buttons, text="生成汇报", command=lambda: generate_report(True)).pack(side=tk.LEFT, padx=5)
ttk.Button(main_buttons, text="清空重写", command=clear_inputs).pack(side=tk.LEFT, padx=5)
ttk.Button(main_buttons, text="查历史", command=show_history_list).pack(side=tk.LEFT, padx=5)
ttk.Button(main_buttons, text="AI建议", command=ai_suggest).pack(side=tk.LEFT, padx=5)
ttk.Button(main_buttons, text="模板定制", command=open_template_editor).pack(side=tk.LEFT, padx=5)

def generate_report(autocopy=False):
    user, dept, date = user_var.get().strip(), dept_var.get().strip(), date_var.get().strip()
    if not user or not dept or not date:
        messagebox.showwarning("信息须全填！", "请填写姓名、部门和日期！")
        return
    userkey = f"{user}_{dept}"
    report_dict = dict(user=user, dept=dept, date=date)
    outlist = []
    last_tomorrow = ""
    for item in template:
        key = item.get("key","")
        raw = input_widgets.get(key, None)
        value = raw.get("1.0", tk.END).strip() if raw else ""
        if key == "today_work" and not value:
            t = load_last_tomorrow(userkey)
            if t:
                value = t
                raw.insert("1.0", t)
        if key in ("today_work", "tomorrow_plan"):
            value = format_with_bullets(value) if value else ("a. 休息" if key == "tomorrow_plan" else "")
        report_dict[key] = value
        outlist.append(f"{item['title']}；\n{value}\n")
        if key == "tomorrow_plan":
            last_tomorrow = value
    toptext = f"姓名：{user}  部门：{dept}  汇报日期：{date}\n"
    report_full = toptext + "=" * 52 + "\n" + "".join(outlist)
    report_dict["report"] = report_full
    save_user_tomorrow(userkey, last_tomorrow)
    token = get_report_token(user, dept, date)
    save_report_history(token, report_dict)
    output_text.config(state="normal")
    output_text.delete("1.0", tk.END)
    output_text.insert(tk.END, report_full)
    output_text.config(state="disabled")
    if autocopy:
        root.clipboard_clear()
        root.clipboard_append(report_full)
        # 创建自动关闭的消息框
        msg_window = tk.Toplevel(root)
        msg_window.title("已复制")
        msg_window.geometry("300x100")
        msg_window.transient(root)
        msg_window.grab_set()
        
        # 消息内容
        label = tk.Label(msg_window, text="汇报内容已生成并复制到剪贴板！", padx=20, pady=20)
        label.pack()
        
        # 3秒后自动关闭
        msg_window.after(3000, msg_window.destroy)
    save_all_inputs()


# 启动后自动加载输入内容
root.after(200, load_all_inputs)

# 检查是否首次使用（没有配置API Key）
def check_first_time():
    ai_config = load_ai_config()
    if not ai_config.get("api_key"):
        # 首次使用，弹出配置窗口
        show_ai_config_dialog(first_time=True)

root.after(500, check_first_time)


def on_close_all():
    save_all_inputs()
    root.destroy()


root.protocol("WM_DELETE_WINDOW", on_close_all)

root.mainloop()