# 飞书命令执行审批功能实现文档

## 背景

OpenClaw 原生不支持飞书渠道的命令执行审批（chat exec approvals）。当 Agent 需要执行高权限命令时，飞书会返回：

> Exec approval is required, but Feishu does not support chat exec approvals.

Telegram 和 Discord 已原生支持此功能，但飞书插件中缺少相关实现。

---

## 架构理解（必读）

### 飞书的消息回复路径与其他渠道不同

**Telegram / Discord**：走 `deliverOutboundPayloads → deliverOutboundPayloadsCore → handler.sendPayload()`

**飞书**：走 `createFeishuReplyDispatcher（reply-dispatcher.ts）→ deliver()` 函数

这是关键区别。`deliverOutboundPayloadsCore` 中的 `sendPayload` 检测逻辑对飞书**完全无效**，因为飞书从不经过那条路径。所有对 outbound adapter 的 `sendPayload` 方法的拦截，在飞书场景下不会被触发。

### exec approval payload 的产生位置

`dist/reply-Bm8VrLQh.js` 中的 `buildExecApprovalPendingReplyPayload()` 构建如下 payload：

```js
{
  text: "Approval required.\n\nRun:\n\n```txt\n/approve <id> allow-once\n```\n\nPending command:\n\n```sh\n<command>\n```\n\n...",
  channelData: {
    execApproval: {
      approvalId: "...",
      approvalSlug: "...",
      allowedDecisions: ["allow-once", "allow-always", "deny"]
    }
  }
}
```

注意：`channelData.execApproval` 里**没有** `command` 字段，命令需要从 `text` 中用正则提取。

### resolveExecApprovalInitiatingSurfaceState 的飞书分支

这里原先判断错了。当前实际版本里，`dist/reply-Bm8VrLQh.js` 的 `resolveExecApprovalInitiatingSurfaceState()` **没有飞书分支**，只处理了 `telegram` 和 `discord`，其他渠道都会落到：

```js
return {
  kind: "unsupported",
  channel,
  channelLabel,
};
```

这正是飞书仍然提示：

> Exec approval is required, but Feishu does not support chat exec approvals.

所以 **必须 patch `dist/reply-Bm8VrLQh.js`**，给 `feishu` 增加 `enabled/disabled` 判定分支；仅修改 `openclaw.json` 不够。

### Gateway resolve 机制

这里之前也判断错了。当前实际版本的 `dist/gateway-cli-Ol-vpIk7.js` **没有**监听 `__openclaw_feishu_resolve_approval__` 这个进程内事件。

现象就是：

- 飞书按钮点击能回调到 `card-action.ts`
- 卡片能更新成绿色/红色
- 但系统侧 `exec.approval.waitDecision` 一直收不到 resolve，最终超时

所以 **必须 patch `dist/gateway-cli-Ol-vpIk7.js`**，注册：

```js
process.on("__openclaw_feishu_resolve_approval__", async (payload) => {
  await callGateway({
    method: "exec.approval.resolve",
    params: { id: payload.id, decision: payload.decision },
    timeoutMs: 10000,
  });
});
```

---

## 需要修改的文件清单

主要文件路径前缀：`/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/`

| 文件 | 改动类型 | 说明 |
|------|----------|------|
| `channel.ts` | 新增 | 添加 `execApprovals` adapter（`getInitiatingSurfaceState` + `buildPendingPayload`），声明插件支持审批 |
| `outbound.ts` | 新增 | 添加 `sendPayload` 方法（虽然飞书不走这条路，但保留以备将来）；新增 export `buildFeishuExecApprovalCard`；将 `_approvalCardMessageIds` 改为存储 `{ messageId, command }` |
| `reply-dispatcher.ts` | 修改核心 | 在 `deliver()` 函数开头拦截 `channelData.execApproval`，调用 `sendCardFeishu` 发送审批卡片 |
| `card-ux-exec-approval.ts` | 新增文件 | 审批卡片模板（pending / resolved 两种状态）|
| `card-action.ts` | 修改 | 按钮点击时 emit 进程内事件；更新卡片为已解析状态 |
| `dist/reply-Bm8VrLQh.js` | 必改 | 给 `resolveExecApprovalInitiatingSurfaceState()` 增加 `feishu` 分支，否则框架仍判定为 unsupported |
| `dist/gateway-cli-Ol-vpIk7.js` | 必改 | 注册 `__openclaw_feishu_resolve_approval__` 监听器，把飞书按钮回调真正转成 `exec.approval.resolve` |
| `monitor.account.ts` | 无需改动 | — |

