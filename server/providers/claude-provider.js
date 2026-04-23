/**
 * Claude Code CLI provider.
 *
 * Spawns `claude -p --output-format stream-json --input-format stream-json`
 * and translates stdio JSONL events into normalized E.* internal events.
 *
 * All events go through the same translation layer as other providers.
 * No _raw passthrough.
 */

import { spawn } from 'child_process';
import { E } from './events.js';

const CLAUDE_CMD = process.env.CLAUDE_CMD || 'claude';

export class ClaudeProvider {
  constructor() {
    this.name = 'claude';
  }

  connect(config = {}) {
    const args = [
      '--dangerously-skip-permissions',
      '-p',
      '--output-format',
      'stream-json',
      '--verbose',
      '--input-format',
      'stream-json',
      '--include-partial-messages',
    ];
    if (config.resume) args.push('--resume', config.resume);
    if (config.model && config.model !== 'default') args.push('--model', config.model);
    if (config.effortLevel && config.effortLevel !== 'default') args.push('--effort', config.effortLevel);

    const proc = spawn(CLAUDE_CMD, args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, CMX_AGENT: config.agentId || '' },
      cwd: config.cwd || process.cwd(),
    });

    const conn = {
      proc,
      sessionId: config.resume || null,
      listeners: new Set(),
      alive: true,
      _stdoutBuf: '',
      _currentToolId: null,
      _textBlockOpen: false,
      _thinkingBlockOpen: false,
    };

    // Strict \n JSONL parsing (same pattern as pi-provider)
    proc.stdout.on('data', (chunk) => {
      conn._stdoutBuf += chunk.toString('utf8');
      let nl;
      while ((nl = conn._stdoutBuf.indexOf('\n')) !== -1) {
        let line = conn._stdoutBuf.slice(0, nl);
        conn._stdoutBuf = conn._stdoutBuf.slice(nl + 1);
        if (line.endsWith('\r')) line = line.slice(0, -1);
        if (!line) continue;
        try {
          const parsed = JSON.parse(line);
          this._emitRaw(conn, {
            direction: 'in',
            transport: 'stdio',
            raw: line,
            payload: parsed,
          });
          this._handleEvent(conn, parsed);
        } catch (err) {
          console.error(`[claude-provider] parse/handle error: ${err.message}, line: ${line.slice(0, 200)}`);
        }
      }
    });

    proc.stderr.on('data', (d) => {
      const t = d.toString().trim();
      if (!t) return;
      this._emitRaw(conn, {
        direction: 'err',
        transport: 'stderr',
        raw: t,
        payload: { type: 'stderr', text: t },
      });
      console.error(`[claude-provider] stderr: ${t}`);
      // If resume fails, mark session ID as invalid so caller can retry
      if (t.includes('No conversation found')) {
        conn._resumeFailed = true;
      }
    });

    proc.on('exit', (code, signal) => {
      conn.alive = false;
      const isClean = signal === 'SIGTERM' || signal === 'SIGINT' || code === 143 || code === 130;
      if (conn._resumeFailed) {
        // Resume failed — emit special event so session layer can retry without resume
        this._emit(conn, { type: 'resume_failed' });
        return;
      }
      if (code !== 0 && !isClean) {
        this._emit(conn, E.turnError(`Claude exited with code ${code}`));
      }
      this._emit(conn, E.sessionClosed(isClean ? 'normal' : `exit ${code}`));
    });

    proc.on('error', (err) => {
      conn.alive = false;
      this._emit(conn, E.turnError(`Failed to spawn Claude: ${err.message}`));
      this._emit(conn, E.sessionClosed(err.message));
    });

    return conn;
  }

  send(conn, message) {
    if (!conn.alive || !conn.proc.stdin.writable) return;
    const payload = {
      type: 'user',
      uuid: crypto.randomUUID(),
      session_id: conn.sessionId || '',
      parent_tool_use_id: null,
      message: { role: 'user', content: [{ type: 'text', text: message }] },
    };
    this._emitRaw(conn, {
      direction: 'out',
      transport: 'stdio',
      raw: JSON.stringify(payload),
      payload,
    });
    conn.proc.stdin.write(JSON.stringify(payload) + '\n');
  }

  onEvent(conn, callback) {
    conn.listeners.add(callback);
    return () => conn.listeners.delete(callback);
  }

  respondPermission(conn, requestId, allowed) {
    if (!conn.alive || !conn.proc.stdin.writable) return;
    const payload = {
      type: 'control_response',
      response: {
        request_id: requestId,
        subtype: 'success',
        result: { behavior: allowed ? 'allow' : 'deny' },
      },
    };
    this._emitRaw(conn, {
      direction: 'out',
      transport: 'stdio',
      raw: JSON.stringify(payload),
      payload,
      summary: 'control_response',
    });
    conn.proc.stdin.write(JSON.stringify(payload) + '\n');
  }

  interrupt(conn) {
    if (!conn.alive) return;
    if (conn.proc.stdin.writable) {
      const payload = {
        request_id: Math.random().toString(36).substring(2, 15),
        type: 'control_request',
        request: { subtype: 'interrupt' },
      };
      this._emitRaw(conn, {
        direction: 'out',
        transport: 'stdio',
        raw: JSON.stringify(payload),
        payload,
        summary: 'interrupt',
      });
      conn.proc.stdin.write(JSON.stringify(payload) + '\n');
    } else {
      conn.proc.kill('SIGINT');
    }
  }

  close(conn) {
    conn.alive = false;
    try {
      conn.proc.kill('SIGTERM');
    } catch {}
  }

  // ── Internal ──

  _emit(conn, event) {
    for (const fn of conn.listeners) fn(event);
  }

  _emitRaw(conn, event) {
    this._emit(conn, E.rawEvent(event));
  }

  _handleEvent(conn, parsed) {
    switch (parsed.type) {
      case 'system':
        if (parsed.subtype === 'init' && parsed.session_id) {
          conn.sessionId = parsed.session_id;
          this._emit(conn, E.sessionReady(parsed.session_id));
        }
        break;

      case 'stream_event':
        this._handleStreamEvent(conn, parsed.event);
        break;

      case 'assistant':
        // Final assembled message — skip (already streamed via stream_event deltas)
        break;

      case 'user':
        // Tool results from Claude's internal tool loop
        if (parsed.message?.content) {
          for (const block of parsed.message.content) {
            if (block.type === 'tool_result') {
              const text =
                typeof block.content === 'string'
                  ? block.content
                  : Array.isArray(block.content)
                    ? block.content.map((c) => c.text || '').join('')
                    : '';
              this._emit(conn, E.toolResult(block.tool_use_id, text, block.is_error || false));
            }
          }
        }
        break;

      case 'result': {
        const u = parsed.usage;
        if (u) {
          const contextUsed =
            (u.input_tokens || 0) +
            (u.cache_creation_input_tokens || 0) +
            (u.cache_read_input_tokens || 0);
          this._emit(
            conn,
            E.usageUpdate({
              inputTokens: u.input_tokens,
              outputTokens: u.output_tokens,
              cacheRead: u.cache_read_input_tokens,
              cacheWrite: u.cache_creation_input_tokens,
              totalTokens: contextUsed,
            }),
          );
        }
        // Detect errors: explicit subtype, is_error flag, or API error status
        const isError = parsed.subtype === 'error' || parsed.is_error || parsed.api_error_status;
        if (isError) {
          const errMsg = parsed.error
            || (parsed.api_error_status ? `API error (HTTP ${parsed.api_error_status})` : null)
            || 'Unknown error';
          this._emit(conn, E.turnError(errMsg));
        } else {
          this._emit(
            conn,
            E.turnComplete(u ? { inputTokens: u.input_tokens, outputTokens: u.output_tokens } : undefined),
          );
        }
        break;
      }

      case 'rate_limit_event': {
        const rli = parsed.rate_limit_info || {};
        this._emit(
          conn,
          E.usageUpdate({
            fiveHour: rli.status ? { status: rli.status, resetsAt: rli.resetsAt } : undefined,
          }),
        );
        break;
      }

      case 'control_request':
        // Auto-approve tool permissions
        if (parsed.request?.subtype === 'can_use_tool' && conn.proc.stdin.writable) {
          const payload = {
            type: 'control_response',
            response: {
              request_id: parsed.request_id,
              subtype: 'success',
              result: { behavior: 'allow', updatedInput: parsed.request?.input },
            },
          };
          this._emitRaw(conn, {
            direction: 'out',
            transport: 'stdio',
            raw: JSON.stringify(payload),
            payload,
            summary: 'control_response',
          });
          conn.proc.stdin.write(JSON.stringify(payload) + '\n');
        }
        break;

      case 'control_response':
      case 'keep_alive':
        break;
    }
  }

  _handleStreamEvent(conn, ev) {
    if (!ev?.type) return;

    switch (ev.type) {
      case 'message_start':
        this._emit(conn, E.turnStart());
        break;

      case 'content_block_start': {
        const block = ev.content_block;
        if (!block) break;
        if (block.type === 'tool_use') {
          conn._currentToolId = block.id;
          this._emit(conn, E.toolStart(block.id, block.name, block.input || {}));
        } else if (block.type === 'thinking') {
          conn._thinkingBlockOpen = true;
          console.log(`[claude-prov] thinking block START`);
          this._emit(conn, E.thinkingDelta(''));
        } else if (block.type === 'text') {
          conn._textBlockOpen = true;
        }
        break;
      }

      case 'content_block_delta': {
        const delta = ev.delta;
        if (!delta) break;
        if (delta.type === 'text_delta' && delta.text) {
          this._emit(conn, E.textDelta(delta.text));
        } else if (delta.type === 'thinking_delta' && delta.thinking) {
          console.log(`[claude-prov] thinking_delta len=${delta.thinking.length}`);
          this._emit(conn, E.thinkingDelta(delta.thinking));
        } else if (delta.type === 'input_json_delta' && delta.partial_json && conn._currentToolId) {
          this._emit(conn, E.toolInputDelta(conn._currentToolId, delta.partial_json));
        }
        break;
      }

      case 'content_block_stop':
        if (conn._textBlockOpen) {
          this._emit(conn, E.textDone(''));
          conn._textBlockOpen = false;
        }
        if (conn._thinkingBlockOpen) {
          this._emit(conn, E.thinkingDone(''));
          conn._thinkingBlockOpen = false;
        }
        if (conn._currentToolId) {
          conn._currentToolId = null;
        }
        break;

      case 'message_delta':
        // Contains stop_reason and usage — handled at result level
        break;

      case 'message_stop':
        // End of streaming — turnComplete comes from result event
        break;
    }
  }
}
