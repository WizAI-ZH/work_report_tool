import tkinter as tk
from tkinter import messagebox, simpledialog, ttk
import os, json, re
from datetime import datetime

ROOT_DIR = "工作汇报记录"    # 所有数据写这个文件夹
CFG_FILE = os.path.join(ROOT_DIR, "report_config.json")
HISTORY_DIR = os.path.join(ROOT_DIR, "report_history")

# 启动时自动创建
if not os.path.exists(ROOT_DIR):
    os.makedirs(ROOT_DIR)
if not os.path.exists(HISTORY_DIR):
    os.makedirs(HISTORY_DIR)

TEMPLATE_FILE = os.path.join(ROOT_DIR, "report_template.json")
SUGGESTIONS = [
    "建议使用简洁的短句，条理清晰；",
    "适当量化工作成效，例如“完成XX模块开发50%”；",
    "明日计划建议明确到具体任务或目标；",
    "如有困难，建议在计划部分注明需协助资源；",
]

if not os.path.exists(HISTORY_DIR):
    os.makedirs(HISTORY_DIR)

def excel_letters(n):
    """生成 a-z, aa-zz...的序号"""
    res = ""
    while True:
        n, r = divmod(n, 26)
        res = chr(97 + r) + res
        if n == 0:
            break
        n -= 1
    return res + "."

def proper_bullet(line, idx):
    """判断已存在的各种编号，否则生成合理编号"""
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
    # 每用户保存明日计划（支持多用户）
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
        {"title": "2、明日工作计划", "key": "tomorrow_plan"},
        {"title": "3、遇到的问题/需协助", "key": "problems"},
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

# -------------- 自动保存/恢复功能 ----------------
def save_all_inputs():
    cache = {
        "user": user_var.get(),
        "dept": dept_var.get(),
        "date": date_var.get(),
        "fields": {k: input_widgets[k].get("1.0", tk.END) for k in input_widgets}
    }
    # 保留原本的 tomorrow 结构（含明日-今日转换）
    oldtomorrow = {}
    if os.path.exists(CFG_FILE):
        try:
            with open(CFG_FILE, 'r', encoding='utf-8') as fr:
                oldall = json.load(fr)
                if "tomorrow" in oldall:
                    oldtomorrow = oldall["tomorrow"]
        except: pass
    cache["tomorrow"] = oldtomorrow
    with open(CFG_FILE, 'w', encoding='utf-8') as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)

def load_all_inputs():
    if not os.path.exists(CFG_FILE): return
    with open(CFG_FILE, 'r', encoding='utf-8') as f:
        try:
            cache = json.load(f)
        except:
            return
    user_var.set(cache.get("user", ""))
    dept_var.set(cache.get("dept", ""))
    date_var.set(cache.get("date", datetime.now().strftime("%Y-%m-%d")))
    for k, v in cache.get("fields", {}).items():
        if k in input_widgets:
            input_widgets[k].delete("1.0", tk.END)
            input_widgets[k].insert("1.0", v)

# ------------------- GUI设计 -------------------------
root = tk.Tk()
root.title("工作汇报全功能生成器")
root.geometry("820x830")
style = ttk.Style()
style.theme_use("clam")
root.config(bg="#f5f7fa")

# 头部输入区
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
date_var = tk.StringVar(value=datetime.now().strftime("%Y-%m-%d"))
date_entry = ttk.Entry(headerframe, textvariable=date_var, width=12)
date_entry.pack(side="left", padx=4)
def select_date():
    sel = simpledialog.askstring("自定义日期", "格式：2024-05-19", parent=root)
    if sel: date_var.set(sel)
date_btn = ttk.Button(headerframe, text="选择日期", command=select_date)
date_btn.pack(side="left", padx=(8,0))

# 动态表单区
inputframe = tk.LabelFrame(root, text="工作内容填写区", bg="#f5f7fa", font=("微软雅黑", 13, "bold"))
inputframe.pack(fill='x', padx=14, pady=6)
template = load_template()
input_widgets = {}
for item in template:
    tk.Label(inputframe, text=item["title"], font=("微软雅黑",11,"bold"), bg="#f5f7fa").pack(anchor="w", padx=8, pady=(5,0))
    textw = tk.Text(inputframe, width=100, height=5, font=("Consolas",11), relief="solid", borderwidth=1, bg="#FFFFFF")
    textw.pack(padx=10, pady=4)
    input_widgets[item["key"]] = textw

# 自动保存输入内容
def bind_autosave(widget):
    widget.bind("<KeyRelease>", lambda e: save_all_inputs())
    widget.bind("<FocusOut>", lambda e: save_all_inputs())
user_var.trace_add("write", lambda *a: save_all_inputs())
dept_var.trace_add("write", lambda *a: save_all_inputs())
date_var.trace_add("write", lambda *a: save_all_inputs())
for w in input_widgets.values():
    bind_autosave(w)

