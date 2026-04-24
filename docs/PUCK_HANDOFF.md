# Puck Handoff

This document is a thorough transfer note for the current `clawmux` repo state, focused on the work done during the recent debugging, deployment, and reliability pass.

Repo:
- Local path: `/home/zeul/GIT/clawmux`
- GitHub: `https://github.com/zeulewan/clawmux`
- Current `main` head at time of writing: `1572d5e` `Filter foreign Codex thread events`

## Scope Of Work

This pass was not one feature. It was a rolling stabilization and operational pass across:
- Codex frontend rendering
- Codex launch/resume behavior
- session identity and routing
- inter-agent close-thread semantics
- effort/thinking visibility and sync
- raw provider-stream inspection
- mac deployment/runtime fixes
- workstation Codex cross-thread routing corruption

There were also machine-local operational changes that are not in git, especially on the mac and in agent docs.

## Current Repo State

As of this handoff:
- Local repo head: `1572d5e`
- Working tree: expected clean after the latest commit/push
- Main remote: `origin https://github.com/zeulewan/clawmux.git`
- Extra remote: `zmac zeul@100.117.222.41:~/GIT/clawmux`

Recent commits on `main`, newest first:
- `1572d5e` `Filter foreign Codex thread events`
- `41bab39` `Add monitor tail panel`
- `f3d7712` `Add raw provider tail stream`
- `fbf3278` `Fix effort selector state sync`
- `e9a724f` `Fix Codex approval handling on resumed threads`
- `5b41f1f` `Start Codex app-server in bypass mode`
- `c6a529a` `Reconnect active sessions instead of remapping them`
- `cf4fe11` `Add thread close controls and effort visibility`
- `a5c7d02` `Fix monitor usage SSE updates`
- `38dff19` `Normalize snapshot-style streaming deltas`
- `11d6f54` `Separate conversation identity from transport channels`
- `50e1af7` `Bind sessions to explicit agent IDs`
- `2051d48` `Recover stale agent channels after relaunch`
- `2a3e866` `Fix Codex resume fallback helper scope`
- `ad700ce` `Fix Codex launch from fresh sessions`
- `06403cf` `Add agent session migration command`
- `920a4d9` `Add session migration prompt builder`
- `19af1a7` `Fix Codex turn start handling`

## Major Changes

### 1. Codex Frontend Rendering Fix

Problem:
- Codex could return turn start only in the JSON-RPC `turn/start` response.
- The frontend expected turn initialization from a later `turn/started` path.
- If that notification did not arrive, assistant deltas had no proper message/container setup and would not render correctly.

Fix:
- `19af1a7` added `turnStart()` emission from the RPC `turn/start` result.
- Added a guard so `turn/started` does not double-fire the same turn.

Key file:
- `server/providers/codex-provider.js`

Validation:
- Playwright UI smoke passed at the time.
- This was the initial “Codex renders again” fix.

### 2. Migration Tooling

Goal:
- Support practical cross-backend migration, not impossible native cross-backend resume.

Core distinction:
- Native resume across backends is not real.
- Claude and Codex use different native session/thread formats and IDs.
- What is implementable is migration: extract, compact, and inject history into a new target backend session.

Shipped pieces:
- `920a4d9` added a migration-prompt builder primitive.
- `06403cf` added `cmx migrate <agent> --to <backend> [--max-tokens N]`

Behavior:
- Reads the source session
- Builds a compact migration prompt
- Switches backend
- Kills the old live connection
- Starts a fresh target session
- Primes the target backend invisibly so the next user message continues from migrated context

Notes:
- Default Codex migration budget was set conservatively relative to its context window.
- Follow-up testing was intentionally deferred rather than overclaimed.

GitHub follow-up:
- Issue `#24` was added to track more thorough migration testing.

### 3. Fresh Codex Session / Resume Fixes

Problems:
- Fresh frontend sessions were passing a local browser `channelId` like `ch_*` as if it were a Codex resume/thread ID.
- Codex resume failed with invalid thread IDs.
- A first attempt at resume fallback had a scope bug.

Fixes:
- `ad700ce` `Fix Codex launch from fresh sessions`
- `2a3e866` `Fix Codex resume fallback helper scope`

