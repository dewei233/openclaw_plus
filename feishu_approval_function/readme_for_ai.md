# feishu approval for AI

本说明的读者是 OpenClaw 的 AI 助手，不是最终用户。

你的任务是替主人为 OpenClaw 增加飞书命令执行审批功能，使 OpenClaw 在飞书中遇到高权限命令时，不再报：

```text
Exec approval is required, but Feishu does not support chat exec approvals.
```

参考材料：

- [`setup_doc.md`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup_doc.md)
- [`setup.sh`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup.sh)

## 你的目标

你需要完成以下结果：

1. OpenClaw 飞书渠道支持 exec approval
2. 飞书内可以收到审批卡片
3. 用户点击“允许一次”或“拒绝”后，系统能真正 resolve 审批
4. 审批结果能反馈回 OpenClaw，不再一直超时
5. 配置被整理成稳定、可重复执行的安装流程

## 实现原则

你不要只改配置文件。这个功能需要同时修改 OpenClaw 的飞书扩展源码和 `dist` 产物。

关键事实：

- 飞书回复链路不走 Telegram / Discord 的 `sendPayload` 主路径
- 仅修改 `openclaw.json` 不够
- 仅让卡片显示出来也不够
- 必须让按钮点击最终转成 `exec.approval.resolve`

如果你只做了卡片展示，但没有打通 resolve 链路，表现会是：

- 飞书卡片能显示
- 点击按钮后卡片可能变绿或变红
- 但 OpenClaw 内部审批仍然超时

## 优先执行方式

优先复用现成脚本：

[`setup.sh`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup.sh)

如果目标环境和脚本假设一致，应优先运行这个脚本，而不是手工逐个改文件。

仅在以下场景才改为手工 patch：

- OpenClaw 安装路径不一致
- 上游版本变更导致脚本 patch 位置失效
- 主人要求你审阅并定制 patch 内容

## 你需要修改的范围

根据参考实现，至少要覆盖这些文件：

- `extensions/feishu/src/channel.ts`
- `extensions/feishu/src/outbound.ts`
- `extensions/feishu/src/reply-dispatcher.ts`
- `extensions/feishu/src/card-action.ts`
- `extensions/feishu/src/card-ux-exec-approval.ts`
- `dist/reply-*.js`
- `dist/gateway-cli-*.js`

其中最容易漏掉、但实际上必须改的是：

- `dist/reply-*.js`
- `dist/gateway-cli-*.js`

## 标准实施步骤

### 1. 定位 OpenClaw 安装目录

你需要先确认当前机器的 OpenClaw 安装位置，例如通过：

- `npm root -g`
- `yarn global dir`
- `pnpm root -g`

脚本默认面向全局安装的 OpenClaw。

如果机器上没有安装 OpenClaw，先向主人确认是否允许安装，以及要操作哪个环境。

### 2. 备份原文件

在修改任何 OpenClaw 安装目录下的文件前，先备份原文件。

至少要备份：

- `extensions/feishu/src/*`
- `dist/reply-*.js`
- `dist/gateway-cli-*.js`

如果你使用 [`setup.sh`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup.sh)，它已经包含 `.bak` 备份逻辑。

### 3. 应用补丁

优先执行：

```bash
bash /Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup.sh
```

如果脚本失败，再根据 [`setup_doc.md`](/Users/dewei/Documents/demo/openclaw_plus/feishu_approval_function/setup_doc.md) 手工 patch。

### 4. 配置飞书审批开关

你需要确认 OpenClaw 配置里启用了飞书审批，例如：

```json
{
  "channels": {
    "feishu": {
      "execApprovals": {
        "enabled": true,
        "approvers": ["ou_placeholder"]
      }
    }
  }
}
```

如果 `enabled` 没开，或者 `approvers` 为空，框架仍会把飞书判为不支持审批。

### 5. 重启 OpenClaw / gateway

补丁生效后，必须重启对应进程。否则旧代码仍在内存里运行。

### 6. 进行端到端验证

你必须验证完整链路，而不是只看卡片能否发送。

最少要验证两种情况：

1. 允许一次
2. 拒绝

验证通过标准：

- 飞书里出现审批卡片
- 点击按钮后卡片更新为已通过或已拒绝
- OpenClaw 不再报 “Feishu does not support chat exec approvals”
- 原命令在允许后继续执行，或在拒绝后终止

## 你需要理解的关键技术点

### 飞书审批卡片的来源

飞书审批卡片不是走通用 outbound 主路径，而是在 `reply-dispatcher.ts` 中拦截 `channelData.execApproval` 后直接发送。

### 命令正文的来源

`channelData.execApproval` 里没有完整 `command` 字段，命令正文需要从 payload 的 `text` 里用正则提取。

### resolve 的关键补丁

按钮点击后不能只更新卡片，还必须 emit 进程内事件，并在 gateway 侧监听这个事件，转成：

```text
exec.approval.resolve
```

这一步缺失时，审批看起来像成功了，实际上内部仍在等待。

## 推荐的 Skill 设计

你应该把这项能力整理成一个 OpenClaw skill，供后续 AI 重复使用。

建议 skill 职责：

- 检测 OpenClaw 全局安装位置
- 备份原始文件
- 应用飞书审批 patch
- 检查配置里是否开启 `execApprovals`
- 提示或协助重启服务
- 执行验收测试

建议 skill 输入：

- OpenClaw 安装路径，可选
- 飞书审批 approver 列表
- 配置文件路径，可选
- 是否允许自动重启相关进程

建议 skill 输出：

- 补丁是否成功
- 修改了哪些文件
- 哪些配置仍待补全
- 是否已通过端到端验证

## 必须向主人确认的信息

遇到以下信息时，必须向主人询问，不能自行假设：

- OpenClaw 安装在哪个环境
- 是否允许修改全局安装目录
- 飞书账号对应的 `approvers` 应该填谁
- 飞书 App / Bot 是否已经配置完成
- OpenClaw 配置文件具体位置
- 是否允许重启 OpenClaw 或 gateway 进程
- 测试时可以执行哪些高权限命令

如果缺这些信息，不要编造账号、open_id、ou_id、app 凭据或审批人。

## 交付标准

任务完成时，应满足以下条件：

- 飞书渠道已被框架识别为支持 exec approval
- 飞书中可以收到审批卡片
- 点击审批按钮后能真正 resolve
- OpenClaw 不再出现飞书不支持审批的报错
- 相关配置已补齐
- 安装流程已沉淀为可重复执行的 skill 或脚本

## 失败时的排查顺序

如果功能没有生效，按这个顺序检查：

1. `execApprovals.enabled` 是否为 `true`
2. `approvers` 是否非空
3. `dist/reply-*.js` 是否已经 patch
4. `dist/gateway-cli-*.js` 是否已经 patch
5. 是否已重启 OpenClaw / gateway
6. 飞书卡片按钮回调是否真的触发
7. `exec.approval.resolve` 是否真的被调用
