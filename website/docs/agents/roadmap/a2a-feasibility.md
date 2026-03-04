# A2A Protocol Feasibility Study

**Date:** 2026-03-03
**Author:** Echo (research agent)
**Status:** Decision document — ready for review

---

## Executive Summary

Adding A2A (Agent-to-Agent protocol) endpoints to ClawMux is **feasible and low-risk**. The protocol maps cleanly onto our existing messaging architecture. A phased approach lets us add A2A discovery and messaging without touching the current tmux/converse pipeline. The main value isn't local agent-to-agent communication (we already have that) — it's **federation**: letting external agents on other hubs discover and talk to ours.

**Recommendation:** Do it in two phases. Phase 1 (Agent Cards + receive endpoint) is ~2-3 days of work. Phase 2 (outbound A2A client + federation) is a larger effort that builds on the trust framework you've already specced.

---

## What is A2A?

A2A (Agent2Agent) is an open protocol from Google, now hosted by the Linux Foundation (June 2025). Current version: **v0.3.0** (July 2025). Backed by AWS, Microsoft, Salesforce, SAP, Cisco, and 150+ organizations.

**Core concepts:**

- **Agent Cards** — JSON manifests describing what an agent can do, how to reach it, and what auth it requires. Published at `/.well-known/agent.json`.
- **Tasks** — The unit of work. States: `working` → `input-required` → `completed`/`failed`/`canceled`/`rejected`.
- **Messages** — Contain `parts` (text, files, structured data) with roles (`user`/`agent`).
- **Transport** — JSON-RPC 2.0 over HTTPS (primary), with gRPC and REST bindings. SSE for streaming.
- **Push notifications** — Webhook-based async delivery for long-running tasks.

**Python SDK:** `pip install a2a-sdk` — includes FastAPI/Starlette server integration, async-native.

---

## Current ClawMux Architecture (Relevant Parts)

| Component | What it does |
|-----------|-------------|
| `POST /api/messages/send` | Send message between local agents |
| `MessageBroker` | In-memory tracking with ack/reply/retry |
| Agent discovery | CLAUDE.md "Active Agents" section, rebuilt on spawn |
| Message format | `[MSG id:xxx from:name] content` injected via tmux |
| Transport | REST API + tmux send-keys + MCP WebSocket |

**Key insight:** Our messaging is already structured (IDs, states, ack/reply lifecycle). The gap is that it's internal-only and uses a custom format.

---

## What A2A Would Give Us

### Things we'd gain
1. **Agent discovery** — External agents find ours via standard Agent Cards
2. **Federation** — Agents on different hubs can communicate
3. **Interop** — Any A2A-compatible agent (LangGraph, CrewAI, custom) can talk to our agents
4. **Structured messages** — MIME-typed parts instead of plain text
5. **Standard auth** — OAuth2, API keys, mTLS baked into the spec

