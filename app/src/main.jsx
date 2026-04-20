import React, { useEffect, useState } from 'react';
import ReactDOM from 'react-dom/client';
import './styles/webview.css';
import './styles/sidebar.css';
import { SessionView } from './components/SessionView.jsx';
import { Sidebar } from './components/Sidebar.jsx';
import { Monitor } from './components/Monitor.jsx';
// StatusBar is now integrated into SessionView header
import { init } from './state/sessions.js';

// CSS handles html/body/#root layout (flex:1, height:100%)

// The base CSS sets messageInput color to transparent (for mention mirror overlay).
// We don't use the mirror system, so make text visible.
const style = document.createElement('style');
style.textContent = `
  :root { --cmx-mobile-bottom-offset: 0px; --cmx-mobile-bottom-cushion: 0px; }
  html, body, #root { background-color: var(--app-primary-background) !important; }
  .messageInput { color: var(--app-input-foreground) !important; }
  /* Ensure Unicode math symbols render with a font that has them */
  .markdownContent, .toolBodyRowContent, .hintMessage {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif, "Apple Color Emoji", "Segoe UI Emoji" !important;
  }
  .userMessageContainer { display: block !important; width: 100% !important; }
  .userMessage { display: block !important; max-width: none !important; }
  .expandableContainer { max-width: 100% !important; }
  .messagesContainer { padding-bottom: calc(120px + var(--cmx-mobile-bottom-cushion, 0px)) !important; }
  .message.stickyHeader:hover .actionButton { opacity: 1 !important; }
  /* Collapsible tool blocks */
  .toolSummaryClickable {
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    background: none;
    border: none;
    color: inherit;
    font: inherit;
    text-align: left;
    padding: 4px 0;
  }
  .toolSummaryClickable:hover { opacity: 0.8; }
  .toolChevron {
    transition: transform 0.15s;
    flex-shrink: 0;
    opacity: 0.5;
  }
  .toolChevronOpen { transform: rotate(90deg); }
  /* Attachment preview */
  .attachment-preview {
    display: flex;
    gap: 8px;
    padding: 8px 12px 4px;
    flex-wrap: wrap;
  }
  .attachment-item {
    position: relative;
    border-radius: 8px;
    overflow: hidden;
    border: 1px solid var(--vscode-panel-border, #3c3c3c);
  }
  .attachment-thumb {
    height: 60px;
    max-width: 120px;
    object-fit: cover;
    display: block;
  }
  .attachment-file {
    display: block;
    padding: 8px 12px;
    font-size: 11px;
    color: var(--vscode-foreground, #ccc);
    max-width: 120px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .attachment-remove {
    position: absolute;
    top: 2px;
    right: 2px;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    border: none;
    background: rgba(0,0,0,0.6);
    color: white;
    font-size: 10px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
  }
  .attachment-remove:hover { background: rgba(255,0,0,0.6); }
  /* Drop overlay */
  .input-drag-active { border-color: var(--vscode-focusBorder, #0078d4) !important; }
  .drop-overlay {
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0, 120, 212, 0.1);
    border: 2px dashed var(--vscode-focusBorder, #0078d4);
    border-radius: inherit;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--vscode-focusBorder, #0078d4);
    font-size: 14px;
    font-weight: 500;
    z-index: 10;
    pointer-events: none;
  }
  .toolStatusDot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--vscode-charts-green, #22c55e);
    flex-shrink: 0;
    margin-left: auto;
  }
  /* Fix flex height chain — prevent content from overflowing viewport */
  .cmx-root, .cmx-body, .cmx-content, .sessionBody,
  .chatContainer, .messagesContainer { min-height: 0 !important; }
  .root_-a7MRw pre {
    background: var(--app-tool-background, var(--vscode-editor-background, #1e1e1e));
    border: 1px solid var(--app-primary-border-color, #3c3c3c);
    border-radius: var(--corner-radius-medium, 6px);
    padding: 12px 16px;
    overflow-x: auto;
    margin: 8px 0;
  }
  .root_-a7MRw pre code {
    background: none;
    border: none;
    padding: 0;
    font-size: var(--app-monospace-font-size, 12px);
    font-family: var(--app-monospace-font-family, monospace);
    color: var(--app-primary-foreground);
  }
  .root_-a7MRw code {
    background: var(--app-tool-background, rgba(255,255,255,0.06));
    border-radius: 3px;
    padding: 2px 5px;
    font-size: 0.9em;
  }
  .root_-a7MRw a { color: var(--vscode-textLink-foreground, #4daafc); }
  .root_-a7MRw ul, .root_-a7MRw ol { padding-left: 20px; margin: 4px 0; }
  .root_-a7MRw li { margin: 2px 0; }
  .root_-a7MRw blockquote {
    border-left: 3px solid var(--app-primary-border-color, #3c3c3c);
    margin: 8px 0;
    padding: 4px 12px;
    opacity: 0.8;
  }
`;
document.head.appendChild(style);