# 明日转今日逻辑（仍支持）
def load_last_tomorrow_to_today():
    key = f"{user_var.get()}_{dept_var.get()}"
    last_tomorrow = load_last_tomorrow(key)
    if last_tomorrow and "today_work" in input_widgets:
        input_widgets["today_work"].delete("1.0", tk.END)
        input_widgets["today_work"].insert(tk.END, last_tomorrow)

def on_user_dept_change(*args):
    load_last_tomorrow_to_today()
    save_all_inputs()
user_var.trace("w", on_user_dept_change)
dept_var.trace("w", on_user_dept_change)

# 启动时立即加载所有内容
root.after(200, load_all_inputs)

# 操作按钮
btnframe = tk.Frame(root, bg="#f5f7fa")
btnframe.pack(pady=6)
def copy_now():
    txt = output_text.get("1.0", tk.END)
    root.clipboard_clear()
    root.clipboard_append(txt)
    messagebox.showinfo("已复制", "汇报内容已复制到剪贴板！")
def clear_inputs():
    for t in input_widgets.values():
        t.delete("1.0", tk.END)
    save_all_inputs()
def show_stats():
    messagebox.showinfo("统计分析", analyze_report_stat())
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
        # 自动填充各输入栏
        for key in input_widgets:
            val = data.get(key, "")
            input_widgets[key].delete("1.0", tk.END)
            input_widgets[key].insert("1.0", val)
        # 同步姓名、部门、日期
        user_var.set(data.get("user", ""))
        dept_var.set(data.get("dept", ""))
        date_var.set(data.get("date", datetime.now().strftime("%Y-%m-%d")))
        messagebox.showinfo("导入成功","已将历史内容填入当前输入，检查无误后可直接生成或编辑。")
        win.destroy()  # 导入后自动关闭历史窗口，体验更顺畅

    # 新增：双击历史导入内容！
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
            messagebox.showinfo("成功", "保存成功，重启软件生效！")
            win.destroy()
        except Exception as ex:
            messagebox.showerror("格式错误", "请确保JSON格式正确！\n" + str(ex))
    ttk.Button(win, text="保存并关闭", command=_save).pack(pady=5)
def smart_suggest():
    content = []
    for k in ["today_work","tomorrow_plan"]:
        v = input_widgets[k].get("1.0", tk.END)
        content.append(v)
    fulltext = "\n".join(content)
    advice = make_suggestion(fulltext)
    messagebox.showinfo("智能建议", advice)

ttk.Button(btnframe, text="生成汇报", command=lambda: generate_report(True), style="Primary.TButton").grid(row=0,column=0,padx=12)
ttk.Button(btnframe, text="复制内容", command=copy_now).grid(row=0,column=1,padx=8)
ttk.Button(btnframe, text="清空重写", command=clear_inputs).grid(row=0,column=2,padx=8)
ttk.Button(btnframe, text="统计分析", command=show_stats).grid(row=0,column=3,padx=8)
ttk.Button(btnframe, text="查历史", command=show_history_list).grid(row=0,column=4,padx=8)
ttk.Button(btnframe, text="模板定制", command=open_template_editor).grid(row=0,column=5,padx=8)
ttk.Button(btnframe, text="智能建议", command=smart_suggest).grid(row=0,column=6,padx=8)

# 输出区
outLf = tk.LabelFrame(root, text="生成的汇报内容", font=("微软雅黑", 12, "bold"), bg="#f8fcff")
outLf.pack(fill="both", expand=True, padx=15,pady=9)
output_text = tk.Text(outLf, font=("Consolas",12), width=100, height=18, bg="#fafdfe", relief="ridge")
output_text.pack(padx=10, pady=10)
output_text.config(state="disabled")

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
        if key=="today_work" and not value:
            t = load_last_tomorrow(userkey)
            if t:
                value = t
                raw.insert("1.0", t)
        if key in ("today_work", "tomorrow_plan"):
            value = format_with_bullets(value) if value else ("a. 休息" if key=="tomorrow_plan" else "")
        report_dict[key] = value
        outlist.append(f"{item['title']}；\n{value}\n")
        if key=="tomorrow_plan":
            last_tomorrow = value
    toptext = f"姓名：{user}  部门：{dept}  汇报日期：{date}\n"
    report_full = toptext + "="*52 + "\n" + "".join(outlist)
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
        messagebox.showinfo("已复制", "汇报内容已生成并复制到剪贴板！")
    save_all_inputs() # 生成后也存一次

# 启动即恢复输入
root.after(200, load_all_inputs)

# 关闭时自动保存
root.protocol("WM_DELETE_WINDOW", lambda: (save_all_inputs(), root.destroy()))

root.mainloop()