### Things we already have (no change needed)
- Local agent-to-agent messaging (keep tmux injection as-is)
- Agent lifecycle management (tmux spawning, health checks)
- TTS/STT pipeline (not A2A's domain)
- Browser UI and WebSocket protocol

---

## Integration Design

### Phase 1: Agent Cards + Inbound A2A (Receive messages from external agents)

**Effort: 2-3 days**

#### 1a. Publish Agent Cards

Add `GET /.well-known/agent.json` to the hub. Returns a manifest for the hub itself (not individual agents — the hub is the "agent" from A2A's perspective, routing internally).

```json
{
  "name": "ClawMux Hub",
  "description": "Multi-agent voice hub with specialized agents",
  "url": "https://hub.example.com",
  "version": "0.6.0",
  "capabilities": {
    "streaming": true,
    "pushNotifications": false
  },
  "skills": [
    {"id": "clawmux-voice", "name": "Voice Conversation"},
    {"id": "code-task", "name": "Code Task Execution"},
    {"id": "research", "name": "Research & Analysis"}
  ],
  "securitySchemes": {
    "apiKey": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
  },
  "interfaces": ["jsonrpc"]
}
```

**What changes:** Add one new route to `hub.py`. Generate card from current session list.

#### 1b. A2A Receive Endpoint

Add `POST /a2a` (JSON-RPC 2.0) that accepts `a2a.sendMessage`. Route incoming A2A messages to local agents via the existing `MessageBroker`.

```python
# Pseudocode — new handler in hub.py
@app.post("/a2a")
async def a2a_jsonrpc(request: Request):
    body = await request.json()
    method = body["method"]

    if method == "a2a.sendMessage":
        # Extract message parts, find target agent
        # Create internal Message via broker
        # Return A2A Task object with status
        ...
    elif method == "a2a.getTask":
        # Map to broker message status
        ...
```

**Message translation:** A2A message parts → internal `[MSG ...]` format for tmux injection. Responses collected via broker's reply mechanism → formatted back as A2A task completion.

**What changes:** ~200 lines in `hub.py`. New `a2a_bridge.py` module for format translation. No changes to existing endpoints.

#### 1c. Dependencies

```
pip install "a2a-sdk[http-server]"
```

The SDK provides Pydantic models for all A2A types, which we'd use for request/response validation.

### Phase 2: Outbound A2A + Federation (Send messages to external agents)

**Effort: 1-2 weeks**

#### 2a. A2A Client

Add ability for agents to send messages to external A2A endpoints. New `clawmux` command:

```bash
clawmux a2a send --to "https://other-hub.example.com" --agent "researcher" "Can you look into X?"
```

Under the hood: discover remote Agent Card → send A2A message → track task → deliver response back to requesting agent.

**What changes:** New `a2a_client.py` module. New CLI command. New REST endpoint `POST /api/a2a/send`.

#### 2b. Trust Framework

This maps directly to the trust tier system you've already designed:

| Trust Tier | A2A Mapping |
|-----------|-------------|
| Cold message | Unauthenticated `a2a.sendMessage` → goes to a gateway agent for screening |
| Request only | API key auth → can send tasks, limited to certain skills |
| Structured gateway | OAuth2 → full task access with audit trail |
| Raw access | mTLS → direct agent routing, no gateway |

**What changes:** Auth middleware on `/a2a` endpoint. Trust ledger storage. This is the bulk of Phase 2 work.

#### 2c. Hub Discovery

Register hub's Agent Card with a discovery service (or just DNS/Tailscale for private networks).

For the Tailscale case: each hub publishes its Agent Card at `https://{hostname}.ts.net/.well-known/agent.json`. Agents discover peers by scanning known Tailscale hosts.

---

## What Doesn't Change

| Component | Impact |
|-----------|--------|
| Tmux session management | None |
| Internal `clawmux send` messaging | None |
| MCP WebSocket protocol | None |
| TTS/STT pipeline | None |
| Browser WebSocket | None (but could show external messages) |
| CLAUDE.md generation | None |
| Health monitoring | None |

The A2A layer sits **alongside** the existing API, not replacing it. Internal agents keep using `clawmux send`. A2A is for external communication only.

---

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| A2A spec changes (still v0.3) | Medium | SDK handles protocol details; we only implement the bridge layer |
| Performance overhead | Low | A2A is just HTTP — same as our existing REST API |
| Security surface | Medium | Phase 1 can be read-only (Agent Cards only). Phase 2 adds auth |
| Breaking existing messaging | Very Low | A2A is additive — new endpoints, no changes to existing ones |
| SDK maturity | Low | Python SDK is actively maintained, FastAPI integration built-in |
| Complexity creep | Medium | Keep Phase 1 minimal. Don't over-abstract |

---

## Effort Summary

| Phase | Scope | Effort | Dependencies |
|-------|-------|--------|-------------|
| **Phase 1a** | Agent Card endpoint | 0.5 days | `a2a-sdk` |
| **Phase 1b** | Inbound A2A receive | 1-2 days | Phase 1a |
| **Phase 1c** | Integration tests | 0.5 days | Phase 1b |
| **Phase 2a** | Outbound A2A client | 2-3 days | Phase 1 |
| **Phase 2b** | Trust framework | 3-5 days | Phase 2a + trust spec |
| **Phase 2c** | Hub discovery | 1-2 days | Phase 2a |

**Phase 1 total: ~2-3 days.** Get Agent Cards published and accept inbound messages.
**Phase 2 total: ~1-2 weeks.** Full bidirectional federation with trust tiers.

---

## Decision Points

1. **Should the hub expose as one A2A agent or multiple?**
   - Recommendation: One agent (the hub) that routes internally. Simpler, matches how A2A clients expect to interact. Individual agent skills listed in the Agent Card.

2. **Where does A2A fit in the roadmap?**
   - Natural fit for v0.7.0 (already scoped as "decentralized hub"). Phase 1 could land earlier as a v0.6.x addition.

3. **ACP (BeeAI) vs A2A?**
   - ACP is IBM's competing protocol. A2A has massively more adoption (Google, AWS, Microsoft, 150+ orgs, Linux Foundation backing). Go with A2A.

4. **Do we need gRPC support?**
   - No. JSON-RPC over HTTPS is sufficient for hub-to-hub communication. gRPC adds complexity with minimal benefit at our scale.

---

## Bottom Line

**Can we do this without breaking what works?** Yes. A2A is purely additive. The existing REST API, tmux injection, MCP WebSocket, and converse pipeline are untouched. We're adding a new front door for external agents, with a translation layer to our internal messaging format.

**Is it worth doing?** If federation is the goal, absolutely. A2A is the clear standard with the ecosystem momentum. The alternative is building a custom federation protocol, which would be more work and less interoperable.

**When to start:** Phase 1 is small enough to do as an exploratory spike alongside v0.6.0 work. It gives us something to demo (external agents discovering our hub) without committing to the full federation stack.
