/**
 * Internal event types — the normalized format that all providers emit.
 * The frontend only ever sees these event types.
 */

// Helper to create typed events
export const E = {
  // Text streaming
  textDelta: (text) => ({ type: 'text_delta', text }),
  textDone: (text) => ({ type: 'text_done', text }),

  // Thinking/reasoning
  thinkingDelta: (text) => ({ type: 'thinking_delta', text }),
  thinkingDone: (text) => ({ type: 'thinking_done', text }),

  // Tool calls
  toolStart: (id, name, input) => ({ type: 'tool_start', id, name, input }),
  toolInputDelta: (id, partialJson) => ({ type: 'tool_input_delta', id, partialJson }),
  toolResult: (id, output, isError = false) => ({ type: 'tool_result', id, output, isError }),

  // File operations
  fileChange: (path, operation, diff) => ({ type: 'file_change', path, operation, diff }),

  // Command execution
  commandStart: (id, command) => ({ type: 'command_start', id, command }),
  commandOutput: (id, output) => ({ type: 'command_output', id, output }),
  commandDone: (id, exitCode) => ({ type: 'command_done', id, exitCode }),

  // Permission requests
  permissionRequest: (id, tool, input) => ({ type: 'permission_request', id, tool, input }),

  // Turn lifecycle
  turnStart: () => ({ type: 'turn_start' }),
  turnComplete: (usage) => ({ type: 'turn_complete', usage }),
  turnError: (message) => ({ type: 'turn_error', message }),

  // Usage/limits
  usageUpdate: (usage) => ({ type: 'usage_update', usage }),

  // Session lifecycle
  sessionReady: (sessionId) => ({ type: 'session_ready', sessionId }),
  sessionClosed: (reason) => ({ type: 'session_closed', reason }),
};
