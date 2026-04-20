import React, { useState } from 'react';
import { getToolRenderer } from '../tools/registry.js';

/**
 * ToolUseContent — collapsible tool call block.
 * Shows command name + header, with chevron to expand IN/OUT details.
 */
export function ToolUseContent({ content, toolResult }) {
  const [expanded, setExpanded] = useState(false);
  const renderer = getToolRenderer(content.name);
  const headerText = renderer.headerText(content);
  const input = renderer.inputText(content);
  const output = toolResult?.value;

  return (
    <div className="toolRoot">
      <button className="toolSummary toolSummaryClickable" onClick={() => setExpanded(!expanded)} type="button">
        <svg
          className={`toolChevron ${expanded ? 'toolChevronOpen' : ''}`}
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.5"
        >
          <path d="M9 18l6-6-6-6" />
        </svg>
        <span>
          <span className="toolNameText">{content.name} </span>
          <span className="toolNameTextSecondaryPlaintext">{headerText}</span>
        </span>
        {output && !expanded && <span className="toolStatusDot" title="Has output" />}
      </button>
      {expanded && (
        <div className="toolBody">
          <div className="toolBodyGrid">
            {input && (
              <div className="toolBodyRow inputRow">
                <div className="toolBodyRowLabel">IN</div>
                <div
                  className="toolBodyRowContent toolBodyRowContent_disableClipping"
                  style={{ overflow: 'auto', maxHeight: '300px' }}
                >
                  <pre style={{ margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>{input}</pre>
                </div>
                <CopyButton text={input} />
              </div>
            )}
            {output && (
              <div className="toolBodyRow">
                <div className="toolBodyRowLabel">OUT</div>
                <div
                  className="toolBodyRowContent toolBodyRowContent_disableClipping"
                  style={{ overflow: 'auto', maxHeight: '400px' }}
                >
                  <div className="toolResult">
                    <pre style={{ margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
                      {typeof output === 'string' ? output : JSON.stringify(output, null, 2)}
                    </pre>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function CopyButton({ text }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = () => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  return (
    <button
      className="copyButton inputCopyButton"
      title="Copy code"
      aria-label="Copy code to clipboard"
      onClick={handleCopy}
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
        aria-hidden="true"
        className="copyIcon"
      >
        <path
          fillRule="evenodd"
          d="M15.988 3.012A2.25 2.25 0 0 1 18 5.25v6.5A2.25 2.25 0 0 1 15.75 14H13.5v-3.379a3 3 0 0 0-.879-2.121l-3.12-3.121a3 3 0 0 0-1.402-.791 2.252 2.252 0 0 1 1.913-1.576A2.25 2.25 0 0 1 12.25 1h1.5a2.25 2.25 0 0 1 2.238 2.012ZM11.5 3.25a.75.75 0 0 1 .75-.75h1.5a.75.75 0 0 1 .75.75v.25h-3v-.25Z"
          clipRule="evenodd"
        />
        <path d="M3.5 6A1.5 1.5 0 0 0 2 7.5v9A1.5 1.5 0 0 0 3.5 18h7a1.5 1.5 0 0 0 1.5-1.5v-5.879a1.5 1.5 0 0 0-.44-1.06L8.44 6.439A1.5 1.5 0 0 0 7.378 6H3.5Z" />
      </svg>
    </button>
  );
}
