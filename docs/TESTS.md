# Test Suite

29 Playwright tests across 3 test files. Run with `npm test` or `npx playwright test`.

## tests/ui.spec.js (10 tests)

Core UI functionality.

- Page load: renders without errors
- Sidebar: all agents visible, alphabetical
- Backend badges: each agent shows backend badge
- Top bar: shows agent name, backend, model
- Send via Enter: message appears in chat
- Send via button: click send, message appears
- Message display: user and assistant messages render
- Agent switching: click agent → top bar updates
- Rapid agent switching: 10 agents fast — no crash
- Backend dropdown: opens with all backends listed

## tests/reliability.spec.js (13 tests)

Every production bug gets a regression test.

- Send via Enter delivers message
- Send via button delivers message
- Send button state: enabled when not busy
- Input clears after send
- Agent switch updates top bar immediately
- Messages preserved on switch-back
- Rapid 10-agent switch: no crash, correct state
- Backend dropdown: all backends present
- Backend switch: badge updates
- Backend isolation: switching one agent doesn't affect another
- Reload persistence: agent + send survive reload
- No stale "default" in badges or top bar
- No page errors: zero uncaught exceptions

## tests/mobile.spec.js (3 tests)

Mobile viewport (iPhone 14).

- Page loads at mobile viewport
- No horizontal overflow
- Can type in input

## Running

```bash
npx playwright test              # all tests
npx playwright test ui.spec.js   # just UI tests
npx playwright test --headed     # watch in browser
```

Video and screenshots saved to `test-results/` on failure.
