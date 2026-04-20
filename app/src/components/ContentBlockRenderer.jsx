import React from 'react';
import { ToolUseContent } from './ToolUseContent.jsx';
import { ThinkingBlock } from './ThinkingBlock.jsx';
import { MarkdownRenderer } from './MarkdownRenderer.jsx';

/**
 * ContentBlockRenderer — dispatches to the right renderer based on content type.
 * Renders text, thinking, tool_use, tool_result, and image content blocks.
 */
export function ContentBlockRenderer({ block, isLast, busy }) {
  const content = block?.content;
  if (!content) return null;

  switch (content.type) {
    case 'text':
      return (
        <span className="root_-a7MRw">
          <MarkdownRenderer text={content.text || ''} isPartial={isLast && busy} />
        </span>
      );

    case 'thinking':
      return (
        <ThinkingBlock thinking={content.thinking || ''} isCurrentlyThinking={isLast && busy && !content.thinking} />
      );

    case 'tool_use':
      return (
        <div className="toolUse">
          <ToolUseContent content={content} toolResult={block.toolResult} />
        </div>
      );

    case 'tool_result':
      if (typeof content.content === 'string') {
        return <pre className="toolResult">{content.content}</pre>;
      }
      return null;

    case 'image':
      return (
        <div className="imageBlock">
          <img
            src={`data:${content.source?.media_type || 'image/png'};base64,${content.source?.data}`}
            alt="Attached image"
            style={{ maxWidth: '100%', borderRadius: 8 }}
          />
        </div>
      );

    default:
      return <div style={{ opacity: 0.5, fontSize: '0.85em' }}>[{content.type}]</div>;
  }
}