Behavior after fix:
- fresh sessions no longer try to resume with fake browser IDs
- if Codex resume still fails, provider falls back to `thread/start`

Files involved:
- `app/src/state/session.js`
- `server/providers/codex-provider.js`

### 4. Session Identity Rewrite

This was one of the bigger architectural fixes.

Old model:
- `channelId` was doing too much
- temporary browser transport IDs were too close to being treated as conversation identity
- reconnects/reloads/relaunches could cross-wire sessions

New model:
- stable app-level `conversationId`
- `channelId` is transport only
- provider session IDs remain backend-native and live under app conversation identity

Commits:
- `50e1af7` `Bind sessions to explicit agent IDs`
- `11d6f54` `Separate conversation identity from transport channels`

Effect:
- routing is keyed by explicit conversation identity
- stale transport channel recovery is safer
- backend reuse only happens for the same conversation or same native backend session

Files involved:
- `app/src/state/session.js`
- `app/src/state/sessions.js`
- `app/src/lib/protocol.js`
- `server/provider-session.js`
- `server.js`

### 5. Duplicate-Word Streaming Fix

Problem:
- Some providers, especially Codex paths, could emit “full text so far” snapshots while the frontend/session layer treated them as append-only deltas.
- This produced duplicated output like `YesYes.. I I’m...`.

Fix:
- `38dff19` `Normalize snapshot-style streaming deltas`

Implementation:
- Normalize “new text begins with existing text” into suffix-only append behavior.

File:
- `server/provider-session.js`

### 6. Monitor Usage SSE Fix

Problem:
- OpenAI/Codex usage values were not reliably updating in the monitor pane after initial connect.

Fix:
- `a5c7d02` `Fix monitor usage SSE updates`

Behavior:
- monitor SSE now pushes usage refreshes after connect instead of only at initial load
- `0%`-ish values no longer get dropped by snapshot logic

Files:
- `server.js`
- `server/provider-session.js`

### 7. Inter-Agent Thread Close Semantics

Problem:
- `cmx send` originally had no real “close thread” semantic
- “stop replying” was just another message
- prompts strongly biased agents to respond to all `[MSG ...]` items

Fix:
- `cf4fe11` `Add thread close controls and effort visibility`

New controls:
- `cmx send --close-thread TARGET_NAME "..."`  
- `cmx send --reopen-thread TARGET_NAME "..."`  

Behavior:
- closed peer threads are tracked server-side
- regular sends to a closed peer thread are blocked until reopened
- agent docs were updated so agents stop reflexively acknowledging closeouts

Repo-side behavior:
- thread closed/open state stored in `~/.clawmux/thread-state.json`
- `server.js` enforces closed thread behavior in `/api/send`

### 8. Effort / Thinking Visibility

Goals:
- restore Codex `xhigh`
- show thinking/effort in monitor and UI
- keep effort selector, header, and monitor in sync

Relevant commits:
- `cf4fe11` `Add thread close controls and effort visibility`
- `fbf3278` `Fix effort selector state sync`

Behavior:
- Codex `xhigh` is exposed again
- monitor shows effort/thinking level
- chat header reflects live effort
- effort changes now emit monitor refreshes and resync open UI state

Files:
- `server/provider-session.js`
- `server.js`
- `app/src/components/InputBar.jsx`
- monitor-related UI components

Reference research:
- `okcode` and `t3code` were checked as references
- takeaway was mostly architectural:
  - `okcode`: canonical thread identity everywhere
  - `t3code`: provider-specific typed reasoning/effort state

Those repos were reference material, not copy-paste sources.

### 9. Codex Approval / Unsandboxed Execution Fixes

Requirements from user:
- no sandboxing
- no watchdog as a fake solution

Problem:
- Codex app-server approval requests were still appearing
- request IDs starting at `0` were mishandled because normal JS truthiness treated `0` as absent/falsy
- this could wedge turns

Fixes:
- `5b41f1f` `Start Codex app-server in bypass mode`
- `e9a724f` `Fix Codex approval handling on resumed threads`

Behavior:
- Codex launched with explicit bypass/full access behavior
- `approval_policy="never"`
- `sandbox_mode="danger-full-access"`
- approval request ID `0` now handled correctly

