# claw_backup for AI

本说明的读者不是最终用户，而是 OpenClaw 的 AI 助手。

你的任务是替主人完成 `claw_backup.py` 的接入、配置和自动化备份设置，用于备份 OpenClaw 主目录，通常是 `~/.openclaw`。

脚本路径：
[`claw_backup.py`](/Users/dewei/Documents/demo/openclaw_plus/claw_backup/claw_backup.py)

## 你的目标

你需要帮助主人完成以下事项：

1. 确认要备份的 OpenClaw 主目录，默认是 `~/.openclaw`
2. 确认该目录已经是 Git 仓库
3. 确认该目录已经配置可写的远端仓库
4. 配置脚本中的飞书 webhook
5. 验证脚本可运行
6. 将该脚本接入为一个可复用的 skill
7. 按需要配置定时自动备份

## 脚本行为

`claw_backup.py` 会在当前工作目录执行以下操作：

1. `git add .`
2. 检查仓库变更
3. 自动提交，提交信息格式为 `自动备份: YYYY-MM-DD HH:MM`
4. 执行 `git push origin main`
5. 发送飞书 webhook 通知

这意味着你必须确保脚本是在目标仓库目录中运行，而不是在脚本所在目录运行。

正确运行方式：

```bash
cd ~/.openclaw
python3 /Users/dewei/Documents/demo/openclaw_plus/claw_backup/claw_backup.py
```

## 需要你完成的配置

### 1. 确认备份目录

默认目录是：

```bash
~/.openclaw
```

如果主人的 OpenClaw 数据目录不是这里，你必须先询问主人，不要自行猜测。

### 2. 确认 Git 仓库可用

你需要确认目标目录满足以下条件：

- 已执行过 `git init` 或已经是现有仓库
- 已配置远端 `origin`
- 默认推送分支是 `main`，或者脚本已被相应修改
- 当前机器已经配置好可用于推送的 SSH key

如果以下任一信息缺失，你需要询问主人：

- 远端仓库地址
- GitHub / GitLab 账号归属
- 应使用哪把 SSH key
- 默认分支是否是 `main`

### 3. 配置飞书 webhook

脚本中有以下配置项：

```python
WEBHOOK_URL = "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"
```

你需要将其替换为真实可用的 webhook 地址。

如果主人没有提供飞书 webhook，必须询问主人，不能伪造，也不要留空后假设系统已经配置。

### 4. 安装依赖

脚本依赖 `requests`。如果环境里没有，需要安装：

```bash
python3 -m pip install requests
```

### 5. 验证运行

完成配置后，你需要在目标目录执行一次：

```bash
cd ~/.openclaw
python3 /Users/dewei/Documents/demo/openclaw_plus/claw_backup/claw_backup.py
```

验证以下结果：

- 脚本可以启动
- 能识别 Git 状态
- 有变更时能成功提交并推送
- webhook 能正常发送

如果失败，优先检查：

- 当前目录是否正确
- 远端仓库是否可推送
- SSH 权限是否正确
- webhook 是否有效
- 默认分支是否为 `main`

## 配置为 Skill

你需要把这个备份能力包装成 OpenClaw 可调用的 skill，让系统后续能稳定触发备份流程。

建议 skill 的职责如下：

- 目标：备份 OpenClaw 主目录到 Git 远端
- 输入：可选目录路径；默认 `~/.openclaw`
- 执行方式：进入目标目录后运行 `claw_backup.py`
- 输出：返回备份是否成功、Git 提交是否成功、Webhook 是否成功

建议 skill 描述包含以下约束：

- 必须在目标仓库目录中执行，不能直接在脚本目录执行
- 默认目录为 `~/.openclaw`
- 如需仓库地址、账号、SSH key、Webhook 等外部配置，先询问主人
- 如果默认分支不是 `main`，需要先询问主人是否修改脚本或改仓库设置

建议 skill 调用步骤：

1. 确认目标目录存在
2. 确认目录是 Git 仓库
3. 确认远端和 SSH 可用
4. 确认 webhook 已配置
5. 切换到目标目录
6. 执行脚本
7. 汇报结果

## 定时自动备份

如果主人要求开启自动备份，你可以建议使用 `crontab`。

示例：每小时执行一次

```bash
0 * * * * cd ~/.openclaw && /usr/bin/python3 /Users/dewei/Documents/demo/openclaw_plus/claw_backup/claw_backup.py >> ~/.openclaw_backup.log 2>&1
```

在写入定时任务前，先向主人确认：

- 是否真的需要自动备份
- 备份频率
- 日志输出位置
- 是否允许自动推送远端仓库

## 遇到账号或权限配置时的处理规则

如果你需要以下任一信息，必须向主人询问：

- GitHub / GitLab 仓库地址
- 仓库账号归属
- SSH key 选择
- 飞书 webhook 地址
- 默认分支
- 定时任务频率
- 是否允许自动推送

不要自行编造账号信息、仓库地址、Webhook 或密钥配置。

## 交付标准

当你完成此任务时，应满足以下结果：

- 备份脚本配置完成
- 能在 `~/.openclaw` 或主人指定目录正常执行
- 远端推送正常
- webhook 正常
- 已整理为可复用的 skill
- 若主人要求，定时任务已配置完成
