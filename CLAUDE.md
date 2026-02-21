# Voice Hub Development

## hub.html is fragile

`static/hub.html` is a single-file application with all JS inline. A syntax error anywhere in the `<script>` block kills the entire page — the WebSocket never connects and the UI shows "Connecting..." with no useful error for the user.

**After editing hub.html, always verify there are no JS syntax errors.** Common mistakes:
- Missing trailing commas in object literals (especially when adding entries to `VOICE_NAMES`, `VOICE_COLORS`, `VOICE_ICONS`)
- Mismatched braces or brackets
- Unterminated template literals

Quick check: open the browser console and look for `SyntaxError` before assuming the hub or network is broken.