Files:
- `server/providers/codex-provider.js`
- `tests/codex-provider.test.js`

### 10. Raw Provider Tail Stream

Goal:
- expose a more raw provider-native event stream for debugging all backends

Commit:
- `f3d7712` `Add raw provider tail stream`

CLI:
- `cmx tail alice`
- `cmx tail alice --raw`
- `cmx tail alice --json`
- `cmx tail alice --limit 200`

API:
- `GET /api/agents/:id/raw`
- `GET /api/agents/:id/raw/stream`

Implementation:
- shared raw ring buffers in `server/provider-session.js`
- provider-native raw event instrumentation added to:
  - `server/providers/claude-provider.js`
  - `server/providers/codex-provider.js`
  - `server/providers/pi-provider.js`
  - `server/providers/opencode-provider.js`

Important nuance:
- Claude is parsed native JSONL/provider messages, not byte-for-byte raw stdout dump.

### 11. Monitor Tail Panel

Goal:
- expose the raw-tail feature in the web UI, not just CLI

Commit:
- `41bab39` `Add monitor tail panel`

Behavior:
- in monitor UI, clicking an agent row opens a live tail panel
- views:
  - `summary`
  - `raw`
  - `json`
- panel includes `Open Chat` action
- clicking a dead/no-session agent from monitor triggers `/api/launch`

Files:
- `app/src/components/Monitor.jsx`
- `app/src/styles/webview.css`

### 12. Codex Cross-Thread Corruption Fix

This was the latest serious reliability issue on workstation Codex.

Observed symptom:
- some Codex agents were stuck in `thinking`
- `lastActivity` timestamps stopped moving
- a message intended for `Alice` was actually launched on `Jessica`’s or `Nova`’s Codex thread ID

Concrete evidence observed:
- `Alice`’s saved thread: `019d9fac-...`
- `Jessica`’s saved thread: `019dbaf2-42de-...`
- `Nova`’s saved thread: `019db492-...`
- server log showed sends for `Alice` going to non-Alice thread IDs

Root cause:
- shared Codex app-server emits thread-bound notifications broadly
- `codex-provider.js` was accepting those notifications without verifying `params.threadId`
- a connection could absorb another thread’s turn/thread state

Fix:
- `1572d5e` `Filter foreign Codex thread events`

Implementation:
- reject thread-bound notifications whose `threadId` does not match the connection’s active thread
- do not let `thread/started` overwrite an already-known thread from a foreign event

Files:
- `server/providers/codex-provider.js`
- `tests/codex-provider.test.js`

Live validation on workstation:
- restarted `clawmux`
- previously poisoned Codex sessions came back `idle`
- sent a test prompt to `Alice`
- raw stream showed the turn stayed on Alice’s real thread
- `Jessica` and `Nova` were not touched

## Operational / Machine-Local Changes

These changes are important but are not fully represented in git.

### mac (`zeul-mac`)

Operational work done:
- cloned/updated active repo to `/Users/zeul/GIT/clawmux`
- archived old prototype repos on mac
- deleted old `clawmux-lite` checkout from mac later
- added the first five workstation agent identities to mac
- copied per-agent `CLAUDE.md` to mac agent dirs
- duplicated those into `AGENT.md`
- fixed local `cmx` availability using an absolute wrapper path
- updated mac agent docs to reference absolute mac `cmx`

Important runtime note:
- mac `cmx start` was brittle because child spawns could not find `node` on `PATH`
- manual restart with explicit `/opt/homebrew/bin/node` and explicit `PATH` was needed at least once

Last verified mac repo state before SSH became unreliable:
- repo head on mac had been updated to `f3d7712` at one point
- later changes after `f3d7712` were not all confirmed deployed there
- do not assume mac is on current `main` without checking directly

### workstation

Operational work done:
- active repo switched fully to `/home/zeul/GIT/clawmux`
- old `clawmux-lite` / old webview repos archived earlier in the cycle
- workstation server sometimes intentionally rebound:
  - `127.0.0.1:3470` for local-only mode
  - `0.0.0.0:3470` when Tailscale access was needed

