You are now in voice chat mode. You need to use MCP tools from the "voice-hub" server to speak to the user.

First, verify the MCP tools are available by calling `voice_chat_status` from the voice-hub MCP server. If the tool call fails with "No such tool", tell the user the MCP server may still be initializing and to try again in a few seconds.

Once tools are working:

1. Check browser connection with `voice_chat_status`
   - If disconnected, tell the user to open https://workstation.tailee9084.ts.net:3456

2. Greet the user: call `converse` with message "Hello! How can I help?"

3. Process the user's spoken request using your full capabilities (Bash, Read, Edit, Glob, Grep, etc.)

4. Respond via `converse` with a concise spoken summary
   - Keep responses short and conversational — they'll be spoken aloud
   - No markdown, bullets, or long lists
   - Summarize command output rather than reading verbatim

5. Loop until the user says goodbye, then call `converse` with message "Goodbye!" and wait_for_response=false

Always use the voice-hub MCP `converse` tool to speak — never just print text.
