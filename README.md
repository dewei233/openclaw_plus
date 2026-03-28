# 🦞✨ openclaw_plus

这是一个给 OpenClaw 增强能力的小型功能仓库。目前包含两个核心功能：

## 💾 1. OpenClaw 主目录自动备份

位置：

- [`claw_backup/claw_backup.py`](/Users/dewei/Documents/demo/openclaw_plus/claw_backup/claw_backup.py)
- [`claw_backup/readme_for_ai.md`](/Users/dewei/Documents/demo/openclaw_plus/claw_backup/readme_for_ai.md)

这个功能用于备份 OpenClaw 主目录，通常是 `~/.openclaw`。脚本会在目标目录内自动执行：

- `git add .`
- 检查变更
- 自动提交
- 推送到 `origin main`
- 发送飞书 webhook 通知

适合用来做 OpenClaw 配置、插件和本地状态的持续备份。

## ✅ 2. 飞书命令执行审批

位置：

- [`feishu_approval_function/setup.sh`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup.sh)
- [`feishu_approval_function/setup_doc.md`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup_doc.md)
- [`feishu_approval_function/readme_for_ai.md`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/readme_for_ai.md)

这个功能用于给 OpenClaw 增加飞书渠道的命令执行审批能力。补丁完成后，OpenClaw 在飞书里遇到高权限命令时，可以发送审批卡片，由用户点击“允许一次”或“拒绝”，并将审批结果真正回传给系统。

它解决的问题是 OpenClaw 默认在飞书中不支持 exec approval。

## 🚀 推荐使用方式

不推荐你自己手动看代码、手工 patch、手工配配置。

推荐方式是直接把对应功能目录下的 `readme_for_ai.md` 丢给你的龙虾阅读，然后让它代替你完成全部工作。

对应关系如下：

- 要配置自动备份：把 [`claw_backup/readme_for_ai.md`](/Users/dewei/Documents/demo/openclaw_plus/claw_backup/readme_for_ai.md) 给你的龙虾
- 要配置飞书审批：把 [`feishu_approval_function/readme_for_ai.md`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/readme_for_ai.md) 给你的龙虾

这些 `readme_for_ai.md` 已经明确告诉 AI：

- 应该完成哪些具体步骤
- 什么时候优先复用现有脚本
- 哪些配置项必须向主人询问
- 如何验证功能是否真正可用

## 🛠️ 推荐工作流

1. 选择你要启用的功能
2. 打开对应目录下的 `readme_for_ai.md`
3. 直接把全文交给你的龙虾
4. 让它在你的机器上完成配置、验证和必要的提问

如果过程中涉及以下信息，AI 应该向主人确认，而不是自行猜测：

- Git 仓库地址
- SSH key
- 飞书 webhook
- 飞书审批人
- OpenClaw 安装路径
- 是否允许重启进程

## 📁 仓库结构

- [`claw_backup`](/Users/dewei/Documents/demo/openclaw_plus/claw_backup)
  OpenClaw 主目录备份能力
- [`feishu_approval_function`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function)
  飞书审批能力