Current workstation state at last verification:
- listener bound to `0.0.0.0:3470`
- Tailscale reachability on `100.101.214.44:3470`
- all 27 agents present in monitor
- Codex agents `alice`, `jessica`, `nova`, `river`, `lily` were all back to `idle` after `1572d5e`

## Agent / Prompt / Config Notes

Per-agent docs:
- workstation has per-agent `CLAUDE.md`
- mac had `CLAUDE.md` copied and duplicated to `AGENT.md`
- docs were updated to:
  - use explicit `cmx` paths where needed
  - mention `--close-thread`
  - mention `--reopen-thread`
  - stop reflexively acknowledging closeouts

Backend defaults and config:
- repo-level config behavior is driven by server config and `~/.clawmux`
- multiple backends live in one hub:
  - `claude`
  - `codex`
  - `pi`
  - `opencode`

Current design takeaway:
- system is more stable after conversation/thread identity work
- but backend session IDs are still backend-native
- migration is the cross-backend path, not direct native resume across providers

## Known Limitations / Risks

### 1. mac deployment state may lag `main`

Do not assume the mac is on the latest repo head.
Check directly before claiming parity.

### 2. `cmx start` portability on mac

There is a machine-local startup/path bug:
- mac server start may fail if bare `node` is not on the daemon/process PATH

This is operationally important and should likely be fixed in repo code by making start/update more robust about `process.execPath` or explicit PATH injection.

### 3. Silent queueing to stale agent session shells

Observed issue:
- `/api/send` can persist/send-log a message even when the target agent has only a stale session shell and no live usable backend connection
- this makes “Sent to X” misleading

Desired fix:
- either auto-launch target agent on send if no usable live connection exists
- or fail loudly instead of queueing forever

This is still a real gap.

### 4. Clicking dead agents should wake them deterministically

Some UI behavior has been improved via monitor launch kicks, but the session/focus path still deserves a direct review so “focus dead agent” always deterministically relaunches instead of relying on stale local state.

### 5. No-watchdog preference

User explicitly does not want a watchdog-style fake fix for Codex hangs.
Work should continue to prefer actual protocol/session/state fixes over periodic forced relaunch hacks.

## Validation Summary

Things explicitly validated during this pass:
- targeted Node tests for Codex provider logic
- app build via `npm run build`
- live workstation Codex smoke:
  - healthy turn flow
  - healthy raw tail output
  - `Alice` routing staying on Alice’s thread after `1572d5e`
- workstation Tailscale reachability after rebinding to `0.0.0.0`

Things that were not universally revalidated in one final full sweep:
- every backend on every machine
- all mac deployments after the latest workstation-only fixes

## Suggested Next Steps

Highest-value next fixes:
1. Fix `/api/send` so it cannot silently queue forever into dead agent shells.
2. Make “click/focus dead agent” always perform an explicit relaunch, not just focus/session reuse.
3. Harden `cmx start`/`cmx update` so mac child spawns do not depend on ambient PATH for `node`.
4. If needed, deploy `1572d5e` and later commits to mac and verify Codex routing there too.
5. Consider continuing the long-term architecture direction already implied by the recent work:
   - strict conversation identity
   - strict backend thread ownership
   - provider-scoped option state

## Fast Reference

Important commands:
- `cmx tail alice --raw`
- `cmx tail alice --json`
- `cmx send --close-thread alice "done"`
- `cmx send --reopen-thread alice "new topic"`
- `cmx migrate puck --to codex`
- `cmx terminate alice`
- `cmx launch alice`

Important files:
- `server/providers/codex-provider.js`
- `server/provider-session.js`
- `server.js`
- `app/src/state/session.js`
- `app/src/state/sessions.js`
- `app/src/lib/protocol.js`
- `app/src/components/Monitor.jsx`
- `tests/codex-provider.test.js`

## Bottom Line

The repo is materially better than it was at the start of this pass.

The most important shipped improvements were:
- Codex render recovery
- session/conversation identity cleanup
- migration tooling
- explicit close-thread semantics
- effort/thinking visibility
- raw provider tailing
- monitor-integrated tail UI
- real Codex cross-thread routing fix

The most important unresolved operational gap is still the difference between:
- an agent having a registry/session shell entry
- and an agent having a real live usable backend connection

That distinction caused at least some of the “agent isn’t responding” confusion and should be tightened next.
