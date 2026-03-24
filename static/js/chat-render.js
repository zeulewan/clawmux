// ClawMux — Chat Render Module
// Message rendering, markdown processing, agent message parsing.
// Dependencies: sidebar.js (voiceColor, voiceDisplayName, VOICE_NAMES),
//   state.js (sessions, activeSessionId), marked.js, DOMPurify, hljs, KaTeX

// --- Agent message helpers ---
const _AGENT_MSG_RE = /^\[Agent msg (from|to) (\w+)\] ([\s\S]*)$/;
const _GROUP_MSG_RE = /^\[Group msg to ([^\]]+)\] ([\s\S]*)$/;
// Injection prefix patterns (from transcripts)
const _INJECT_MSG_RE = /^\[MSG id:\S+ from:(\w+)\]\s*([\s\S]*)$/;
const _INJECT_VOICE_RE = /^\[VOICE id:\S+ from:(\w+)\]\s*([\s\S]*)$/;
const _INJECT_GROUP_RE = /^\[GROUP:(\S+) id:\S+ from:(\w+)\]\s*([\s\S]*)$/;
const _INJECT_ACK_RE = /^\[ACK from:(\w+) on:\S+\]$/;
const _INJECT_SYSTEM_RE = /^\[SYSTEM\]\s*([\s\S]*)$/;

/** Create a collapsible system message (collapsed by default, click to expand). */
function _createCollapsibleSystemMsg(div, label, content, color) {
  div.className = 'msg agent-msg';
  div.style.cssText = 'padding:3px 10px;margin:2px 0;font-size:0.82em;opacity:0.5;cursor:pointer;';
  const hdr = document.createElement('span');
  hdr.style.cssText = `color:${color};font-weight:600;font-size:0.9em;`;
  hdr.textContent = '\u2139 ' + label;
  div.appendChild(hdr);
  const body = document.createElement('div');
  body.className = 'agent-msg-body';
  body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;white-space:pre-wrap;max-height:200px;overflow-y:auto;';
  body.textContent = content;
  div.appendChild(body);
  div.addEventListener('click', (e) => {
    if (e.target.closest('.msg-actions')) return;
    const showing = body.style.display !== 'none';
    body.style.display = showing ? 'none' : 'block';
    div.style.opacity = showing ? '0.5' : '1';
  });
  return div;
}

/** Look up a voice color by display name (e.g. "Sky" → "#3A86FF"). */
function _voiceColorByName(name) {
  const lower = name.toLowerCase();
  for (const [id, dname] of Object.entries(VOICE_NAMES)) {
    if (dname.toLowerCase() === lower) return voiceColor(id);
  }
  return '#888';
}

