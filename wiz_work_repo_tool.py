# 文件名如：工作汇报云端版.py（推荐用英文：work_report_web.py)

import streamlit as st
import json, os, datetime

st.set_page_config(page_title="工作汇报系统", layout="wide")

# ----------------------- 数据与结构 -------------------------- #
DATA_DIR = "work_report_data"
HIST_FILE = os.path.join(DATA_DIR, "history.json")
TPL_FILE = os.path.join(DATA_DIR, "template.json")

if not os.path.exists(DATA_DIR):
    os.makedirs(DATA_DIR)
if not os.path.exists(HIST_FILE):
    with open(HIST_FILE, "w", encoding="utf-8") as f:
        json.dump([], f)
if not os.path.exists(TPL_FILE):
    default_tpl = [
        {"title":"今日工作完成情况", "key":"today_work"},
        {"title":"明日工作计划", "key":"tomorrow_plan"},
        {"title":"遇到问题/需协助", "key":"problems"},
    ]
    with open(TPL_FILE, "w", encoding="utf-8") as f:
        json.dump(default_tpl, f, ensure_ascii=False, indent=2)

def load_json(fp, default):
    try:
        with open(fp, "r", encoding="utf-8") as f:
            return json.load(f)
    except:
        return default

def save_json(fp, obj):
    with open(fp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

def excel_letters(n):
    # a, b, ..., z, aa, ab...
    res = ""
    while True:
        n, r = divmod(n, 26)
        res = chr(97 + r) + res
        if n == 0:
            break
        n -= 1
    return res + "."

def proper_bullet(line, idx):
    import re
    patterns = [
        r"^[a-zA-Z]{1,2}\.\s?.*",
        r"^\d+\.\s?.*",
        r"^①|②|③|④|⑤|⑥|⑦|⑧|⑨|⑩",
    ]
    for pat in patterns:
        if re.match(pat, line):
            return line
    circled = ["①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩"]
    if idx < 10:
        return f"{excel_letters(idx)} {line}"
    elif idx < 36:
        return f"{idx+1}. {line}"
    else:
        return f"{circled[idx%10]} {line}"

def format_with_bullets(text):
    lines = text.strip().split("\n")
    return "\n".join([proper_bullet(line, i) for i, line in enumerate(lines) if line.strip()])

def get_today():
    return str(datetime.date.today())

def make_suggestion(content):
    SUGGESTIONS=[
        "建议使用简洁短句，条理清晰；",
        "建议量化工作成效，例如“完成XX开发80%”；",
        "明日计划请具体到任务/目标；",
        "如有难题建议在汇报中注明。",
    ]
    lines = content.strip().split("\n")
    advice = []
    if any("完成" in l and "%" not in l for l in lines):
        advice.append("建议补充百分比。")
    if all(not l.strip() for l in lines):
        advice.append("内容过少，建议细化。")
    advice += SUGGESTIONS[:2] if len(content)<100 else SUGGESTIONS[2:]
    return "\n".join(advice)

# -------------------- UI/交互-------------------#
st.header("📋 工作汇报系统（云端网页版）")

col1, col2, col3 = st.columns([1,1,1])
with col1:
    user = st.text_input("姓名")
with col2:
    dept = st.text_input("部门")
with col3:
    date = st.date_input("汇报日期", value=datetime.date.today())
date_str = str(date)

# 加载模板
template = load_json(TPL_FILE, [])
if not template:
    st.error("模板丢失，请重置")
    st.stop()

# 用于明日内容自动转今日
history_list = load_json(HIST_FILE, [])

def get_last_tomorrow(user, dept):
    # 找到当前人最后一次的明日计划
    history = [h for h in history_list if h.get("user")==user and h.get("dept")==dept]
    if history:
        last = sorted(history, key=lambda x:x['date'], reverse=True)[0]
        return last.get("tomorrow_plan","")
    return ""

curr_fields = {}
with st.form("report_form"):
    for field in template:
        key = field['key']
        title = field['title']
        # 明日转今日
        default_txt = ""
        if key=="today_work":
            default_txt = get_last_tomorrow(user, dept)
        value = st.text_area(title, value=default_txt, height=100)
        curr_fields[key] = value
    submitted = st.form_submit_button("生成/保存汇报")

if submitted:
    outlist = []
    last_tomorrow = ""
    for field in template:
        key = field["key"]
        value = curr_fields[key]
        if key in ("today_work","tomorrow_plan"):
            value = format_with_bullets(value) if value else ("a. 休息" if key=="tomorrow_plan" else "")
        outlist.append(f"{field['title']}：\n{value}\n")
        if key=="tomorrow_plan":
            last_tomorrow = value
    toptext = f"姓名：{user}  部门：{dept}  汇报日期：{date_str}\n"
    report_full = toptext + "="*52 + "\n" + "".join(outlist)
    # 写入历史
    newentry = {"user":user, "dept":dept, "date":date_str, "report":report_full}
    for field in template:
        newentry[field["key"]] = curr_fields[field["key"]]
    history_list.append(newentry)
    save_json(HIST_FILE, history_list)
    st.success("汇报已生成，下方可一键复制")
    st.code(report_full, language="markdown")
    st.download_button("导出为txt", report_full, file_name=f"work_report_{user}_{date_str}.txt")
    st.button("复制内容", on_click=lambda: st.session_state.setdefault('copied', True))
    # 智能建议
    with st.expander("免费写作建议/优化：", expanded=False):
        st.write(make_suggestion(outlist[0]+outlist[1]))

# --------- 查历史（可一键导入）----------------------
st.markdown("---")
with st.expander("历史记录：点击查看历史报表，点击“导入此历史”，会自动填入输入区"):
    ids = [f"{h.get('user','')}|{h.get('dept','')}|{h.get('date','')}" for h in history_list[::-1]]
    selected = st.selectbox("选择历史记录", ids)
    if selected:
        idx = ids.index(selected)
        h = history_list[::-1][idx]
        st.code(h.get("report",""), language="markdown")
        if st.button("导入此历史作为当前编辑内容"):
            # 重新填充到session_state
            for f in template:
                k = f["key"]
                st.session_state[k] = h.get(k,"")
            st.session_state["用户手动导入"] = True
            st.experimental_rerun()

# ---------- 模板定制 ----------------------
with st.expander("自定义汇报模板", expanded=False):
    txt = st.text_area("如需调整模板(如增/减栏目/换名称)，请编辑JSON：", value = json.dumps(template, ensure_ascii=False, indent=2))