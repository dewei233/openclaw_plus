#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf "%b\n" "${BLUE}[info]${NC}  $*"; }
ok()    { printf "%b\n" "${GREEN}[ok]${NC}    $*"; }
warn()  { printf "%b\n" "${YELLOW}[warn]${NC}  $*"; }
fail()  { printf "%b\n" "${RED}[error]${NC} $*"; exit 1; }

echo ""
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║   openclaw 飞书审批功能 patch 脚本            ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo ""

info "检查依赖..."
command -v node >/dev/null 2>&1 || fail "未找到 node，请先安装 Node.js"
ok "node $(node --version)"

info "定位 openclaw 安装路径..."

OPENCLAW_DIR=""

try_path() {
  local candidate="$1"
  if [ -n "$candidate" ] && [ -f "${candidate}/openclaw/package.json" ]; then
    OPENCLAW_DIR="${candidate}/openclaw"
  fi
}

if command -v npm >/dev/null 2>&1; then
  try_path "$(npm root -g 2>/dev/null || true)"
fi

if [ -z "$OPENCLAW_DIR" ] && command -v yarn >/dev/null 2>&1; then
  YARN_GLOBAL="$(yarn global dir 2>/dev/null || true)"
  try_path "${YARN_GLOBAL}/node_modules"
fi

if [ -z "$OPENCLAW_DIR" ] && command -v pnpm >/dev/null 2>&1; then
  try_path "$(pnpm root -g 2>/dev/null || true)"
fi

[ -z "$OPENCLAW_DIR" ] && fail "未找到 openclaw 安装目录，请先运行: npm install -g openclaw"

ok "openclaw 路径: $OPENCLAW_DIR"

VERSION=$(node -e "const fs=require('fs');console.log(JSON.parse(fs.readFileSync('${OPENCLAW_DIR}/package.json','utf8')).version)" 2>/dev/null || echo "unknown")
ok "openclaw 版本: $VERSION"

FEISHU_SRC="${OPENCLAW_DIR}/extensions/feishu/src"
REPLY_DIST="${OPENCLAW_DIR}/dist/reply-Bm8VrLQh.js"
GATEWAY_DIST="${OPENCLAW_DIR}/dist/gateway-cli-Ol-vpIk7.js"
[ -d "$FEISHU_SRC" ] || fail "飞书扩展目录不存在: $FEISHU_SRC"
[ -f "$REPLY_DIST" ] || fail "reply bundle 不存在: $REPLY_DIST"
[ -f "$GATEWAY_DIST" ] || fail "gateway bundle 不存在: $GATEWAY_DIST"

backup_file() {
  local f="$1"
  if [ -f "$f" ] && [ ! -f "${f}.bak" ]; then
    cp "$f" "${f}.bak"
    ok "备份: $(basename "$f").bak"
  fi
}

info "备份原始文件..."
backup_file "${FEISHU_SRC}/card-ux-exec-approval.ts"
backup_file "${FEISHU_SRC}/channel.ts"
backup_file "${FEISHU_SRC}/outbound.ts"
backup_file "${FEISHU_SRC}/reply-dispatcher.ts"
backup_file "${FEISHU_SRC}/card-action.ts"
backup_file "$REPLY_DIST"
backup_file "$GATEWAY_DIST"

info "写入 card-ux-exec-approval.ts"
cat > "${FEISHU_SRC}/card-ux-exec-approval.ts" <<'EOF_CARD'
export const FEISHU_EXEC_APPROVAL_APPROVE = "feishu.exec_approval.approve";
export const FEISHU_EXEC_APPROVAL_DENY = "feishu.exec_approval.deny";