// --- Message Rendering ---
function _renderMarkdown(text) {
  if (typeof marked === 'undefined' || typeof DOMPurify === 'undefined') return null;

  try {
    // Protect math blocks from marked.js processing
    const mathBlocks = [];
    let protectedText = text;
    // Display math $$...$$
    protectedText = protectedText.replace(/\$\$([\s\S]*?)\$\$/g, (m) => {
      mathBlocks.push(m);
      return `MATHBLOCK${mathBlocks.length - 1}ENDMATH`;
    });
    // Inline math $...$
    protectedText = protectedText.replace(/\$([^\$\n]+?)\$/g, (m) => {
      mathBlocks.push(m);
      return `MATHBLOCK${mathBlocks.length - 1}ENDMATH`;
    });

    let html = marked.parse(protectedText, { breaks: true, gfm: true });

    // Restore math blocks
    html = html.replace(/MATHBLOCK(\d+)ENDMATH/g, (_, i) => mathBlocks[parseInt(i)]);

    // Sanitize HTML
    html = DOMPurify.sanitize(html, {
      ALLOWED_TAGS: ['p', 'br', 'strong', 'em', 'code', 'pre', 'ul', 'ol', 'li',
        'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'a', 'blockquote', 'table', 'thead',
        'tbody', 'tr', 'th', 'td', 'hr', 'img', 'span', 'div', 'del', 'sup', 'sub'],
      ALLOWED_ATTR: ['href', 'src', 'alt', 'class', 'style', 'target'],
    });

    // Create container
    const container = document.createElement('div');
    container.className = 'md-content';
    container.innerHTML = html;

    // Syntax-highlight code blocks with highlight.js
    if (typeof hljs !== 'undefined') {
      container.querySelectorAll('pre code').forEach(block => {
        hljs.highlightElement(block);
      });
    }

    // Make links open in new tab
    container.querySelectorAll('a').forEach(a => { a.target = '_blank'; a.rel = 'noopener'; });

    // Add language label + copy button to code blocks
    container.querySelectorAll('pre').forEach(pre => {
      const code = pre.querySelector('code');
      // Language label from hljs class e.g. "language-python" → "python"
      if (code) {
        const langClass = Array.from(code.classList).find(c => c.startsWith('language-'));
        if (langClass) {
          const lang = langClass.replace('language-', '');
          const label = document.createElement('span');
          label.className = 'code-lang-label';
          label.textContent = lang;
          pre.appendChild(label);
        }
      }
      const btn = document.createElement('button');
      btn.className = 'code-copy-btn';
      btn.textContent = 'Copy';
      btn.onclick = (e) => {
        e.stopPropagation();
        const text = code ? code.textContent : pre.textContent;
        navigator.clipboard.writeText(text).then(() => {
          btn.textContent = 'Copied!';
          setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
        }).catch(() => { btn.textContent = 'Error'; setTimeout(() => { btn.textContent = 'Copy'; }, 1500); });
      };
      pre.appendChild(btn);
    });

    // Wrap tables in scrollable container for mobile horizontal scroll
    container.querySelectorAll('table').forEach(table => {
      const wrapper = document.createElement('div');
      wrapper.className = 'md-table-scroll';
      table.parentNode.insertBefore(wrapper, table);
      wrapper.appendChild(table);
    });

    // Click-to-copy for inline code
    container.querySelectorAll('code:not(pre code)').forEach(code => {
      code.onclick = (e) => {
        e.stopPropagation();
        navigator.clipboard.writeText(code.textContent).then(() => {
          if (typeof showCopyToast === 'function') showCopyToast();
        });
      };
    });

    // Render KaTeX math ($$...$$ and $...$)
    if (typeof renderMathInElement === 'function') {
      renderMathInElement(container, {
        delimiters: [
          { left: '$$', right: '$$', display: true },
          { left: '$', right: '$', display: false },
          { left: '\\[', right: '\\]', display: true },
          { left: '\\(', right: '\\)', display: false },
        ],
        throwOnError: false,
      });
    }

    // Lazy-load images — replace <img> with click-to-reveal placeholder
    container.querySelectorAll('img').forEach(img => {
      const src = img.getAttribute('src') || '';
      const alt = img.alt || 'image';
      const wrap = document.createElement('div');
      wrap.className = 'chat-img-placeholder';
      const icon = document.createElement('span');
      icon.className = 'chat-img-icon';
      icon.textContent = '🖼';
      const label = document.createElement('span');
      label.className = 'chat-img-label';
      label.textContent = alt;
      const hint = document.createElement('span');
      hint.className = 'chat-img-hint';
      hint.textContent = 'click to load';
      wrap.append(icon, label, hint);
      wrap.onclick = () => {
        const actualImg = document.createElement('img');
        actualImg.src = src;
        actualImg.alt = alt;
        actualImg.className = 'chat-img-revealed';
        wrap.replaceWith(actualImg);
      };
      img.replaceWith(wrap);
    });

    // Wrap text nodes in karaoke-word spans for TTS highlighting compatibility
    _wrapTextNodesInKaraokeSpans(container);

    return container;
  } catch (e) {
    console.warn('Markdown render error:', e);
    return null;
  }
}

