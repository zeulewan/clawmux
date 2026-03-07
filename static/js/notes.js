// ClawMux — Notes Panel Module
// Persists "Now" and "Later" notes via /api/notes.

let _notesData = { now: '', later: '' };
let _notesLoaded = false;
let _notesSaveTimer = null;
let _activeNotesTab = 'now';

function toggleNotesPanel() {
  const panel = document.getElementById('notes-panel');
  panel.classList.toggle('open');
  const isOpen = panel.classList.contains('open');
  fetch('/api/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ notes_panel_open: isOpen }),
  }).catch(() => {});
  if (isOpen && !_notesLoaded) {
    loadNotes();
  }
}

// Restore panel state from server settings on load
(async function _restoreNotesPanel() {
  try {
    const resp = await fetch('/api/settings');
    if (!resp.ok) return;
    const settings = await resp.json();
    if (settings.notes_active_tab) {
      switchNotesTab(settings.notes_active_tab, false);
    }
    if (settings.notes_panel_open) {
      document.getElementById('notes-panel').classList.add('open');
      loadNotes();
    }
  } catch(e) {}
})();

function switchNotesTab(tab, persist = true) {
  _activeNotesTab = tab;
  const tabs = document.querySelectorAll('#notes-panel-header .notes-tab');
  tabs.forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
  document.getElementById('notes-now').style.display = tab === 'now' ? '' : 'none';
  document.getElementById('notes-later-wrap').style.display = tab === 'later' ? '' : 'none';
  if (persist) {
    fetch('/api/settings', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ notes_active_tab: tab }),
    }).catch(() => {});
  }
}

async function loadNotes() {
  try {
    const resp = await fetch('/api/notes');
    if (resp.ok) {
      _notesData = await resp.json();
      document.getElementById('notes-now').value = _notesData.now || '';
      document.getElementById('notes-later').value = _notesData.later || '';
    }
    _notesLoaded = true;
  } catch (e) {
    console.error('Failed to load notes:', e);
  }
}

function _scheduleSaveNotes() {
  if (_notesSaveTimer) clearTimeout(_notesSaveTimer);
  _notesSaveTimer = setTimeout(saveNotes, 800);
  const status = document.getElementById('notes-save-status');
  if (status) status.textContent = '';
}

async function saveNotes() {
  _notesData.now = document.getElementById('notes-now').value;
  _notesData.later = document.getElementById('notes-later').value;
  try {
    await fetch('/api/notes', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(_notesData),
    });
    const status = document.getElementById('notes-save-status');
    if (status) status.textContent = 'Saved';
    setTimeout(() => { if (status) status.textContent = ''; }, 2000);
  } catch (e) {
    console.error('Failed to save notes:', e);
    const status = document.getElementById('notes-save-status');
    if (status) status.textContent = 'Save failed';
  }
}

let _laterPreviewMode = false;

function toggleLaterPreview() {
  _laterPreviewMode = !_laterPreviewMode;
  const textarea = document.getElementById('notes-later');
  const preview = document.getElementById('notes-later-preview');
  const btn = document.getElementById('notes-later-preview-btn');
  if (_laterPreviewMode) {
    // Save any pending changes before switching
    if (_notesSaveTimer) { clearTimeout(_notesSaveTimer); _notesSaveTimer = null; saveNotes(); }
    const html = typeof marked !== 'undefined' ? marked.parse(textarea.value || '') : textarea.value;
    preview.innerHTML = typeof DOMPurify !== 'undefined' ? DOMPurify.sanitize(html) : html;
    textarea.style.display = 'none';
    preview.style.display = '';
    btn.textContent = 'Edit';
    btn.classList.add('active');
  } else {
    textarea.style.display = '';
    preview.style.display = 'none';
    btn.textContent = 'Preview';
    btn.classList.remove('active');
  }
}

// Attach event listeners once DOM is ready
document.getElementById('notes-now').addEventListener('input', _scheduleSaveNotes);
document.getElementById('notes-later').addEventListener('input', _scheduleSaveNotes);
document.getElementById('notes-now').addEventListener('blur', () => {
  if (_notesSaveTimer) { clearTimeout(_notesSaveTimer); _notesSaveTimer = null; saveNotes(); }
});
document.getElementById('notes-later').addEventListener('blur', () => {
  if (_notesSaveTimer) { clearTimeout(_notesSaveTimer); _notesSaveTimer = null; saveNotes(); }
});