export function createExecApprovalPendingCard(params: {
  approvalId: string;
  command: string;
  cwd?: string;
  host: string;
  expiresAtMs: number;
  nowMs?: number;
}): Record<string, unknown> {
  return {
    schema: "2.0",
    config: { wide_screen_mode: true, update_multi: true },
    header: {
      title: { tag: "plain_text", content: "命令执行审批" },
      template: "orange",
    },
    body: {
      elements: [
        {
          tag: "markdown",
          content: `计划执行以下命令：\n\`\`\`\n${params.command}\n\`\`\``,
        },
        {
          tag: "column_set",
          columns: [
            {
              tag: "column",
              width: "auto",
              elements: [
                {
                  tag: "button",
                  text: { tag: "plain_text", content: "允许一次" },
                  type: "primary",
                  behaviors: [{ type: "callback", value: { approvalId: params.approvalId, action: "approve", decision: "allow-once" } }],
                },
              ],
            },
            {
              tag: "column",
              width: "auto",
              elements: [
                {
                  tag: "button",
                  text: { tag: "plain_text", content: "拒绝" },
                  type: "danger",
                  behaviors: [{ type: "callback", value: { approvalId: params.approvalId, action: "deny", decision: "deny" } }],
                },
              ],
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
        content: isApproved ? "审批已通过" : "审批已拒绝",
      },
      template: isApproved ? "green" : "red",
    },
    body: {
      elements: [
        {
          tag: "markdown",
          content: `执行命令：\n\`\`\`\n${params.command}\n\`\`\``,
        },
      ],
    },
  };
}
EOF_CARD
ok "card-ux-exec-approval.ts 已更新"

info "patch: channel.ts"
node --input-type=module <<EOF_NODE
import { readFileSync, writeFileSync } from "fs";
const file = ${REPLY_DIST@Q}.replace("dist/reply-Bm8VrLQh.js", "extensions/feishu/src/channel.ts");
let content = readFileSync(file, "utf8");
if (!content.includes('import { createExecApprovalPendingCard } from "./card-ux-exec-approval.js";')) {
  content = content.replace(
    'import { feishuOnboardingAdapter } from "./onboarding.js";\nimport { feishuOutbound } from "./outbound.js";',
    'import { createExecApprovalPendingCard } from "./card-ux-exec-approval.js";\nimport { feishuOnboardingAdapter } from "./onboarding.js";\nimport { feishuOutbound } from "./outbound.js";'
  );
}
if (!content.includes('  execApprovals: {')) {
  content = content.replace(
    '  },\n  setup: {',
    '  },\n  execApprovals: {\n    getInitiatingSurfaceState: ({ cfg, accountId }) => {\n      const account = resolveFeishuAccount({ cfg, accountId });\n      const feishuCfg = account.config as Record<string, unknown>;\n      const execCfg = feishuCfg.execApprovals as {\n        enabled?: boolean;\n        approvers?: Array<string | number>;\n      } | undefined;\n      if (!execCfg?.enabled) return { kind: "disabled" as const };\n      const approvers = (execCfg.approvers ?? []).map(String).filter(Boolean);\n      if (approvers.length === 0) return { kind: "disabled" as const };\n      return { kind: "enabled" as const };\n    },\n    buildPendingPayload: ({ request, nowMs }) => {\n      return {\n        card: createExecApprovalPendingCard({\n          approvalId: request.id,\n          command: request.request.command,\n          cwd: request.request.cwd,\n          host: request.request.host === "node" ? "node" : "gateway",\n          expiresAtMs: request.expiresAtMs,\n          nowMs,\n        }),\n        msgType: "interactive",\n      };\n    },\n  },\n  setup: {'
  );
}
writeFileSync(file, content);
EOF_NODE
ok "channel.ts 已更新"

info "patch: outbound.ts"
node --input-type=module <<EOF_NODE
import { readFileSync, writeFileSync } from "fs";
const file = ${FEISHU_SRC@Q} + "/outbound.ts";
let content = readFileSync(file, "utf8");
if (!content.includes('import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";')) {
  content = content.replace(
    'import { sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";',
    'import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";'
  );
}
if (!content.includes('export const _approvalCardMessageIds = new Map<string, { messageId: string; command: string }>();')) {
  content = content.replace(
    'import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";\n',
    'import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";\n\nexport const _approvalCardMessageIds = new Map<string, { messageId: string; command: string }>();\n\nexport function buildFeishuExecApprovalCard(\n  approvalId: string,\n  bodyText: string,\n): Record<string, unknown> {\n  const commandMatch = bodyText.match(/Pending command:\\n\\n```sh\\n([\\s\\S]*?)\\n```/);\n  const command = commandMatch?.[1]?.trim() ?? bodyText;\n  return {\n    schema: "2.0",\n    config: { wide_screen_mode: true, update_multi: true },\n    header: {\n      title: { tag: "plain_text", content: "命令执行审批" },\n      template: "orange",\n    },\n    body: {\n      elements: [\n        {\n          tag: "markdown",\n          content: `计划执行以下命令：\\n\\`\\`\\`\\n${command}\\n\\`\\`\\``,\n        },\n        {\n          tag: "column_set",\n          columns: [\n            {\n              tag: "column",\n              width: "auto",\n              elements: [\n                {\n                  tag: "button",\n                  text: { tag: "plain_text", content: "允许一次" },\n                  type: "primary",\n                  behaviors: [{ type: "callback", value: { approvalId, action: "approve", decision: "allow-once" } }],\n                },\n              ],\n            },\n            {\n              tag: "column",\n              width: "auto",\n              elements: [\n                {\n                  tag: "button",\n                  text: { tag: "plain_text", content: "拒绝" },\n                  type: "danger",\n                  behaviors: [{ type: "callback", value: { approvalId, action: "deny", decision: "deny" } }],\n                },\n              ],\n            },\n          ],\n        },\n      ],\n    },\n  };\n}\n\n'
  );
}
writeFileSync(file, content);
EOF_NODE
ok "outbound.ts 已更新"

info "patch: reply-dispatcher.ts"
node --input-type=module <<EOF_NODE
import { readFileSync, writeFileSync } from "fs";
const file = ${FEISHU_SRC@Q} + "/reply-dispatcher.ts";
let content = readFileSync(file, "utf8");
if (!content.includes('import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";')) {
  content = content.replace(
    'import { sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";',
    'import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";'
  );
}
if (!content.includes('import { _approvalCardMessageIds, buildFeishuExecApprovalCard } from "./outbound.js";')) {
  content = content.replace(
    'import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";\nimport { FeishuStreamingSession, mergeStreamingText } from "./streaming-card.js";',
    'import { sendCardFeishu, sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";\nimport { _approvalCardMessageIds, buildFeishuExecApprovalCard } from "./outbound.js";\nimport { FeishuStreamingSession, mergeStreamingText } from "./streaming-card.js";'
  );
}
if (!content.includes('// ---- exec approval card interception ----')) {
  content = content.replace(
    '        const text = payload.text ?? "";',
    '        // ---- exec approval card interception ----\n        // eslint-disable-next-line @typescript-eslint/no-explicit-any\n        const execApproval = (payload as any).channelData?.execApproval as { approvalId?: string; command?: string } | undefined;\n        if (execApproval?.approvalId && payload.text) {\n          const commandMatch = payload.text.match(/Pending command:\\n\\n```sh\\n([\\s\\S]*?)\\n```/);\n          const command = execApproval.command ?? commandMatch?.[1]?.trim() ?? "";\n          const card = buildFeishuExecApprovalCard(execApproval.approvalId, payload.text);\n          try {\n            const result = await sendCardFeishu({ cfg, to: chatId, card, accountId });\n            _approvalCardMessageIds.set(execApproval.approvalId, { messageId: result.messageId, command });\n            const id = execApproval.approvalId;\n            setTimeout(() => _approvalCardMessageIds.delete(id), 15 * 60 * 1000);\n          } catch (err) {\n            params.runtime.error?.(`feishu[${account.accountId}]: exec approval card send failed: ${String(err)}`);\n          }\n          return;\n        }\n        // ---- end exec approval interception ----\n        const text = payload.text ?? "";'
  );
}
writeFileSync(file, content);
EOF_NODE
ok "reply-dispatcher.ts 已更新"

info "patch: card-action.ts"
node --input-type=module <<EOF_NODE
import { readFileSync, writeFileSync } from "fs";
const file = ${FEISHU_SRC@Q} + "/card-action.ts";
let content = readFileSync(file, "utf8");
if (!content.includes('import { _approvalCardMessageIds } from "./outbound.js";')) {
  content = content.replace(
    'import { handleFeishuMessage, type FeishuMessageEvent } from "./bot.js";',
    'import { handleFeishuMessage, type FeishuMessageEvent } from "./bot.js";\nimport { _approvalCardMessageIds } from "./outbound.js";\nimport { createExecApprovalResolvedCard } from "./card-ux-exec-approval.js";\nimport { sendCardFeishu, updateCardFeishu } from "./send.js";'
  );
}
if (!content.includes('// ---- exec approval button handling ----')) {
  content = content.replace(
    '  // Extract action value\n  const actionValue = event.action.value;\n  let content = "";',
    '  // ---- exec approval button handling ----\n  const actionValue = event.action.value;\n  if (typeof actionValue === "object" && actionValue !== null && "approvalId" in actionValue) {\n    const approvalId = String(actionValue.approvalId);\n    const decision = String(actionValue.decision ?? (actionValue.action === "approve" ? "allow-once" : "deny"));\n    const chatId = event.context.chat_id || event.operator.open_id;\n\n    log(`feishu[${account.accountId}]: exec approval ${decision} for ${approvalId}`);\n\n    (process as NodeJS.EventEmitter).emit("__openclaw_feishu_resolve_approval__", {\n      id: approvalId,\n      decision,\n    });\n    log(`feishu[${account.accountId}]: emitted resolve for ${approvalId} decision=${decision}`);\n\n    const stored = _approvalCardMessageIds.get(approvalId);\n    const messageId = stored?.messageId;\n    const command = stored?.command ?? "";\n    _approvalCardMessageIds.delete(approvalId);\n\n    const resolvedCard = createExecApprovalResolvedCard({ command, decision });\n\n    try {\n      if (messageId) {\n        await updateCardFeishu({ cfg, messageId, card: resolvedCard, accountId: account.accountId });\n      } else {\n        await sendCardFeishu({ cfg, to: chatId, card: resolvedCard, accountId: account.accountId });\n      }\n    } catch (err) {\n      log(`feishu[${account.accountId}]: failed to update approval card: ${String(err)}`);\n    }\n\n    return;\n  }\n  // ---- end exec approval button handling ----\n\n  let content = "";'
  );
}
writeFileSync(file, content);
EOF_NODE
ok "card-action.ts 已更新"

info "patch: dist/reply-Bm8VrLQh.js"
node --input-type=module <<EOF_NODE
import { readFileSync, writeFileSync } from "fs";
const file = ${REPLY_DIST@Q};
let content = readFileSync(file, "utf8");
if (!content.includes('if (channel === "feishu") {')) {
  content = content.replace(
    'if (channel === "discord") return isDiscordExecApprovalClientEnabled({\n\t\tcfg,\n\t\taccountId: params.accountId\n\t}) ? {\n\t\tkind: "enabled",\n\t\tchannel,\n\t\tchannelLabel\n\t} : {\n\t\tkind: "disabled",\n\t\tchannel,\n\t\tchannelLabel\n\t};\n\treturn {',
    'if (channel === "discord") return isDiscordExecApprovalClientEnabled({\n\t\tcfg,\n\t\taccountId: params.accountId\n\t}) ? {\n\t\tkind: "enabled",\n\t\tchannel,\n\t\tchannelLabel\n\t} : {\n\t\tkind: "disabled",\n\t\tchannel,\n\t\tchannelLabel\n\t};\n\tif (channel === "feishu") {\n\t\tconst feishuCfg = cfg.channels?.feishu;\n\t\tconst execApprovals = feishuCfg?.execApprovals;\n\t\tconst enabled = execApprovals?.enabled === true;\n\t\tconst hasApprovers = Array.isArray(execApprovals?.approvers) && execApprovals.approvers.length > 0;\n\t\treturn (enabled && hasApprovers) ? {\n\t\t\tkind: "enabled",\n\t\t\tchannel,\n\t\t\tchannelLabel\n\t\t} : {\n\t\t\tkind: "disabled",\n\t\t\tchannel,\n\t\t\tchannelLabel\n\t\t};\n\t}\n\treturn {'
  );
}
writeFileSync(file, content);
EOF_NODE
ok "dist/reply-Bm8VrLQh.js 已更新"

info "patch: dist/gateway-cli-Ol-vpIk7.js"
node --input-type=module <<EOF_NODE
import { readFileSync, writeFileSync } from "fs";
const file = ${GATEWAY_DIST@Q};
let content = readFileSync(file, "utf8");
if (!content.includes('__openclaw_feishu_resolve_approval__')) {
  content = content.replace(
    'const execApprovalManager = new ExecApprovalManager();\n\tconst execApprovalHandlers = createExecApprovalHandlers(execApprovalManager, { forwarder: createExecApprovalForwarder() });',
    'const execApprovalManager = new ExecApprovalManager();\n\tconst execApprovalHandlers = createExecApprovalHandlers(execApprovalManager, { forwarder: createExecApprovalForwarder() });\n\tif (!globalThis.__openclawFeishuExecApprovalListenerRegistered) {\n\t\tglobalThis.__openclawFeishuExecApprovalListenerRegistered = true;\n\t\tprocess.on("__openclaw_feishu_resolve_approval__", async (payload) => {\n\t\t\ttry {\n\t\t\t\tconst id = payload?.id != null ? String(payload.id) : "";\n\t\t\t\tconst decision = payload?.decision != null ? String(payload.decision) : "";\n\t\t\t\tif (!id || !decision) return;\n\t\t\t\tawait callGateway({\n\t\t\t\t\tmethod: "exec.approval.resolve",\n\t\t\t\t\tparams: { id, decision },\n\t\t\t\t\ttimeoutMs: 1e4\n\t\t\t\t});\n\t\t\t\tlog.info(`exec approvals: feishu resolved ${id} decision=${decision}`);\n\t\t\t} catch (err) {\n\t\t\t\tlog.error(`exec approvals: feishu resolve failed: ${String(err)}`);\n\t\t\t}\n\t\t});\n\t}'
  );
}
writeFileSync(file, content);
EOF_NODE
ok "dist/gateway-cli-Ol-vpIk7.js 已更新"

cat <<'EOF_NOTE'

后续还需要确认配置已开启：

  "channels": {
    "feishu": {
      "execApprovals": {
        "enabled": true,
        "approvers": ["ou_placeholder"]
      }
    }
  }

完成后重启 gateway，再在飞书里发送 elevated 命令验证。
EOF_NOTE