function createMsgEl(role, text, voiceColorHex, voiceId, msgObj = null) {
  const div = document.createElement('div');
  div.className = `msg ${role}`;
  if (msgObj && msgObj.id) div.dataset.msgId = msgObj.id;

  // --- Inter-agent messages: collapsed one-liner with click-to-expand ---
  const agentMatch = (role === 'system') ? _AGENT_MSG_RE.exec(text) : null;
  if (agentMatch) {
    const [, direction, agentName, content] = agentMatch;
    const color = _voiceColorByName(agentName);
    div.className = 'msg agent-msg';
    div.style.cssText = 'padding:3px 10px;margin:2px 0;font-size:0.82em;opacity:0.7;cursor:pointer;';

    // One-liner header: "→ Sky" or "← Echo"
    const arrow = direction === 'from' ? '\u2190' : '\u2192';
    const header = document.createElement('span');
    header.className = 'agent-msg-header';
    const nameSpan = document.createElement('span');
    nameSpan.style.cssText = `color:${color};font-weight:600`;
    nameSpan.textContent = `${arrow} ${agentName}`;
    header.appendChild(nameSpan);

    // Expandable body
    const body = document.createElement('div');
    body.className = 'agent-msg-body';
    const mdEl = (typeof marked !== 'undefined') ? _renderMarkdown(content) : null;
    if (mdEl) {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;';
      body.appendChild(mdEl);
    } else {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;white-space:pre-wrap;';
      body.textContent = content;
    }

    div.appendChild(header);
    div.appendChild(body);

    div.addEventListener('click', (e) => {
      if (e.target.closest('.msg-actions')) return;
      const showing = body.style.display !== 'none';
      body.style.display = showing ? 'none' : 'block';
      div.style.opacity = showing ? '0.7' : '1';
    });

    if (voiceId) div.dataset.voice = voiceId;
    if (text) div.dataset.text = text;
    return div;
  }

  // --- Group chat outbound messages: same collapsed style ---
  const groupMatch = (role === 'system') ? _GROUP_MSG_RE.exec(text) : null;
  if (groupMatch) {
    const [, groupName, content] = groupMatch;
    div.className = 'msg agent-msg';
    div.style.cssText = 'padding:3px 10px;margin:2px 0;font-size:0.82em;opacity:0.7;cursor:pointer;';

    const header = document.createElement('span');
    header.className = 'agent-msg-header';
    const nameSpan = document.createElement('span');
    nameSpan.style.cssText = 'color:#7c9ef0;font-weight:600';
    nameSpan.textContent = `\u2295 ${groupName}`;
    header.appendChild(nameSpan);

    const body = document.createElement('div');
    body.className = 'agent-msg-body';
    const mdEl2 = (typeof marked !== 'undefined') ? _renderMarkdown(content) : null;
    if (mdEl2) {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;';
      body.appendChild(mdEl2);
    } else {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;white-space:pre-wrap;';
      body.textContent = content;
    }

    div.appendChild(header);
    div.appendChild(body);
    div.addEventListener('click', (e) => {
      if (e.target.closest('.msg-actions')) return;
      const showing = body.style.display !== 'none';
      body.style.display = showing ? 'none' : 'block';
      div.style.opacity = showing ? '0.7' : '1';
    });

    if (voiceId) div.dataset.voice = voiceId;
    if (text) div.dataset.text = text;
    return div;
  }

  // --- Injection prefix parsing (from transcripts) ---
  if (role === 'user') {
    // [MSG id:xxx from:name] content — inter-agent message received
    const msgMatch = _INJECT_MSG_RE.exec(text);
    if (msgMatch) {
      const [, sender, content] = msgMatch;
      const color = _voiceColorByName(sender);
      div.className = 'msg agent-msg';
      div.style.cssText = 'padding:3px 10px;margin:2px 0;font-size:0.82em;opacity:0.7;cursor:pointer;';
      const hdr = document.createElement('span');
      hdr.innerHTML = `<span style="color:${color};font-weight:600">\u2190 ${sender.charAt(0).toUpperCase() + sender.slice(1)}</span>`;
      div.appendChild(hdr);
      const body = document.createElement('div');
      body.className = 'agent-msg-body';
      const md = (typeof marked !== 'undefined') ? _renderMarkdown(content) : null;
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;' + (md ? '' : 'white-space:pre-wrap;');
      if (md) body.appendChild(md); else body.textContent = content;
      div.appendChild(body);
      div.addEventListener('click', (e) => { if (!e.target.closest('.msg-actions')) { const s = body.style.display !== 'none'; body.style.display = s ? 'none' : 'block'; div.style.opacity = s ? '0.7' : '1'; } });
      if (voiceId) div.dataset.voice = voiceId;
      if (text) div.dataset.text = text;
      return div;
    }
    // [VOICE id:xxx from:user] content — user voice/text message (render as normal user bubble)
    const voiceMatch = _INJECT_VOICE_RE.exec(text);
    if (voiceMatch) {
      text = voiceMatch[2]; // strip prefix, render as normal user message
    }
    // [GROUP:name id:xxx from:sender] content — group message
    const groupMatch = _INJECT_GROUP_RE.exec(text);
    if (groupMatch) {
      const [, groupName, sender, content] = groupMatch;
      const color = _voiceColorByName(sender);
      div.className = 'msg agent-msg';
      div.style.cssText = 'padding:3px 10px;margin:2px 0;font-size:0.82em;opacity:0.7;cursor:pointer;';
      const hdr = document.createElement('span');
      hdr.innerHTML = `<span style="color:#7c9ef0;font-weight:600">\u2295 ${groupName}</span> <span style="color:${color};font-size:0.9em">${sender.charAt(0).toUpperCase() + sender.slice(1)}</span>`;
      div.appendChild(hdr);
      const body = document.createElement('div');
      body.className = 'agent-msg-body';
      const md = (typeof marked !== 'undefined') ? _renderMarkdown(content) : null;
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;' + (md ? '' : 'white-space:pre-wrap;');
      if (md) body.appendChild(md); else body.textContent = content;
      div.appendChild(body);
      div.addEventListener('click', (e) => { if (!e.target.closest('.msg-actions')) { const s = body.style.display !== 'none'; body.style.display = s ? 'none' : 'block'; div.style.opacity = s ? '0.7' : '1'; } });
      if (voiceId) div.dataset.voice = voiceId;
      if (text) div.dataset.text = text;
      return div;
    }
    // [ACK from:name on:xxx] — acknowledgment (subtle one-liner)
    const ackMatch = _INJECT_ACK_RE.exec(text);
    if (ackMatch) {
      const color = _voiceColorByName(ackMatch[1]);
      div.className = 'msg agent-msg';
      div.style.cssText = 'padding:2px 10px;margin:1px 0;font-size:0.75em;opacity:0.5;';
      div.innerHTML = `<span style="color:${color}">\uD83D\uDC4D ${ackMatch[1].charAt(0).toUpperCase() + ackMatch[1].slice(1)}</span>`;
      if (voiceId) div.dataset.voice = voiceId;
      return div;
    }
    // [SYSTEM] content — system notification (collapsible)
    const sysMatch = _INJECT_SYSTEM_RE.exec(text);
    if (sysMatch) {
      return _createCollapsibleSystemMsg(div, 'System', sysMatch[1], '#888');
    }
    // Catch-up context / startup prompts (collapsible)
    if (text.startsWith('# Messages Since You Were Last Active') || text.startsWith('Greet the user as instructed')) {
      const label = text.startsWith('# Messages') ? 'Catch-up Context' : 'Startup Prompt';
      return _createCollapsibleSystemMsg(div, label, text, '#666');
    }
  }

  if (role === 'assistant') {
    // Try markdown rendering first, fall back to karaoke word wrapping
    const mdEl = (typeof marked !== 'undefined') ? _renderMarkdown(text) : null;
    if (mdEl) {
      div.appendChild(mdEl);
    } else {
      _wrapWordsInSpans(div, text);
    }
  } else {
    div.textContent = text;
  }
  if (voiceId) div.dataset.voice = voiceId;
  if (text) div.dataset.text = text;
  if (role === 'assistant' && voiceColorHex) div.style.background = hexToRgba(voiceColorHex, 0.20);
  // Timestamp label (hover to reveal)
  if (role === 'user' || role === 'assistant' || role === 'user interjection') {
    const ts = msgObj && msgObj.ts ? msgObj.ts : Date.now() / 1000;
    const tsEl = document.createElement('span');
    tsEl.className = 'msg-ts';
    tsEl.textContent = new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    div.appendChild(tsEl);
  }
  if (role !== 'system' && role !== 'thinking') {
    const actions = document.createElement('div');
    actions.className = 'msg-actions';

    // Copy button
    const copyBtn = document.createElement('button');
    copyBtn.className = 'msg-action-btn';
    copyBtn.textContent = 'Copy';
    copyBtn.onclick = (e) => {
      e.stopPropagation();
      navigator.clipboard.writeText(text).then(() => showCopyToast()).catch(() => {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.cssText = 'position:fixed;opacity:0';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
        showCopyToast();
      });
    };
    actions.appendChild(copyBtn);

    // Thumbs-up (ack) button — only on non-user messages with an ID
    if (msgObj && msgObj.id && role !== 'user' && role !== 'user interjection') {
      const ackBtn = document.createElement('button');
      ackBtn.className = 'msg-action-btn msg-ack-btn';
      ackBtn.textContent = '\uD83D\uDC4D';
      ackBtn.title = 'Acknowledge';
      ackBtn.onclick = (e) => {
        e.stopPropagation();
        _sendUserAck(msgObj.id);
        div.dataset.selfAcked = '1'; // flag to absorb server echo
        // Store immediately so renderChat shows badge if called before server echo
        const _s = sessions.get(activeSessionId);
        if (_s) _s.messages.push({ role: 'system', text: '', ts: Date.now() / 1000, id: 'local-ack-' + msgObj.id, parentId: msgObj.id, isBareAck: true });
        _showPermanentAck(div, 1);
      };
      actions.appendChild(ackBtn);
    }

    div.appendChild(actions);
  }

  // Mobile: attach long-press directly to each message (matches sidebar pattern)
  if (isMobile && role !== 'thinking' && role !== 'system') {
    let lpTimer = null, lpFired = false, startX = 0, startY = 0;
    div.oncontextmenu = (e) => e.preventDefault();
    div.addEventListener('touchstart', (e) => {
      lpFired = false;
      const touch = e.touches[0];
      startX = touch.clientX; startY = touch.clientY;
      lpTimer = setTimeout(() => {
        lpTimer = null; lpFired = true;
        _longPressFired = true;
        div.classList.add('long-press-active');
        // Programmatically clear any native text selection
        const sel = window.getSelection();
        if (sel) sel.removeAllRanges();
        _showContextMenu(div, touch.clientX, touch.clientY);
        setTimeout(() => div.classList.remove('long-press-active'), 200);
      }, 400);
    }, { passive: false });
    div.addEventListener('touchend', (e) => {
      if (lpTimer) { clearTimeout(lpTimer); lpTimer = null; }
      if (lpFired) { e.preventDefault(); lpFired = false; }
    });
    div.addEventListener('touchmove', (e) => {
      if (lpTimer) {
        const t = e.touches[0];
        if (Math.abs(t.clientX - startX) > 10 || Math.abs(t.clientY - startY) > 10) {
          clearTimeout(lpTimer); lpTimer = null;
        }
      }
    }, { passive: true });
  }

  return div;
}

function _showPermanentAck(msgEl, count) {
  let badge = msgEl.querySelector('.msg-ack-permanent');
  if (badge) {
    badge.textContent = count > 1 ? '\uD83D\uDC4D ' + count : '\uD83D\uDC4D';
    badge.title = count + ' ack';
  } else {
    badge = document.createElement('span');
    badge.className = 'msg-ack-permanent';
    badge.textContent = '\uD83D\uDC4D';
    badge.title = '1 ack';
    // For agent messages, place badge inline inside the header (right next to arrow+name)
    if (msgEl.classList.contains('agent-msg')) {
      const header = msgEl.querySelector('.agent-msg-header');
      (header || msgEl).appendChild(badge);
    } else {
      msgEl.appendChild(badge);
    }
    // Make ack button invisible but keep it in flow so copy button doesn't shift position
    const ackBtn = msgEl.querySelector('.msg-ack-btn');
    if (ackBtn) { ackBtn.style.opacity = '0'; ackBtn.style.pointerEvents = 'none'; ackBtn.style.cursor = 'default'; }
  }
  badge.dataset.count = count || 1;
}

function _sendUserAck(msgId) {
  if (!activeSessionId || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ session_id: activeSessionId, type: 'user_ack', msg_id: msgId }));
}
