# Codex App Server JSON-RPC methods

Date checked: 2026-04-18

Primary sources:
- https://developers.openai.com/codex/app-server
- https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md
- https://raw.githubusercontent.com/openai/codex/main/codex-rs/app-server-protocol/src/protocol/common.rs
- https://openai.com/index/unlocking-the-codex-harness/

Important caveat:
- The public docs page and README do not expose the full wire surface.
- The protocol source in `common.rs` shows additional request, server-request, and notification methods.
- Treat `common.rs` as the strongest source for the actual wire inventory.

## High-value methods for ClawMux

Top priorities identified for a Codex provider:
- `account/rateLimits/read`
- `account/rateLimits/updated`
- `turn/interrupt`
- JSON-RPC overload error `-32001`

Likely next tier:
- `thread/list`
- `thread/compact/start`
- `thread/rollback`
- `thread/tokenUsage/updated`

Notes:
- `account/rateLimits/read` and `account/rateLimits/updated` can unify Codex quota display with the existing Claude rate-limit UI.
- `turn/interrupt` should be used instead of dropping transport when cancelling a running turn.
- Overload handling should treat JSON-RPC error `-32001` as retryable and apply exponential backoff with jitter.
- `thread/compact/start` and `thread/rollback` are useful for context control and error recovery.

## Protocol shape

- JSON-RPC-lite over stdio JSONL. The `"jsonrpc":"2.0"` header is omitted on the wire.
- Experimental websocket transport also exists.
- Handshake is `initialize`, then `initialized`.

## Transport overload and retry

The app-server README documents bounded queues and explicit overload behavior:
- If request ingress is saturated, the server returns JSON-RPC error code `-32001`.
- Error message: `Server overloaded; retry later.`
- Clients should retry with exponential backoff and jitter.

## Token usage and rate limits

- Final turn state and token usage arrive in `turn/completed`.
- Thread-level token usage snapshots stream via `thread/tokenUsage/updated`.
- On `thread/resume` and `thread/fork`, persisted token usage may be emitted immediately after the response.
- ChatGPT quota surfaces:
  - `account/rateLimits/read`
  - `account/rateLimits/updated`
- Public docs show `rateLimits` and `rateLimitsByLimitId`, with fields including `usedPercent`, `windowDurationMins`, and `resetsAt`.

## Session management surfaces

Thread lifecycle and persistence:
- `thread/start`
- `thread/resume`
- `thread/fork`
- `thread/read`
- `thread/list`
- `thread/loaded/list`
- `thread/turns/list`
- `thread/archive`
- `thread/unarchive`
- `thread/unsubscribe`
- `thread/name/set`
- `thread/status/changed`
- `thread/closed`

Context and history control:
- `thread/compact/start`
- `thread/rollback`
- `thread/inject_items`
- `thread/metadata/update`

Realtime sub-sessions:
- `thread/realtime/start`
- `thread/realtime/appendAudio`
- `thread/realtime/appendText`
- `thread/realtime/stop`
- `thread/realtime/listVoices`
- `thread/realtime/*` notifications

Standalone command sessions:
- `command/exec`
- `command/exec/write`
- `command/exec/resize`
- `command/exec/terminate`
- `command/exec/outputDelta`

Approval and elicitation:
- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`
- `item/permissions/requestApproval`
- `serverRequest/resolved`

## Client to server request methods found

### Core and thread lifecycle
- `initialize`
- `thread/start`
- `thread/resume`
- `thread/fork`
- `thread/archive`
- `thread/unsubscribe`
- `thread/increment_elicitation` [experimental]
- `thread/decrement_elicitation` [experimental]
- `thread/name/set`
- `thread/metadata/update`
- `thread/memoryMode/set` [experimental]
- `memory/reset` [experimental]
- `thread/unarchive`
- `thread/compact/start`
- `thread/shellCommand`
- `thread/backgroundTerminals/clean` [experimental]
- `thread/rollback`
- `thread/list`
- `thread/loaded/list`
- `thread/read`
- `thread/turns/list`
- `thread/inject_items`

### Turns, review, realtime
- `turn/start`
- `turn/steer`
- `turn/interrupt`
- `review/start`
- `thread/realtime/start` [experimental]
- `thread/realtime/appendAudio` [experimental]
- `thread/realtime/appendText` [experimental]
- `thread/realtime/stop` [experimental]
- `thread/realtime/listVoices` [experimental]

### Filesystem and command execution
- `command/exec`
- `command/exec/write`
- `command/exec/terminate`
- `command/exec/resize`
- `fs/readFile`
- `fs/writeFile`
- `fs/createDirectory`
- `fs/getMetadata`
- `fs/readDirectory`
- `fs/remove`
- `fs/copy`
- `fs/watch`
- `fs/unwatch`

### Discovery, config, plugins, apps, skills
- `model/list`
- `experimentalFeature/list`
- `experimentalFeature/enablement/set`
- `collaborationMode/list` [experimental]
- `skills/list`
- `skills/config/write`
- `marketplace/add`
- `plugin/list`
- `plugin/read`
- `plugin/install`
- `plugin/uninstall`
- `app/list`
- `config/read`
- `config/value/write`
- `config/batchWrite`
- `configRequirements/read`
- `config/mcpServer/reload`
- `externalAgentConfig/detect`
- `externalAgentConfig/import`

### MCP, platform, auth
- `mcpServer/oauth/login`
- `mcpServerStatus/list`
- `mcpServer/resource/read`
- `mcpServer/tool/call`
- `windowsSandbox/setupStart`
- `feedback/upload`
- `account/read`
- `account/login/start`
- `account/login/cancel`
- `account/logout`
- `account/rateLimits/read`
- `account/sendAddCreditsNudgeEmail`

### Fuzzy search, test, and deprecated methods
- `fuzzyFileSearch`
- `fuzzyFileSearch/sessionStart` [experimental]
- `fuzzyFileSearch/sessionUpdate` [experimental]
- `fuzzyFileSearch/sessionStop` [experimental]
- `mock/experimentalMethod` [experimental, test-only]
- `getConversationSummary` [deprecated]
- `gitDiffToRemote` [deprecated]
- `getAuthStatus` [deprecated]

## Server to client request methods found

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`
- `item/permissions/requestApproval`
- `item/tool/call`
- `account/chatgptAuthTokens/refresh`
- `ApplyPatchApproval` [deprecated]
- `ExecCommandApproval` [deprecated]

