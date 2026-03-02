# v0.6.0 - ClawMux CLI & Agent Orchestration

Replace the MCP server with the ClawMux CLI. Add multi-backend support, sub-agent workers, and infrastructure improvements.

## ClawMux CLI

The MCP server is retired in favor of a CLI tool for voice and inter-agent messaging. Any agent runtime that can run bash uses the same interface. The browser gets a right-click menu to launch sessions with either MCP (legacy) or CLI during migration.

## Dual Backend

Pluggable backend so the hub can run sessions through Claude Code or OpenClaw interchangeably.

## Sub-Agent Workers

Agents can spawn lightweight workers that inherit their voice and appear nested in the sidebar.

## Other

Status visibility between converse calls, streaming TTS, code block rendering, one-command setup, and deferred items from v0.5.0.
