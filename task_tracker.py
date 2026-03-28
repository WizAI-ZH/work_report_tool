import json
import os
from datetime import datetime, timedelta

TASK_FILE = os.path.join("工作汇报记录", "task_tracker.json")


def load_tasks():
    """加载任务跟踪数据"""
    if os.path.exists(TASK_FILE):
        try:
            with open(TASK_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "tasks": [],
        "completed": []
    }


def save_tasks(data):
    """保存任务跟踪数据"""
    try:
        with open(TASK_FILE, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        return True
    except Exception:
        return False


def add_task(task_name, progress="0%", completed="", planned=""):
    """添加新任务"""
    data = load_tasks()
    task = {
        "id": f"task_{datetime.now().timestamp()}",
        "name": task_name,
        "progress": progress,
        "completed": completed,
        "planned": planned,
        "created_at": datetime.now().strftime("%Y-%m-%d"),
        "status": "in_progress"
    }
    data["tasks"].append(task)
    save_tasks(data)
    return task


def update_task(task_id, progress=None, completed=None, planned=None, status=None):
    """更新任务信息"""
    data = load_tasks()
    for task in data["tasks"]:
        if task["id"] == task_id:
            if progress is not None:
                task["progress"] = progress
            if completed is not None:
                task["completed"] = completed
            if planned is not None:
                task["planned"] = planned
            if status is not None:
                task["status"] = status
            save_tasks(data)
            return True
    return False


def complete_task(task_id):
    """完成任务"""
    data = load_tasks()
    for i, task in enumerate(data["tasks"]):
        if task["id"] == task_id:
            task["status"] = "completed"
            task["completed_at"] = datetime.now().strftime("%Y-%m-%d")
            data["completed"].append(data["tasks"].pop(i))
            save_tasks(data)
            return True
    return False


def get_tasks_by_date(date_str):
    """获取指定日期的任务"""
    data = load_tasks()
    return [task for task in data["tasks"] if task["created_at"] == date_str]


def get_pending_tasks():
    """获取未完成的任务"""
    data = load_tasks()
    return [task for task in data["tasks"] if task["status"] == "in_progress"]


def generate_today_work():
    """生成今日工作内容"""
    # 获取昨天的日期
    yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    
    # 获取未完成的任务
    pending_tasks = get_pending_tasks()
    
    # 生成今日工作内容
    today_work = []
    for task in pending_tasks:
        task_str = f"{task['name']}（{task['progress']}，{task['completed'] or '无'}，{task['planned'] or '无'}）"
        today_work.append(task_str)
    
    return "\n".join(today_work) if today_work else ""


def parse_task_input(input_str):
    """解析任务输入格式：任务名字（进度情况，完成内容，准备做的内容）"""
    import re
    pattern = r"^(.*?)\s*\(([^,]+),\s*([^,]*),\s*([^)]*)\)$"
    match = re.match(pattern, input_str)
    if match:
        task_name, progress, completed, planned = match.groups()
        return {
            "name": task_name.strip(),
            "progress": progress.strip(),
            "completed": completed.strip(),
            "planned": planned.strip()
        }
    return None