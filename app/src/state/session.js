/**
 * Session state — manages a single Claude conversation.
 *
 * Each session has: messages, busy state, error, model, effort level.
 * Messages are assembled from streaming io_message events.
 */

import { on, launchAgent, sendMessage, interrupt, closeChannel, request } from '../lib/protocol.js';

let sessionIdCounter = 0;

function defaultConversationId(resume) {
  return resume ? `session:${resume}` : `conv_${crypto.randomUUID()}`;
}

export function createSession({ resume, cwd, model, provider, agentId, conversationId } = {}) {
  const channelId = `ch_${++sessionIdCounter}_${Date.now()}`;

  const session = {
    agentId: agentId || null,
    channelId,
    conversationId: conversationId || defaultConversationId(resume),
    messages: [],
    busy: false,
    error: null,
    summary: resume ? 'Resuming...' : 'New conversation',
    sessionId: resume || null,
    model: model || null,
    provider: provider || null,
    effortLevel: 'default',
    permissionRequests: [],
    lastModified: Date.now(),

    // Listeners
    _listeners: new Set(),
    _currentAssistantMessage: null,

    notify() {
      for (const fn of this._listeners) fn();
    },

    subscribe(fn) {
      this._listeners.add(fn);
      return () => this._listeners.delete(fn);
    },

    /** Load saved messages from a resumed session. */
    loadMessages(savedMessages) {
      const loaded = [];
      for (const msg of savedMessages) {
        if (msg.type === 'user' || msg.message?.role === 'user') {
          let content = msg.message?.content || msg.content || [];
          // Handle double-encoded content (stream-json sessions store content as a JSON string)
          if (typeof content === 'string') {
            try {
              const parsed = JSON.parse(content);
              if (parsed.message?.content) content = parsed.message.content;
              else if (Array.isArray(parsed)) content = parsed;
              else content = [];
            } catch {
              content = [];
            }
          }
          if (!Array.isArray(content)) content = [];

          // Check if this user message contains tool_result blocks
          const toolResults = content.filter((b) => b.type === 'tool_result');
          if (toolResults.length > 0) {
            // Pair tool results with tool_use blocks in the last assistant message
            const lastAssistant = loaded.findLast((m) => m.type === 'assistant');
            if (lastAssistant) {
              for (const tr of toolResults) {
                const toolBlock = lastAssistant.content.find(
                  (b) => b.content?.type === 'tool_use' && b.content.id === tr.tool_use_id,
                );
                if (toolBlock) {
                  const resultContent = Array.isArray(tr.content)
                    ? tr.content.map((c) => c.text || '').join('')
                    : typeof tr.content === 'string' ? tr.content : '';
                  toolBlock.toolResult = { value: resultContent };
                }
              }
            }
            continue; // Don't add tool_result messages as separate user messages
          }

          const text = content.map((b) => b.text || '').join('');
          if (text) {
            loaded.push({
              type: 'user',
              _uuid: msg.uuid,
              _sessionId: this.sessionId,
              content: content.map((b) => ({ content: b })),
            });
            if (this.summary === 'New conversation' || this.summary === 'Resuming...') {
              this.summary = text.slice(0, 60);
            }
          }
        } else if (msg.type === 'assistant' || msg.message?.role === 'assistant') {
          let content = msg.message?.content || msg.content || [];
          if (typeof content === 'string') {
            try {
              const parsed = JSON.parse(content);
              if (parsed.message?.content) content = parsed.message.content;
              else if (Array.isArray(parsed)) content = parsed;
              else content = [];
            } catch {
              content = [];
            }
          }
          if (!Array.isArray(content)) content = [];
          loaded.push({
            type: 'assistant',
            content: content.map((b) => ({ content: b, toolResult: { value: null } })),
          });
        }
      }
      if (loaded.length > 0) {
        this.messages = loaded;
        this.notify();
      }
    },

    _launched: false,

    /** Start the Claude CLI process for this session. */
    launch() {
      if (this._launched) return;
      this._launched = true;
      launchAgent(channelId, {
        resume: this.sessionId || undefined,
        agentId: this.agentId || undefined,
        provider: this.provider || undefined,
        conversationId: this.conversationId,
      });
      this.notify();
    },

    /** Send a user message with optional attachments. */
    send(text, attachments) {
      this.launch();

      if (this.summary === 'New conversation' || this.summary === 'Resuming...') {
        this.summary = text.slice(0, 60);
      }

      // Build content blocks
      const contentBlocks = [];
      if (text) contentBlocks.push({ type: 'text', text });
      if (attachments?.length) {
        for (const a of attachments) {
          if (a.isImage && a.data) {
            const [header, base64] = a.data.split(',');
            const mediaType = header.match(/:(.*?);/)?.[1] || 'image/png';
            contentBlocks.push({
              type: 'image',
              source: { type: 'base64', media_type: mediaType, data: base64 },
            });
          }
        }
      }

      const msgUuid = crypto.randomUUID();
      this.messages = [
        ...this.messages,
        {
          type: 'user',
          _uuid: msgUuid,
          _sessionId: this.sessionId,
          content: contentBlocks.map((b) => ({ content: b })),
        },
      ];
      this.error = null;
      if (!this.busy) {
        this.busy = true;
      }
      this.notify();

      sendMessage(
        channelId,
        {
          type: 'user',
          uuid: msgUuid,
          session_id: this.sessionId || '',
          parent_tool_use_id: null,
          message: {
            role: 'user',
            content: contentBlocks,
          },
        },
        this.agentId || undefined,
        this.conversationId,
      );
    },

    /** Interrupt the current response. */
    interrupt() {
      interrupt(channelId, this.agentId || undefined, this.conversationId);
    },

    /** Close this session's channel. */
    close() {
      closeChannel(channelId, this.agentId || undefined, this.conversationId);
    },

    /** Handle an incoming io_message from Claude. */
    _handleIO(msg) {
      const event = msg.message;
      if (!event) return;

      // Unwrap stream_event wrapper
      const inner = event.type === 'stream_event' ? event.event : event;
      if (!inner) return;

      this._processEvent(inner);
      this.lastModified = Date.now();
      this.notify();
    },

    _processEvent(event) {
      switch (event.type) {
        // Claude CLI sends 'assistant' type for the full/partial assistant message
        case 'assistant': {
          const msg = event.message;
          if (msg?.stop_reason === 'error' || msg?.content?.[0]?.text?.startsWith('API Error')) {
            this.error = msg.content?.[0]?.text || 'API Error';
            this.busy = false;
            break;
          }
          if (msg?.role === 'assistant') {
            const newContent = (msg.content || []).map((block) => ({
              content: block,
              toolResult: { value: null },
            }));

            if (this._currentAssistantMessage) {
              // Accumulate: Claude CLI sends each block as a separate assistant event.
              // We must APPEND new blocks, not replace, or earlier blocks vanish.
              const existing = this._currentAssistantMessage.content || [];

              // Build sets for dedup
              const existingToolIds = new Set();
              const resultMap = new Map();
              for (const b of existing) {
                if (b.content?.type === 'tool_use' && b.content?.id) {
                  existingToolIds.add(b.content.id);
                  if (b.toolResult?.value) resultMap.set(b.content.id, b.toolResult);
                }
              }

              const toAppend = [];
              for (const b of newContent) {
                const isToolUse = b.content?.type === 'tool_use' && b.content?.id;
                if (isToolUse && existingToolIds.has(b.content.id)) {
                  // Update existing tool_use block input + preserve result
                  const eb = existing.find((e) => e.content?.id === b.content.id);
                  if (eb) {
                    eb.content.input = b.content.input;
                    if (!eb.toolResult?.value && resultMap.has(b.content.id))
                      eb.toolResult = resultMap.get(b.content.id);
                  }
                } else if (b.content?.type === 'text') {
                  // Text block: update last text if it's the trailing block, else append
                  const last = existing[existing.length - 1] || toAppend[toAppend.length - 1];
                  if (last?.content?.type === 'text' && toAppend.length === 0) {
                    // Streaming update to the last text block
                    last.content.text = b.content.text;
                  } else {
                    toAppend.push(b);
                  }
                } else if (b.content?.type === 'thinking') {
                  // Thinking: update last thinking or append
                  const lastThinking = existing.findLast((e) => e.content?.type === 'thinking');
                  if (lastThinking) {
                    lastThinking.content.thinking = b.content.thinking;
                  } else {
                    toAppend.push(b);
                  }
                } else {
                  toAppend.push(b);
                }
                // Preserve tool results
                if (isToolUse && resultMap.has(b.content.id)) {
                  b.toolResult = resultMap.get(b.content.id);
                }
              }

              const merged = [...existing, ...toAppend];
              const updated = { type: 'assistant', _uuid: event.uuid, _sessionId: this.sessionId, content: merged };
              const existingIdx = this.messages.indexOf(this._currentAssistantMessage);
              this._currentAssistantMessage = updated;
              if (existingIdx >= 0) {
                this.messages = [
                  ...this.messages.slice(0, existingIdx),
                  updated,
                  ...this.messages.slice(existingIdx + 1),
                ];
              }
            } else {
              const updated = { type: 'assistant', _uuid: event.uuid, _sessionId: this.sessionId, content: newContent };
              this._currentAssistantMessage = updated;
              this.messages = [...this.messages, updated];
            }
          }
          break;
        }

        case 'message_start': {
          const message = event.message;
          if (message?.role === 'assistant') {
            this._currentAssistantMessage = {
              type: 'assistant',
              content: [],
            };
            this.messages = [...this.messages, this._currentAssistantMessage];
          }
          break;
        }

        case 'content_block_start': {
          // Safety: if no assistant message is open, create one so deltas have somewhere to go
          if (!this._currentAssistantMessage) {
            this._currentAssistantMessage = { type: 'assistant', content: [] };
            this.messages = [...this.messages, this._currentAssistantMessage];
          }
          if (event.content_block) {
            // Deduplicate: Claude CLI with --include-partial-messages can send
            // the same content_block_start twice for the same tool_use ID
            const blockId = event.content_block.id;
            if (blockId && this._currentAssistantMessage.content.some((b) => b.content?.id === blockId)) break;

            this._currentAssistantMessage.content.push({
              content: event.content_block,
              toolResult: { value: null },
            });
            this.messages = [...this.messages];
          }
          break;
        }

        case 'content_block_delta': {
          // Safety: if no assistant message is open, create one
          if (!this._currentAssistantMessage) {
            this._currentAssistantMessage = { type: 'assistant', content: [] };
            this.messages = [...this.messages, this._currentAssistantMessage];
          }
          const blocks = this._currentAssistantMessage.content;
          let lastBlock = blocks[blocks.length - 1];

          const delta = event.delta;
          // If no block exists or the block type doesn't match the delta, create one
          if (delta?.type === 'text_delta' && delta.text) {
            if (!lastBlock || lastBlock.content.type !== 'text') {
              lastBlock = { content: { type: 'text', text: '' }, toolResult: { value: null } };
              blocks.push(lastBlock);
            }
            lastBlock.content.text = (lastBlock.content.text || '') + delta.text;
          } else if (delta?.type === 'thinking_delta' && delta.thinking) {
            if (!lastBlock || lastBlock.content.type !== 'thinking') {
              lastBlock = { content: { type: 'thinking', thinking: '' }, toolResult: { value: null } };
              blocks.push(lastBlock);
            }
            lastBlock.content.thinking = (lastBlock.content.thinking || '') + delta.thinking;
          } else if (delta?.type === 'input_json_delta' && delta.partial_json) {
            if (lastBlock.content.type === 'tool_use') {
              lastBlock.content._partialInput = (lastBlock.content._partialInput || '') + delta.partial_json;
              try {
                lastBlock.content.input = JSON.parse(lastBlock.content._partialInput);
              } catch {}
            }
          }
          this.messages = [...this.messages];
          break;
        }

        case 'content_block_stop': {
          this.messages = [...this.messages];
          break;
        }

        case 'message_delta': {
          if (event.delta?.stop_reason) {
            this.busy = false;
          }
          this.messages = [...this.messages];
          break;
        }

        case 'message_stop': {
          this.busy = false;
          this._currentAssistantMessage = null;
          this.messages = [...this.messages];
          break;
        }

        case 'error': {
          this.error = event.error?.message || 'Unknown error';
          this.busy = false;
          break;
        }

        // User type message = tool result from CLI
        case 'user': {
          const msg = event.message;
          if (msg?.role === 'user' && msg?.content) {
            // Find matching tool_use blocks in the LAST assistant message and attach results
            const lastAssistant = [...this.messages].reverse().find((m) => m.type === 'assistant');
            if (lastAssistant) {
              for (const block of msg.content) {
                if (block.type === 'tool_result' && block.tool_use_id) {
                  for (const aBlock of lastAssistant.content) {
                    if (aBlock.content?.type === 'tool_use' && aBlock.content.id === block.tool_use_id) {
                      aBlock.toolResult = {
                        value:
                          typeof block.content === 'string'
                            ? block.content
                            : Array.isArray(block.content)
                              ? block.content.map((c) => c.text || '').join('\n')
                              : JSON.stringify(block.content),
                        is_error: block.is_error || false,
                      };
                    }
                  }
                }
              }
            }
            this.messages = [...this.messages];
          }
          break;
        }

        // Result = Claude finished responding
        case 'result': {
          this.busy = false;
          this._currentAssistantMessage = null;
          // Update summary from result if available
          if (event.result && typeof event.result === 'string') {
            // Short result text can serve as session summary
          }
          this.messages = [...this.messages];
          break;
        }

        // System init message from CLI — save the real session ID
        case 'system': {
          if (event.session_id) {
            this.sessionId = event.session_id;
            // Persist under the owning agent, not the currently focused one.
            if (this.agentId) {
              localStorage.setItem(`cmx-session-${this.agentId}`, event.session_id);
              if (this.provider) {
                localStorage.setItem(`cmx-session-${this.agentId}-${this.provider}`, event.session_id);
              }
              localStorage.setItem(`cmx-conversation-${this.agentId}`, this.conversationId);
              if (this.provider) {
                localStorage.setItem(`cmx-conversation-${this.agentId}-${this.provider}`, this.conversationId);
              }
            }
            localStorage.setItem(`cmx-conversation-session-${event.session_id}`, this.conversationId);
          }
          break;
        }
      }
    },

    /** Handle channel close. */
    _handleClose(msg) {
      this.busy = false;
      if (msg.error) {
        this.error = msg.error;
      }
      this.notify();
    },

    /** Handle incoming permission request. */
    _handleRequest(msg) {
      this.permissionRequests = [...this.permissionRequests, msg];
      this.notify();
    },
  };

  // Subscribe to messages for this channel — store unsubs for cleanup
  const unsubs = [
    on('io_message', (msg) => {
      if (msg.channelId === channelId) session._handleIO(msg);
    }),
    on('close_channel', (msg) => {
      if (msg.channelId === channelId) session._handleClose(msg);
    }),
    on('request', (msg) => {
      if (msg.request?.channelId === channelId) session._handleRequest(msg);
    }),
  ];

  /** Remove all protocol listeners for this session. */
  session.dispose = () => {
    for (const unsub of unsubs) unsub();
    unsubs.length = 0;
  };

  return session;
}
