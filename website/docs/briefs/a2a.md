# A2A Integration Brief

*Created: 2026-03-02*

How ClawMux will let your agents talk to the outside world.

## The Problem

Right now, your ClawMux agents can only talk to each other. They use `clawmux send` to pass messages around, and that works great for your local team. But they can't talk to agents running on someone else's machine, or to agents built with different frameworks. Your hub is an island.

At the same time, the way agents communicate internally is a bit rough. They call REST endpoints directly, which wastes tokens and requires them to know API details they shouldn't have to care about.

## What A2A Is

A2A (Agent-to-Agent) is an open protocol backed by Google, AWS, Microsoft, and 150+ organizations under the Linux Foundation. It defines a standard way for agents to discover each other, exchange messages, and track tasks. Think of it like HTTP for agent communication: a shared language that any agent can speak regardless of what framework or model it runs on.

The protocol has three core pieces:

- **Agent Cards** describe what an agent can do and how to reach it, published at a well-known URL
- **Tasks** are units of work with clear lifecycle states (working, completed, failed)
- **Messages** carry structured content (text, files, data) between agents

## How It Fits Into ClawMux

```
                        ┌──────────────────────────────────────┐
                        │          Your ClawMux Hub             │
                        │                                      │
  External              │   ┌─────┐  ┌───────┐  ┌──────┐      │
  A2A Agents ──────────►│   │ Sky │  │ Alloy │  │ Echo │ ...  │
  (any framework)   A2A │   └──┬──┘  └───┬───┘  └──┬───┘      │
                        │      │         │         │           │
                        │      └────clawmux send───┘           │
                        │         (unchanged)                  │
                        └──────────────────────────────────────┘
```

The key insight is that A2A sits *alongside* the existing system, not replacing it. Internally, your agents keep using `clawmux send` exactly as they do today. A2A adds a new front door for agents coming from outside your hub.

Your hub appears as a single A2A agent to the outside world. When an external agent sends a message, the hub routes it to the right internal agent. Responses go back out through the same A2A channel.

**Nothing changes about how your agents work day-to-day.** The tmux sessions, voice pipeline, browser UI, and internal messaging all stay the same.

## The CLI Stays Central

Agents won't interact with A2A directly. They'll use the `clawmux` CLI, which wraps the protocol details:

```bash
# Internal messaging (unchanged)
clawmux send --to sky "Check the test results"

# External messaging (new)
clawmux a2a send --to "https://alice-hub.ts.net" "Can your researcher look into X?"
```

This matters because CLI commands are cheap on tokens and easy for agents to learn. Making agents call REST endpoints directly wastes context and creates fragile instructions.

## The Path to Federation

A2A is the foundation for something bigger: trusted peer-to-peer communication between hubs.

**Phase 1: Be Discoverable.** Publish an Agent Card so external agents can find your hub and what it offers. Accept inbound messages with basic API key auth. This is a few days of work and gives you something to demo.

**Phase 2: Reach Out.** Let your agents initiate conversations with external A2A agents on other hubs. Add outbound messaging and the trust framework that controls who can talk to whom.

**Phase 3: Federation.** Full bidirectional communication between hubs, with trust tiers controlling access:

| Trust Level | What They Can Do |
|------------|-----------------|
| Anyone | Send a short intro message (you review it manually) |
| Acquaintance | Interact, but you approve each time |
| Trusted | Messages get through, but stripped to structured data |
| Inner Circle | Full natural language access between agents |

Trust is earned over time. Your agents monitor interactions and recommend trust changes. You always have final say.

## OpenClaw Connection

OpenClaw already has 40+ channel extensions (Slack, Discord, Telegram, etc.). A2A would be another extension in `extensions/a2a/`, exposing your hub agents as A2A-compatible endpoints. This means any OpenClaw deployment could participate in the same federation network, bringing its multi-channel capabilities along.

## Why A2A Over Rolling Our Own

- **Ecosystem:** 150+ organizations, Linux Foundation backing, SDKs in Python and TypeScript
- **Interop:** Any A2A-compatible agent can talk to yours (LangGraph, CrewAI, custom frameworks)
- **Standards-based auth:** OAuth2, API keys, and mTLS built into the spec
- **Low risk:** The protocol is additive. If A2A evolves or a better standard emerges, the internal system is untouched

Building a custom protocol would mean more work, zero interoperability, and maintaining it forever. A2A gives us the network effects for free.

## Current Status

Echo completed a [feasibility study](../agents/roadmap/a2a-feasibility.md) confirming the integration is straightforward. Phase 1 (Agent Cards and inbound messaging) is estimated at 2-3 days. Phase 2 (outbound messaging and trust framework) is 1-2 weeks.

The work fits naturally into the v0.7.0 roadmap, though Phase 1 could land earlier as an exploratory addition to v0.6.x.