---

## 各文件详细实现

### 1. `channel.ts` — 声明插件审批能力

在 `feishuPlugin` 对象中添加 `execApprovals` adapter（位于 `security` 块之后、`setup` 块之前）：

```typescript
import { createExecApprovalPendingCard } from "./card-ux-exec-approval.js";

execApprovals: {
  getInitiatingSurfaceState: ({ cfg, accountId }) => {
    const account = resolveFeishuAccount({ cfg, accountId });
    const feishuCfg = account.config as Record<string, unknown>;
    const execCfg = feishuCfg.execApprovals as {
      enabled?: boolean;
      approvers?: Array<string | number>;
    } | undefined;
    if (!execCfg?.enabled) return { kind: "disabled" as const };
    const approvers = (execCfg.approvers ?? []).map(String).filter(Boolean);
    if (approvers.length === 0) return { kind: "disabled" as const };
    return { kind: "enabled" as const };
  },
  buildPendingPayload: ({ request, nowMs }) => {
    return {
      card: createExecApprovalPendingCard({
        approvalId: request.id,
        command: request.request.command,
        cwd: request.request.cwd,
        host: request.request.host === "node" ? "node" : "gateway",
        expiresAtMs: request.expiresAtMs,
        nowMs,
      }),
      msgType: "interactive",
    };
  },
},
```

> **注意**：`buildPendingPayload` 返回的 `card` 字段在飞书场景下**不会被使用**——飞书走 `reply-dispatcher.ts` 路径，审批卡片在那里直接构建和发送。此 adapter 的作用是让框架层认为飞书"支持审批"，从而生成 `channelData.execApproval` 并调用 `onToolResult`。

---

### 2. `card-ux-exec-approval.ts` — 卡片模板（新建文件）

提供两个函数：

**`createExecApprovalPendingCard(params)`** — 橙色 header，含命令详情和两个按钮：

