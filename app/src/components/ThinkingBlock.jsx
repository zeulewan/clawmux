import React, { useState } from 'react';
import { MarkdownRenderer } from './MarkdownRenderer.jsx';

/**
 * ThinkingBlock — collapsible thinking indicator.
 * Shows "Thinking..." while active, "Thought for Xs" when done.
 */
export function ThinkingBlock({ thinking, isCurrentlyThinking, durationMs }) {
  const [isOpen, setIsOpen] = useState(false);
  const hasContent = thinking && thinking.length > 0;

  const durationText = durationMs
    ? `Thought for ${(durationMs / 1000).toFixed(0)}s`
    : isCurrentlyThinking
      ? 'Thinking...'
      : hasContent
        ? 'Thinking'
        : 'Thinking...';

  return (
    <details className="cmx-thinking thinkingV2" open={isOpen} onToggle={(e) => setIsOpen(e.target.open)}>
      <summary className="thinkingSummary">
        <span className={`thinkingToggle ${isOpen ? 'thinkingToggleOpen' : ''}`}>
          <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
            <path d="M6 4l4 4-4 4" />
          </svg>
        </span>
        <span>{durationText}</span>
      </summary>
      {hasContent && (
        <div className="thinkingContent">
          <MarkdownRenderer text={thinking} />
        </div>
      )}
    </details>
  );
}
