import React from 'react';

export const MODES = [
  {
    id: 'acceptEdits',
    label: 'Ask before edits',
    description: 'Asks for your approval before each file change',
    icon: (
      // Shield with checkmark
      <path
        d="M10 2L3 5v4.09c0 5.05 3.41 9.76 7 10.91 3.59-1.15 7-5.86 7-10.91V5l-7-3zm-1.5 11.59l-3.09-3.09L6.82 9.09 8.5 10.77l4.68-4.68 1.41 1.41-6.09 6.09z"
        fill="currentColor"
      />
    ),
  },
  {
    id: 'auto',
    label: 'Edit automatically',
    description: 'Applies changes to files without confirmation',
    icon: (
      // Pencil
      <path
        d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a1.003 1.003 0 000-1.42l-2.34-2.34a1.003 1.003 0 00-1.42 0l-1.83 1.83 3.75 3.75 1.84-1.82z"
        fill="currentColor"
      />
    ),
  },
  {
    id: 'plan',
    label: 'Plan mode',
    description: 'Analyzes the codebase and proposes a plan before making changes',
    icon: (
      // Clipboard/list
      <path
        d="M9 2a1 1 0 00-1 1H6a2 2 0 00-2 2v14a2 2 0 002 2h12a2 2 0 002-2V5a2 2 0 00-2-2h-2a1 1 0 00-1-1H9zm0 2h6v1H9V4zm-1 4h8v2H8V8zm0 4h8v2H8v-2zm0 4h5v2H8v-2z"
        fill="currentColor"
      />
    ),
  },
  {
    id: 'bypassPermissions',
    label: 'Bypass permissions',
    description: 'Runs all commands and edits without asking — use with caution',
    icon: (
      // Lightning bolt
      <path
        d="M11 2L4 13h5v7l7-11h-5V2z"
        fill="currentColor"
      />
    ),
  },
];

const CHECK_ICON = (
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
    <path
      fillRule="evenodd"
      d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z"
      clipRule="evenodd"
    />
  </svg>
);

function getEffortLevels() {
  const custom = window._clawmuxEffortLevels;
  if (custom === null || custom === undefined) return ['low', 'medium', 'high', 'max']; // Not yet loaded
  return custom.map((e) => e.value); // Empty array = no effort control
}

function getEffortLabels() {
  const custom = window._clawmuxEffortLevels;
  if (custom && custom.length > 0) {
    const labels = {};
    for (const e of custom) labels[e.value] = e.label;
    return labels;
  }
  return { low: 'Low', medium: 'Medium', high: 'High', max: 'Max' };
}

export function ModesMenu({ currentMode, onSelect, onClose, effortLevel = 'medium', onEffortChange }) {
  const EFFORT_LEVELS = getEffortLevels();
  const EFFORT_LABELS = getEffortLabels();
  const permModes = window._clawmuxPermissionModes;
  const modes = permModes && permModes.length > 0 ? MODES.filter((m) => permModes.some((p) => p.id === m.id)) : MODES;
  return (
    <div className="menuPopup menuPopupRight menuPopupV2" onClick={(e) => e.stopPropagation()}>
      <div className="menuHeader">
        <span className="menuHeaderTitle">Modes</span>
        <span className="menuHeaderHint">
          <kbd>⇧</kbd> + <kbd>tab</kbd> to switch
        </span>
      </div>
      {modes.map((mode) => (
        <button
          key={mode.id}
          type="button"
          className={`menuItemV2 ${mode.id === currentMode ? 'menuItemSelected' : ''}`}
          onClick={() => {
            onSelect(mode.id);
            onClose();
          }}
        >
          <span className="menuItemIcon">
            <svg
              width="20"
              height="20"
              viewBox="0 0 20 20"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
              style={{ display: 'block' }}
            >
              {mode.icon}
            </svg>
          </span>
          <span className="menuItemText">
            <span className="menuItemLabel">{mode.label}</span>
            <span className="menuItemDescription">{mode.description}</span>
          </span>
          <span className="menuItemCheckRight">{mode.id === currentMode && CHECK_ICON}</span>
        </button>
      ))}
      {EFFORT_LEVELS.length > 0 && <div className="menuDivider" />}
      {EFFORT_LEVELS.length > 0 && (
        <button
          type="button"
          className="effortRow"
          title="Click to cycle effort level"
          onClick={() => {
            const idx = EFFORT_LEVELS.indexOf(effortLevel);
            const next = EFFORT_LEVELS[(idx + 1) % EFFORT_LEVELS.length];
            if (onEffortChange) onEffortChange(next);
          }}
        >
          <span className="effortLabel">
            <svg
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
              style={{ display: 'block' }}
            >
              <path
                d="M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"
                fill="currentColor"
              />
            </svg>
            Effort
            <span className="effortLevelInline">({EFFORT_LABELS[effortLevel] || 'Auto'})</span>
          </span>
          <EffortToggle level={effortLevel} onChange={onEffortChange} levels={EFFORT_LEVELS} />
        </button>
      )}
    </div>
  );
}

function EffortToggle({ level, onChange, levels }) {
  const effortLevels = levels || ['low', 'medium', 'high', 'max'];
  const positions = {};
  effortLevels.forEach((l, i) => {
    positions[l] = effortLevels.length > 1 ? i / (effortLevels.length - 1) : 0;
  });
  const pos = positions[level] ?? 0.5;

  return (
    <button
      type="button"
      className="cmx-toggle"
      title="Click a position to set effort level"
      onClick={(e) => {
        e.stopPropagation();
        const rect = e.currentTarget.getBoundingClientRect();
        const x = (e.clientX - rect.left) / rect.width;
        const idx = Math.round(x * (effortLevels.length - 1));
        const newLevel = effortLevels[Math.max(0, Math.min(idx, effortLevels.length - 1))];
        if (onChange) onChange(newLevel);
      }}
    >
      <div
        className="toggleFill"
        style={{
          width: `calc(var(--thumb-inset) + ${pos} * (100% - var(--thumb-size) - 2 * var(--thumb-inset)) + var(--thumb-size) + var(--thumb-inset))`,
        }}
      />
      {effortLevels
        .map((_, i) => i / Math.max(1, effortLevels.length - 1))
        .map((p, i) => (
          <div
            key={i}
            className="toggleNotch"
            style={{
              left: `calc(var(--thumb-inset) + ${p} * (100% - var(--thumb-size) - 2 * var(--thumb-inset)) + var(--thumb-size) / 2)`,
            }}
          />
        ))}
      <div
        className="toggleThumb"
        style={{ left: `calc(var(--thumb-inset) + ${pos} * (100% - var(--thumb-size) - 2 * var(--thumb-inset)))` }}
      />
    </button>
  );
}
