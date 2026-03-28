#!/usr/bin/env python3
import subprocess
import json
import requests
import os
from datetime import datetime

# 这里设置接收备份提醒的webhook地址 
WEBHOOK_URL = "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"

def run_git_command(command):
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            cwd="."
        )
        return result.returncode == 0, result.stdout.strip(), result.stderr.strip()
    except Exception as e:
        return False, "", str(e)

def get_git_status():
    success, output, error = run_git_command("git status --porcelain")
    if not success:
        return {"error": f"获取git状态失败: {error}"}
    
    if not output:
        return {"modified": 0, "added": 0, "deleted": 0, "total": 0, "files": []}
    
    lines = output.split('\n')
    modified = 0
    added = 0
    deleted = 0
    files = []
    
    for line in lines:
        if not line:
            continue
        
        status = line[:2]
        filename = line[2:].lstrip()
        
        if 'M' in status:
            modified += 1
            files.append(f"修改: {filename}")
        elif 'A' in status:
            added += 1
            files.append(f"新增: {filename}")
        elif 'D' in status:
            deleted += 1
            files.append(f"删除: {filename}")
        elif '?' in status and '??' in status:
            added += 1
            files.append(f"未跟踪: {filename}")
    
    total = modified + added + deleted
    
    return {
        "modified": modified,
        "added": added,
        "deleted": deleted,
        "total": total,
        "files": files
    }

def commit_changes():
    success, output, error = run_git_command("git add .")
    if not success:
        return False, f"添加文件失败: {error}"
    
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    commit_message = f"自动备份: {now}"
    
    success, output, error = run_git_command(f'git commit -m "{commit_message}"')
    if not success:
        return False, f"提交失败: {error}"
    
    success, output, error = run_git_command("git push origin main")
    if not success:
        return False, f"推送失败: {error}"
    
    return True, "提交并推送成功"

def send_feishu_webhook(status_info,webhook_url=WEBHOOK_URL):
    dir_name = os.path.basename(os.getcwd()).replace('.', '')
    backup_title = f"{dir_name}备份报告"
    
    total = status_info.get("total", 0)
    modified = status_info.get("modified", 0)
    added = status_info.get("added", 0)
    deleted = status_info.get("deleted", 0)
    files = status_info.get("files", [])
    
    file_list = ""
    if files:
        file_list = "\n".join(files)
    
    if total == 0:
        message = f"✅ {backup_title}\n无文件变化"
    else:
        message = f"""📊 {backup_title}

📁 变化文件总数: {total}
  - 修改: {modified}
  - 新增: {added}
  - 删除: {deleted}

📄 文件列表:
{file_list if file_list else "无"}

🕒 备份时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}"""
    
    payload = {
        "msg_type": "text",
        "content": {
            "text": message
        }
    }
    
    try:
        response = requests.post(
            webhook_url,
            headers={"Content-Type": "application/json"},
            data=json.dumps(payload),
            timeout=10
        )
        response.raise_for_status()
        
        result = response.json()
        if result.get("code") == 0 or result.get("StatusCode") == 0:
            return True, "webhook发送成功"
        else:
            return False, f"webhook返回错误: {result}"
    
    except Exception as e:
        return False, f"webhook请求失败: {str(e)}"

def main():
    print("🔍 添加未追踪文件到暂存区...")
    success, output, error = run_git_command("git add .")
    if not success:
        print(f"❌ 添加文件失败: {error}")
        return False
    
    print("🔍 检查Git仓库状态...")
    
    status_info = get_git_status()
    if "error" in status_info:
        print(f"❌ 错误: {status_info['error']}")
        return False
    
    total = int(status_info.get("total", 0))
    print(f"📊 发现 {total} 个文件变化")
    
    if total > 0:
        print("🚀 提交并推送更改...")
        success, message = commit_changes()
        if not success:
            print(f"❌ 提交失败: {message}")
            status_info["commit_status"] = "失败"
            status_info["commit_message"] = message
        else:
            print("✅ 提交并推送成功")
            status_info["commit_status"] = "成功"
    
    print("📨 发送飞书webhook通知...")
    success, message = send_feishu_webhook(status_info)
    
    if success:
        print("✅ Webhook发送成功")
    else:
        print(f"❌ Webhook发送失败: {message}")
    
    return success

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)