## Server to client notifications found

### Thread and turn lifecycle
- `error`
- `thread/started`
- `thread/status/changed`
- `thread/archived`
- `thread/unarchived`
- `thread/closed`
- `thread/name/updated`
- `thread/tokenUsage/updated`
- `turn/started`
- `turn/completed`
- `turn/diff/updated`
- `turn/plan/updated`
- `model/rerouted`
- `thread/compacted` [deprecated]

### Item lifecycle and deltas
- `item/started`
- `item/completed`
- `item/agentMessage/delta`
- `item/plan/delta` [experimental]
- `item/commandExecution/outputDelta`
- `item/commandExecution/terminalInteraction`
- `item/fileChange/outputDelta`
- `item/mcpToolCall/progress`
- `item/reasoning/summaryTextDelta`
- `item/reasoning/summaryPartAdded`
- `item/reasoning/textDelta`
- `item/autoApprovalReview/started` [unstable]
- `item/autoApprovalReview/completed` [unstable]
- `rawResponseItem/completed` [internal-only]

### Commands, files, hooks, requests
- `command/exec/outputDelta`
- `fs/changed`
- `hook/started`
- `hook/completed`
- `serverRequest/resolved`

### Skills, apps, external config
- `skills/changed`
- `app/list/updated`
- `externalAgentConfig/import/completed`

### MCP and auth
- `mcpServer/oauthLogin/completed`
- `mcpServer/startupStatus/updated`
- `account/updated`
- `account/rateLimits/updated`
- `account/login/completed`

### Realtime and fuzzy search
- `fuzzyFileSearch/sessionUpdated`
- `fuzzyFileSearch/sessionCompleted`
- `thread/realtime/started` [experimental]
- `thread/realtime/itemAdded` [experimental]
- `thread/realtime/transcript/delta` [experimental]
- `thread/realtime/transcript/done` [experimental]
- `thread/realtime/outputAudio/delta` [experimental]
- `thread/realtime/sdp` [experimental]
- `thread/realtime/error` [experimental]
- `thread/realtime/closed` [experimental]

### Warnings, diagnostics, Windows
- `warning`
- `deprecationNotice`
- `configWarning`
- `windows/worldWritableWarning`
- `windowsSandbox/setupCompleted`

## Client to server notifications found

- `initialized`

## Source versus docs differences

Methods and notifications clearly present in `common.rs` that are not prominently documented on the public app-server page:
- `thread/increment_elicitation`
- `thread/decrement_elicitation`
- `memory/reset`
- `thread/turns/list`
- `thread/realtime/listVoices`
- `account/sendAddCreditsNudgeEmail`
- `account/chatgptAuthTokens/refresh`
- `fuzzyFileSearch/sessionStart`
- `fuzzyFileSearch/sessionUpdate`
- `fuzzyFileSearch/sessionStop`
- `hook/started`
- `hook/completed`
- `item/commandExecution/terminalInteraction`
- `windows/worldWritableWarning`

## Health and readiness

I did not find a dedicated JSON-RPC health method.

For websocket listeners, the README documents:
- `GET /readyz` returns `200 OK` once the listener is accepting connections.
- `GET /healthz` returns `200 OK` when no `Origin` header is present.

Useful operational signals beyond those endpoints:
- `warning`
- `configWarning`
- `mcpServer/startupStatus/updated`
- `error`
- overload error `-32001`
