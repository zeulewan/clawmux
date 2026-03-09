// ClawMux — Resizable Panels
// Drag handles for sidebar and notes panel with persistent widths.

(function () {
  const SIDEBAR_MIN = 140;
  const SIDEBAR_MAX = 500;
  const NOTES_MIN = 200;
  const NOTES_MAX = 600;
  const SIDEBAR_DEFAULT = 220;
  const NOTES_DEFAULT = 320;

  let _saveTimer = null;

  function initResizeHandles() {
    const sidebar = document.getElementById('sidebar');
    const notesPanel = document.getElementById('notes-panel');
    const appBody = document.getElementById('app-body');
    if (!sidebar || !appBody) return;

    // Create sidebar resize handle
    const sidebarHandle = document.createElement('div');
    sidebarHandle.className = 'resize-handle resize-handle-sidebar';
    sidebar.after(sidebarHandle);

    // Create notes resize handle (hidden until panel is open)
    if (notesPanel) {
      const notesHandle = document.createElement('div');
      notesHandle.className = 'resize-handle resize-handle-notes';
      notesHandle.style.display = notesPanel.classList.contains('open') ? '' : 'none';
      notesPanel.before(notesHandle);
      _attachDrag(notesHandle, notesPanel, 'notes', true);

      // Show/hide notes handle when panel toggles
      const notesObserver = new MutationObserver(function () {
        notesHandle.style.display = notesPanel.classList.contains('open') ? '' : 'none';
      });
      notesObserver.observe(notesPanel, { attributes: true, attributeFilter: ['class'] });
    }

    if (!isMobile) _attachDrag(sidebarHandle, sidebar, 'sidebar', false);
    _restoreWidths();
  }

  function _attachDrag(handle, panel, key, fromRight) {
    let startX, startW;

    handle.addEventListener('mousedown', function (e) {
      e.preventDefault();
      startX = e.clientX;
      startW = panel.getBoundingClientRect().width;
      document.body.style.cursor = 'col-resize';
      document.body.style.userSelect = 'none';

      // Disable transitions during drag
      panel.style.transition = 'none';

      function onMove(e) {
        const delta = fromRight ? startX - e.clientX : e.clientX - startX;
        const min = key === 'sidebar' ? SIDEBAR_MIN : NOTES_MIN;
        const max = key === 'sidebar' ? SIDEBAR_MAX : NOTES_MAX;
        const newW = Math.max(min, Math.min(max, startW + delta));
        if (key === 'notes') {
          panel.style.setProperty('--notes-width', newW + 'px');
        } else {
          panel.style.width = newW + 'px';
          panel.style.minWidth = newW + 'px';
          document.documentElement.style.setProperty('--sidebar-w', newW + 'px');
        }
      }

      function onUp() {
        document.removeEventListener('mousemove', onMove);
        document.removeEventListener('mouseup', onUp);
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
        panel.style.transition = '';
        const savedW = key === 'notes'
          ? parseInt(panel.style.getPropertyValue('--notes-width'))
          : parseInt(panel.style.width);
        _scheduleSave(key, savedW);
      }

      document.addEventListener('mousemove', onMove);
      document.addEventListener('mouseup', onUp);
    });
  }

  function _scheduleSave(key, width) {
    if (_saveTimer) clearTimeout(_saveTimer);
    _saveTimer = setTimeout(function () {
      const settingsKey = key + '_width';
      fetch('/api/settings', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ [settingsKey]: width }),
      }).catch(function () {});
    }, 300);
  }

  async function _restoreWidths() {
    try {
      const resp = await fetch('/api/settings');
      if (!resp.ok) return;
      const settings = await resp.json();

      const sidebar = document.getElementById('sidebar');
      if (settings.sidebar_width && sidebar && !isMobile && window.innerWidth > 900) {
        const w = Math.max(SIDEBAR_MIN, Math.min(SIDEBAR_MAX, settings.sidebar_width));
        sidebar.style.width = w + 'px';
        sidebar.style.minWidth = w + 'px';
        document.documentElement.style.setProperty('--sidebar-w', w + 'px');
      }

      const notes = document.getElementById('notes-panel');
      if (settings.notes_width && notes) {
        const w = Math.max(NOTES_MIN, Math.min(NOTES_MAX, settings.notes_width));
        notes.style.setProperty('--notes-width', w + 'px');
        notes.dataset.savedWidth = w;
      }
    } catch (e) {}
  }

  // Patch toggleNotesPanel to apply saved width
  const _origToggle = window.toggleNotesPanel;
  window.toggleNotesPanel = function () {
    _origToggle();
    const panel = document.getElementById('notes-panel');
    if (panel && panel.classList.contains('open') && panel.dataset.savedWidth) {
      const w = parseInt(panel.dataset.savedWidth);
      panel.style.setProperty('--notes-width', w + 'px');
    }
  };

  // Also apply saved width when panel opens via settings restore
  const observer = new MutationObserver(function (mutations) {
    for (const m of mutations) {
      if (m.attributeName === 'class') {
        const panel = m.target;
        if (panel.classList.contains('open') && panel.dataset.savedWidth) {
          const w = parseInt(panel.dataset.savedWidth);
          panel.style.setProperty('--notes-width', w + 'px');
        }
      }
    }
  });
  const notesEl = document.getElementById('notes-panel');
  if (notesEl) {
    observer.observe(notesEl, { attributes: true, attributeFilter: ['class'] });
  }

  // Clear inline sidebar width when window narrows below tablet breakpoint
  window.addEventListener('resize', function () {
    if (window.innerWidth <= 900) {
      const sidebar = document.getElementById('sidebar');
      if (sidebar) {
        sidebar.style.width = '';
        sidebar.style.minWidth = '';
      }
    }
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initResizeHandles);
  } else {
    initResizeHandles();
  }
})();