// Initialize protocol + create first session
init();

function isMobile() {
  return window.innerWidth < 768;
}

function ensureMeta(name, fallback = '') {
  let meta = document.querySelector(`meta[name="${name}"]`);
  if (!meta) {
    meta = document.createElement('meta');
    meta.setAttribute('name', name);
    if (fallback) meta.setAttribute('content', fallback);
    document.head.appendChild(meta);
  }
  return meta;
}

function App() {
  const [sidebarCollapsed, _setSidebarCollapsed] = useState(() => {
    const saved = localStorage.getItem('cmx-sidebar-collapsed');
    if (saved !== null) return saved === 'true';
    return isMobile();
  });
  const setSidebarCollapsed = (v) => {
    const val = typeof v === 'function' ? v(sidebarCollapsed) : v;
    _setSidebarCollapsed(val);
    localStorage.setItem('cmx-sidebar-collapsed', String(val));
  };
  const [showSettings, setShowSettings] = useState(false);
  const [showMonitor, setShowMonitor] = useState(false);

  useEffect(() => {
    const themeMeta = ensureMeta('theme-color', '#171717');
    const syncMobileChrome = () => {
      const source =
        document.querySelector('.cmx-header') || document.querySelector('.cmx-root') || document.body;
      const color = getComputedStyle(source).backgroundColor || '#171717';
      document.documentElement.style.backgroundColor = color;
      document.body.style.backgroundColor = color;
      themeMeta.setAttribute('content', color);
    };

    syncMobileChrome();
    const observer = new MutationObserver(syncMobileChrome);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style'] });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;

    const updateKeyboardOffset = () => {
      const offset = isMobile() ? Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop)) : 0;
      document.documentElement.style.setProperty('--cmx-mobile-bottom-offset', `${offset}px`);
    };

    updateKeyboardOffset();
    vv.addEventListener('resize', updateKeyboardOffset);
    vv.addEventListener('scroll', updateKeyboardOffset);
    window.addEventListener('resize', updateKeyboardOffset);
    return () => {
      vv.removeEventListener('resize', updateKeyboardOffset);
      vv.removeEventListener('scroll', updateKeyboardOffset);
      window.removeEventListener('resize', updateKeyboardOffset);
      document.documentElement.style.setProperty('--cmx-mobile-bottom-offset', '0px');
    };
  }, []);

  return (
    <div className="app-layout">
      {/* StatusBar integrated into SessionView header */}
      {!sidebarCollapsed && isMobile() && (
        <div className="sidebar-backdrop" onClick={() => setSidebarCollapsed(true)} />
      )}
      <Sidebar
        collapsed={sidebarCollapsed}
        onToggle={() => setSidebarCollapsed(!sidebarCollapsed)}
        onShowSettings={() => setShowSettings(!showSettings)}
        showMonitor={showMonitor}
        onToggleMonitor={() => setShowMonitor((v) => !v)}
      />
      <div className="main-content">
        {showMonitor ? <Monitor onClose={() => setShowMonitor(false)} /> : <SessionView />}
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.querySelector('#root')).render(<App />);