```typescript
export function createExecApprovalPendingCard(params: {
  approvalId: string;
  command: string;
  cwd?: string;
  host: string;
  expiresAtMs: number;
  nowMs?: number;
}): Record<string, unknown> {
  const nowMs = params.nowMs ?? Date.now();
  const approvalSlug = params.approvalId.slice(0, 8);
  const infoLines: string[] = [];
  infoLines.push(`**Command:**\n\`\`\`\n${params.command}\n\`\`\``);
  if (params.cwd) infoLines.push(`**Directory:** ${params.cwd}`);
  infoLines.push(`**Host:** ${params.host}`);
  infoLines.push(`**Expires in:** ${formatExpiresInMs(params.expiresAtMs, nowMs)}`);
  infoLines.push(`**ID:** \`${approvalSlug}\``);

  return {
    schema: "2.0",
    config: { wide_screen_mode: true, update_multi: true },
    header: {
      title: { tag: "plain_text", content: "Approval Required" },
      template: "orange",
    },
    body: {
      elements: [
        { tag: "markdown", content: infoLines.join("\n") },
        {
          tag: "column_set",           // ← 飞书 Schema V2 用 column_set，不是 action/actions
          columns: [
            {
              tag: "column", width: "auto",
              elements: [{
                tag: "button",
                text: { tag: "plain_text", content: "Allow Once" },
                type: "primary",
                behaviors: [{ type: "callback", value: { approvalId: params.approvalId, action: "approve", decision: "allow-once" } }],
              }],
            },
            {
              tag: "column", width: "auto",
              elements: [{
                tag: "button",
                text: { tag: "plain_text", content: "Deny" },
                type: "danger",
                behaviors: [{ type: "callback", value: { approvalId: params.approvalId, action: "deny", decision: "deny" } }],
              }],
            },
          ],
        },
      ],
    },
  };
}
```

**`createExecApprovalResolvedCard(params)`** — 绿色（批准）或红色（拒绝）卡片：

```typescript
export function createExecApprovalResolvedCard(params: {
  command: string;
  decision: string;
}): Record<string, unknown> {
  const isApproved = params.decision === "allow-once" || params.decision === "allow-always";
  return {
    schema: "2.0",
    config: { wide_screen_mode: true },
    header: {
      title: { tag: "plain_text", content: isApproved ? "Approval: Allowed" : "Approval: Denied" },
      template: isApproved ? "green" : "red",
    },
    body: {
      elements: [
        { tag: "markdown", content: `**Command:**\n\`\`\`\n${params.command}\n\`\`\`` },
      ],
    },
  };
}
```

#### 飞书 Schema V2 卡片格式关键注意点

| 场景 | 错误写法 | 正确写法 |
|------|----------|----------|
| 按钮容器 | `tag: "action"` 或 `tag: "actions"` | `tag: "column_set"` + 每个按钮放在 `column` 里 |
| 按钮点击回调 | `value: {...}` 直接放在 button 里 | `behaviors: [{ type: "callback", value: {...} }]` |

---

### 3. `outbound.ts` — 修改

**将 `_approvalCardMessageIds` 改为存储 `{ messageId, command }`**：

```typescript
// 改为存储 { messageId, command }，供 card-action.ts 更新卡片时使用
export const _approvalCardMessageIds = new Map<string, { messageId: string; command: string }>();
```

**将 `buildFeishuExecApprovalCard` 改为 export**（飞书主路径用不到，但 sendPayload 降级路径需要）：

```typescript
export function buildFeishuExecApprovalCard(approvalId: string, bodyText: string): Record<string, unknown> {
  // 同 card-ux-exec-approval.ts 的格式（column_set + behaviors）
  return { ... };
}
```

**在 `sendPayload` 中提取 command 并存入 map**（如果走这条路径）：

```typescript
const commandMatch = ctx.text?.match(/Pending command:\n\n```sh\n([\s\S]*?)\n```/);
const command = commandMatch?.[1]?.trim() ?? "";
_approvalCardMessageIds.set(execApproval.approvalId, { messageId: result.messageId, command });
```

---

### 4. `reply-dispatcher.ts` — 核心修改（飞书审批的真正触发点）

**新增 import**：

```typescript
import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";
import { _approvalCardMessageIds, buildFeishuExecApprovalCard } from "./outbound.js";
```

**在 `deliver()` 函数开头插入拦截逻辑**：

```typescript
deliver: async (payload: ReplyPayload, info) => {
  // ---- exec approval card interception ----
  const execApproval = (payload as any).channelData?.execApproval as { approvalId?: string; command?: string } | undefined;
  if (execApproval?.approvalId && payload.text) {
    // command 不在 channelData 里，从 text 正则提取
    // text 格式：... "Pending command:\n\n```sh\n<cmd>\n```" ...（双换行）
    const commandMatch = payload.text.match(/Pending command:\n\n```sh\n([\s\S]*?)\n```/);
    const command = execApproval.command ?? commandMatch?.[1]?.trim() ?? "";
    const card = buildFeishuExecApprovalCard(execApproval.approvalId, payload.text);
    try {
      const result = await sendCardFeishu({ cfg, to: chatId, card, accountId });
      _approvalCardMessageIds.set(execApproval.approvalId, { messageId: result.messageId, command });
      const id = execApproval.approvalId;
      setTimeout(() => _approvalCardMessageIds.delete(id), 15 * 60 * 1000);
    } catch (err) {
      params.runtime.error?.(`feishu[${account.accountId}]: exec approval card send failed: ${String(err)}`);
    }
    return;  // 不走普通文本发送逻辑
  }
  // ---- end exec approval interception ----

  const text = payload.text ?? "";
  // ... 原有逻辑不变 ...
```

---

### 4.5 `dist/reply-Bm8VrLQh.js` — 必须补飞书分支

如果这一步不做，前面所有 `src` 层 patch 都不会进入执行链路，因为框架层会先认定飞书不支持审批。

把 `resolveExecApprovalInitiatingSurfaceState()` 里的 `discord` 分支后面补上：

```js
if (channel === "feishu") {
  const feishuCfg = cfg.channels?.feishu;
  const execApprovals = feishuCfg?.execApprovals;
  const enabled = execApprovals?.enabled === true;
  const hasApprovers = Array.isArray(execApprovals?.approvers) && execApprovals.approvers.length > 0;
  return enabled && hasApprovers
    ? { kind: "enabled", channel, channelLabel }
    : { kind: "disabled", channel, channelLabel };
}
```

---

### 5. `card-action.ts` — 按钮点击处理

在 `handleFeishuCardAction` 中，识别到 `approvalId` 后：

```typescript
// 1. 触发进程内事件 → gateway-cli bundle 监听器调用 exec.approval.resolve
(process as NodeJS.EventEmitter).emit("__openclaw_feishu_resolve_approval__", { id: approvalId, decision });

// 2. 取出 command 并更新卡片
const messageId = _approvalCardMessageIds.get(approvalId)?.messageId;
const command = _approvalCardMessageIds.get(approvalId)?.command ?? "";
_approvalCardMessageIds.delete(approvalId);
const resolvedCard = createExecApprovalResolvedCard({ command, decision });

const { sendCardFeishu, updateCardFeishu } = await import("./send.js");
if (messageId) {
  await updateCardFeishu({ cfg, messageId, card: resolvedCard, accountId: account.accountId }).catch(...);
} else {
  // 降级：发新消息
  await sendCardFeishu({ cfg, to: chatId, card: resolvedCard, accountId: account.accountId }).catch(...);
}
```

---

### 5.5 `dist/gateway-cli-Ol-vpIk7.js` — 把 emit 接到真实审批 resolve

在 gateway 启动初始化阶段（`execApprovalHandlers` 创建后）补监听器：

```js
if (!globalThis.__openclawFeishuExecApprovalListenerRegistered) {
  globalThis.__openclawFeishuExecApprovalListenerRegistered = true;
  process.on("__openclaw_feishu_resolve_approval__", async (payload) => {
    try {
      const id = payload?.id != null ? String(payload.id) : "";
      const decision = payload?.decision != null ? String(payload.decision) : "";
      if (!id || !decision) return;
      await callGateway({
        method: "exec.approval.resolve",
        params: { id, decision },
        timeoutMs: 1e4,
      });
      log.info(`exec approvals: feishu resolved ${id} decision=${decision}`);
    } catch (err) {
      log.error(`exec approvals: feishu resolve failed: ${String(err)}`);
    }
  });
}
```

这个 patch 的作用是把 `card-action.ts` 里发出的：

```ts
(process as NodeJS.EventEmitter).emit("__openclaw_feishu_resolve_approval__", {
  id: approvalId,
  decision,
});
```

真正接到 gateway 的审批系统上。

---

## 完整审批流程

```
飞书用户发消息（如：运行 curl https://example.com）
  → Agent 生成 exec 工具调用
  → resolveExecApprovalInitiatingSurfaceState("feishu") 读取 cfg，返回 { kind: "enabled" }
  → createAndRegisterDefaultExecApprovalRequest 向 Gateway 注册审批，等待 waitDecision
  → emitToolResultOutput → buildExecApprovalPendingReplyPayload 构建 payload
    （payload.text 含命令文本，payload.channelData.execApproval 含 approvalId）
  → onToolResult(payload) → resolveToolDeliveryPayload 检测到 channelData.execApproval，放行
  → dispatcher.sendToolResult(payload) → enqueue → deliver(payload, { kind: "tool" })
  → reply-dispatcher.ts deliver() 开头拦截 channelData.execApproval
  → sendCardFeishu 发送橙色审批卡片（column_set + button）
  → 记录 approvalId → { messageId, command }

  用户点击「Allow Once」→ 飞书发送 card.action.trigger 事件（WebSocket）
  → handleFeishuCardAction 识别 approvalId + action="approve"
  → process.emit("__openclaw_feishu_resolve_approval__", { id, decision: "allow-once" })
  → gateway-cli-Ol-vpIk7.js 监听器调用 callGateway exec.approval.resolve（回环到本地 Gateway）
  → Gateway 解除 exec.approval.waitDecision 阻塞，Agent 继续执行
  → updateCardFeishu 将卡片更新为绿色「Approval: Allowed」状态
```

---

## 从零重装后一键复刻 Checklist

下面这份 checklist 的目标是：**在一个全新的 openclaw 环境里，不查任何别的资料，照着做一次性复刻成功。**

### A. 前置确认

- [ ] openclaw 已安装，安装路径为：`/opt/homebrew/lib/node_modules/openclaw/`
- [ ] 飞书扩展目录存在：`/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/`
- [ ] 当前运行的 gateway bundle 是：`/opt/homebrew/lib/node_modules/openclaw/dist/gateway-cli-Ol-vpIk7.js`
- [ ] 当前 reply bundle 是：`/opt/homebrew/lib/node_modules/openclaw/dist/reply-Bm8VrLQh.js`
- [ ] `openclaw.json` 里已配置飞书账号，并启用：

```json
{
  "channels": {
    "feishu": {
      "enabled": true,
      "appId": "cli_xxx",
      "appSecret": "xxx",
      "connectionMode": "websocket",
      "execApprovals": {
        "enabled": true,
        "approvers": ["ou_xxx"]
      }
    }
  }
}
```

> `approvers` 这里只要非空即可；当前实现不是把卡片 DM 给 approvers，而是把卡片发回触发审批的飞书会话。

---

### B. 你需要修改/新增的文件（这 5 个 + 2 个 dist 文件是必须的）

- [ ] `extensions/feishu/src/channel.ts`
- [ ] `extensions/feishu/src/card-ux-exec-approval.ts`（新建）
- [ ] `extensions/feishu/src/outbound.ts`
- [ ] `extensions/feishu/src/reply-dispatcher.ts`
- [ ] `extensions/feishu/src/card-action.ts`
- [ ] `dist/reply-Bm8VrLQh.js`
- [ ] `dist/gateway-cli-Ol-vpIk7.js`

### C. 可选但建议同步修改的文件

- [ ] 无

> `outbound.ts` 在当前这轮修复里已经不是可选项，因为 `reply-dispatcher.ts` 依赖它导出的 `_approvalCardMessageIds` 和 `buildFeishuExecApprovalCard`。

---

### D. 核心原理确认（做之前先记住）

- [ ] 飞书**不走** `deliverOutboundPayloadsCore.sendPayload`
- [ ] 飞书实际走：`createFeishuReplyDispatcher()` → `deliver()`
- [ ] 审批卡片真正要拦截的位置：`reply-dispatcher.ts` 的 `deliver()` 函数开头
- [ ] `channelData.execApproval` **没有 command 字段**，必须从 `payload.text` 里提取
- [ ] 飞书 Schema V2 **不能用** `action` / `actions` 作为按钮容器，必须用 `column_set`

---

### E. 逐文件复刻步骤

#### 1) `channel.ts`

- [ ] 引入：

```typescript
import { createExecApprovalPendingCard } from "./card-ux-exec-approval.js";
```

- [ ] 在 `feishuPlugin` 中新增 `execApprovals`：

```typescript
execApprovals: {
  getInitiatingSurfaceState: ({ cfg, accountId }) => {
    const account = resolveFeishuAccount({ cfg, accountId });
    const feishuCfg = account.config as Record<string, unknown>;
    const execCfg = feishuCfg.execApprovals as {
      enabled?: boolean;
      approvers?: Array<string | number>;
    } | undefined;
    if (!execCfg?.enabled) return { kind: "disabled" as const };
    const approvers = (execCfg.approvers ?? []).map(String).filter(Boolean);
    if (approvers.length === 0) return { kind: "disabled" as const };
    return { kind: "enabled" as const };
  },
  buildPendingPayload: ({ request, nowMs }) => {
    return {
      card: createExecApprovalPendingCard({
        approvalId: request.id,
        command: request.request.command,
        cwd: request.request.cwd,
        host: request.request.host === "node" ? "node" : "gateway",
        expiresAtMs: request.expiresAtMs,
        nowMs,
      }),
      msgType: "interactive",
    };
  },
},
```

- [ ] 作用确认：这一步的目的不是直接发卡，而是让框架层认定飞书“支持审批”。

#### 2) 新建 `card-ux-exec-approval.ts`

- [ ] 新建两个函数：
  - `createExecApprovalPendingCard`
  - `createExecApprovalResolvedCard`

- [ ] pending 卡片必须满足：
  - `schema: "2.0"`
  - `header.template: "orange"`
  - 正文是 markdown
  - 按钮区使用 `column_set`
  - 每个按钮使用 `behaviors: [{ type: "callback", value: {...} }]`

- [ ] 使用下面这份完整实现：

```typescript
export function createExecApprovalPendingCard(params: {
  approvalId: string;
  command: string;
  cwd?: string;
  host: string;
  expiresAtMs: number;
  nowMs?: number;
}): Record<string, unknown> {
  const nowMs = params.nowMs ?? Date.now();
  const approvalSlug = params.approvalId.slice(0, 8);
  const infoLines: string[] = [];
  infoLines.push(`**Command:**\n\`\`\`\n${params.command}\n\`\`\``);
  if (params.cwd) infoLines.push(`**Directory:** ${params.cwd}`);
  infoLines.push(`**Host:** ${params.host}`);
  infoLines.push(`**Expires in:** ${formatExpiresInMs(params.expiresAtMs, nowMs)}`);
  infoLines.push(`**ID:** \`${approvalSlug}\``);

  return {
    schema: "2.0",
    config: { wide_screen_mode: true, update_multi: true },
    header: {
      title: { tag: "plain_text", content: "Approval Required" },
      template: "orange",
    },
    body: {
      elements: [
        { tag: "markdown", content: infoLines.join("\n") },
        {
          tag: "column_set",
          columns: [
            {
              tag: "column",
              width: "auto",
              elements: [{
                tag: "button",
                text: { tag: "plain_text", content: "Allow Once" },
                type: "primary",
                behaviors: [{ type: "callback", value: { approvalId: params.approvalId, action: "approve", decision: "allow-once" } }],
              }],
            },
            {
              tag: "column",
              width: "auto",
              elements: [{
                tag: "button",
                text: { tag: "plain_text", content: "Deny" },
                type: "danger",
                behaviors: [{ type: "callback", value: { approvalId: params.approvalId, action: "deny", decision: "deny" } }],
              }],
            },
          ],
        },
      ],
    },
  };
}

export function createExecApprovalResolvedCard(params: {
  command: string;
  decision: string;
}): Record<string, unknown> {
  const isApproved = params.decision === "allow-once" || params.decision === "allow-always";
  return {
    schema: "2.0",
    config: { wide_screen_mode: true },
    header: {
      title: {
        tag: "plain_text",
        content: isApproved ? "Approval: Allowed" : "Approval: Denied",
      },
      template: isApproved ? "green" : "red",
    },
    body: {
      elements: [
        {
          tag: "markdown",
          content: `**Command:**\n\`\`\`\n${params.command}\n\`\`\``,
        },
      ],
    },
  };
}
```

#### 3) `reply-dispatcher.ts`（最关键）

- [ ] 新增 import：

```typescript
import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";
import { _approvalCardMessageIds, buildFeishuExecApprovalCard } from "./outbound.js";
```

- [ ] 在 `deliver: async (payload, info) => { ... }` 开头插入拦截：

```typescript
const execApproval = (payload as any).channelData?.execApproval as { approvalId?: string; command?: string } | undefined;
if (execApproval?.approvalId && payload.text) {
  const commandMatch = payload.text.match(/Pending command:\n\n```sh\n([\s\S]*?)\n```/);
  const command = execApproval.command ?? commandMatch?.[1]?.trim() ?? "";
  const card = buildFeishuExecApprovalCard(execApproval.approvalId, payload.text);
  try {
    const result = await sendCardFeishu({ cfg, to: chatId, card, accountId });
    _approvalCardMessageIds.set(execApproval.approvalId, { messageId: result.messageId, command });
    const id = execApproval.approvalId;
    setTimeout(() => _approvalCardMessageIds.delete(id), 15 * 60 * 1000);
  } catch (err) {
    params.runtime.error?.(`feishu[${account.accountId}]: exec approval card send failed: ${String(err)}`);
  }
  return;
}
```

- [ ] 注意：这里正则一定要写成 **`Pending command:\n\n```sh`**，中间是双换行。

#### 4) `card-action.ts`

- [ ] 识别按钮回调中的 `approvalId` / `action`
- [ ] emit 进程内事件：

```typescript
(process as NodeJS.EventEmitter).emit("__openclaw_feishu_resolve_approval__", {
  id: approvalId,
  decision,
});
```

- [ ] 更新已解析卡片时，必须从 map 中拿 command：

```typescript
const messageId = _approvalCardMessageIds.get(approvalId)?.messageId;
const command = _approvalCardMessageIds.get(approvalId)?.command ?? "";
_approvalCardMessageIds.delete(approvalId);
const resolvedCard = createExecApprovalResolvedCard({ command, decision });
```

#### 5) `outbound.ts`（建议同步）

- [ ] `_approvalCardMessageIds` 改为：

```typescript
export const _approvalCardMessageIds = new Map<string, { messageId: string; command: string }>();
```

- [ ] `buildFeishuExecApprovalCard` 改为 `export function`
- [ ] 卡片按钮结构同步用 `column_set`
- [ ] 如果 `sendPayload` 里要记录 command，也用同样正则：

```typescript
const commandMatch = ctx.text?.match(/Pending command:\n\n```sh\n([\s\S]*?)\n```/);
const command = commandMatch?.[1]?.trim() ?? "";
```

---

### F. 明确哪些文件不要改

- [ ] 必须 patch `dist/reply-Bm8VrLQh.js`
- [ ] 不要再去 patch `dist/gateway-cli-Ol-vpIk7.js`
- [ ] 不要再去找 `deliverOutboundPayloadsCore.sendPayload` 为什么没触发——飞书本来就不走这条路
- [ ] 不要使用 `action` / `actions` 作为 V2 卡片按钮容器

---

### G. 重装后的最短验证路径

#### 验证 1：配置生效
- [ ] 启动 gateway
- [ ] 确认日志里飞书 provider 正常启动，无 import 错误

#### 验证 2：审批触发
- [ ] 在飞书客户端发送：`运行 curl https://example.com`
- [ ] 日志应出现：
  - `elevated command curl -s https://example.com`
  - 不再出现 `Feishu does not support chat exec approvals`
  - 进入 `exec.approval.waitDecision`

#### 验证 3：卡片发送成功
- [ ] 飞书收到橙色审批卡片
- [ ] 卡片里显示 Command / Directory / Host / Expires / ID
- [ ] 两个按钮分别是 `Allow Once` 和 `Deny`

#### 验证 4：批准路径
- [ ] 点击 `Allow Once`
- [ ] 日志应出现：
  - `exec approval allow-once for <id>`
  - `emitted resolve for <id> decision=allow-once`
  - `exec approvals: feishu resolved <id> decision=allow-once`
- [ ] Agent 继续执行命令
- [ ] 卡片更新为绿色，Command 字段非空

#### 验证 5：拒绝路径
- [ ] 再触发一次审批，点击 `Deny`
- [ ] 日志应出现：
  - `exec approval deny for <id>`
  - `emitted resolve for <id> decision=deny`
  - `exec approvals: feishu resolved <id> decision=deny`
- [ ] 卡片更新为红色，Command 字段非空

---

### H. 故障速查（出现问题时按这个顺序排）

#### 现象 1：完全没有审批提示
- 看日志有没有 `Exec approval is required, but Feishu does not support chat exec approvals`
  - 有 → 先查 `dist/reply-Bm8VrLQh.js` 是否已 patch 成功
  - 没有 → 继续看下一条
- 看有没有 `reply-dispatcher deliver: sending exec approval card`
  - 没有 → 说明 `reply-dispatcher.ts` 的拦截没生效
  - 有 → 继续看飞书 API 错误

#### 现象 2：飞书返回 400
- `unsupported tag action` → 你用了 `tag: "action"`
- `not support tag: actions` → 你用了 `tag: "actions"`
- 正确结构是 `column_set`

#### 现象 3：点击按钮没反应
- 看有没有 `exec approval allow-once/deny for <id>`
  - 没有 → `card-action.ts` 没收到 callback 或 `behaviors` 配错
- 有但没 `feishu resolved <id>`
  - 说明 `process.emit("__openclaw_feishu_resolve_approval__")` 没被 gateway listener 接上，优先检查 `dist/gateway-cli-Ol-vpIk7.js` 是否已 patch

#### 现象 4：已解析卡片里 Command 为空
- 先看 `reply-dispatcher.ts` 的 command 提取正则是否是双换行版本
- 再看 `_approvalCardMessageIds` 是否还是 `Map<string, string>`，如果是，说明没改成对象结构
- 再看 `card-action.ts` 是否仍然写着 `command: ""`

---

### I. 重装后最终自检结论

满足下面 6 条，就说明复刻成功：

- [ ] 飞书消息能正常触发 exec approval
- [ ] 飞书能收到审批卡片
- [ ] 按钮点击能回调到 `card-action.ts`
- [ ] `process.emit("__openclaw_feishu_resolve_approval__")` 能解除 waitDecision
- [ ] 允许路径正常继续执行命令
- [ ] 拒绝路径正常更新红色卡片，且 Command 非空

---

## 卡片样式修改指南

所有卡片样式集中在一个文件：

**`extensions/feishu/src/card-ux-exec-approval.ts`**

### 审批中卡片（`createExecApprovalPendingCard`）

| 要修改的项 | 对应字段 |
|-----------|---------|
| 标题文字 | `header.title.content` |
| 标题颜色 | `header.template`（可选值：`orange` `red` `green` `blue` `yellow` `grey`） |
| 正文内容/排版 | `body.elements[0].content`（markdown 格式） |
| 按钮文字 | 各 `button.text.content` |
| 按钮颜色 | `button.type`（`primary`=蓝、`danger`=红、`default`=灰） |
| 按钮布局 | `column_set.columns` 数组，每个 `column` 一个按钮；`width: "auto"` 自适应，`"weighted"` 按比例 |
| 回调数据 | `behaviors[0].value`，点击后原样传回 `event.action.value` |

### 已解析卡片（`createExecApprovalResolvedCard`）

| 要修改的项 | 对应字段 |
|-----------|---------|
| 批准/拒绝标题 | `header.title.content`（当前：`"Approval: Allowed"` / `"Approval: Denied"`） |
| 批准颜色 | `header.template` 当 `isApproved` 时（当前 `"green"`） |
| 拒绝颜色 | `header.template` 当 `!isApproved` 时（当前 `"red"`） |
| 正文内容 | `body.elements[0].content` |

### 审批中卡片的正文来源

`createExecApprovalPendingCard` 显示的是结构化的命令信息（command、cwd、host、expires）。

`outbound.ts` 中的 `buildFeishuExecApprovalCard`（降级路径）显示的是框架原始文本（`payload.text`，包含 `/approve` 命令等）。

**飞书实际走的是 `createExecApprovalPendingCard` 路径**（在 `reply-dispatcher.ts` 中调用），所以改 `card-ux-exec-approval.ts` 即可看到效果。



### 坑 1：飞书走不同的 deliver 路径
- `outbound.sendPayload` 只在 `deliverOutboundPayloads` 路径触发，飞书使用 `createFeishuReplyDispatcher`，完全绕过
- **解法**：在 `reply-dispatcher.ts` 的 `deliver()` 中直接拦截

### 坑 2：飞书 Schema V2 按钮容器 tag
- `"action"`：Schema V1 用法，V2 报错 `200861 unsupported tag action`
- `"actions"`：同样不支持，报错 `200621 not support tag: actions`
- **正确写法**：`"column_set"` + `"column"` 结构

### 坑 3：按钮点击回调字段
- Schema V2 中按钮 click 回调用 `behaviors: [{ type: "callback", value: {...} }]`
- 回调触发后，`event.action.value` 就是 `value` 对象

### 坑 4：command 字段不在 channelData 里
- `channelData.execApproval` 只有 `approvalId`/`approvalSlug`/`allowedDecisions`
- command 需要从 `payload.text` 正则提取，格式为 `Pending command:\n\n\`\`\`sh\n<cmd>\n\`\`\``（**双换行**）

### 坑 5：_approvalCardMessageIds 类型
- 原本 `Map<string, string>`（只存 messageId）
- 需改为 `Map<string, { messageId: string; command: string }>` 以便 card-action.ts 取到 command

### 坑 6：npm reinstall 覆盖
- `npm i -g openclaw` 会覆盖所有修改
- **每次重装后需要重新打全部补丁**（约 5 个文件）

---

## openclaw.json 配置

```json
{
  "channels": {
    "feishu": {
      "enabled": true,
      "appId": "cli_xxx",
      "appSecret": "xxx",
      "connectionMode": "websocket",
      "execApprovals": {
        "enabled": true,
        "approvers": ["ou_xxx"]
      }
    }
  }
}
```

`approvers` 字段只要非空，`getInitiatingSurfaceState` 就返回 `enabled`。字段值实际上不用于路由（飞书的审批卡片发送到触发命令的会话，不是发给 approvers 列表中的人）。

---

## 验证方法

1. 重启 openclaw gateway，确认日志无报错
2. 在飞书客户端发送：`运行 curl https://example.com`
3. 日志应出现：`elevated command curl ...` 和 `[feishu-debug] reply-dispatcher deliver: sending exec approval card`
4. 飞书收到橙色带按钮审批卡片
5. 点击「Allow Once」
6. 日志出现：`emitted resolve for <id>` → `exec approvals: feishu resolved <id> decision=allow-once`
7. Agent 继续执行，卡片更新为绿色「Approval: Allowed」

---

## 不需要修改的文件

- `dist/reply-Bm8VrLQh.js` — 当前版本里飞书 `resolveExecApprovalInitiatingSurfaceState` 分支不存在，必须 patch
- `dist/gateway-cli-Ol-vpIk7.js` — 当前版本里飞书审批事件监听器不存在，必须 patch
- `monitor.account.ts` — 无需改动
- `exec-approval-handler.ts` — 无需改动（如果存在则忽略）
