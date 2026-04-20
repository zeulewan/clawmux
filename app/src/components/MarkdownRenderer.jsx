import React from 'react';
import { marked } from 'marked';
import markedKatex from 'marked-katex-extension';
import 'katex/dist/katex.min.css';

// Register KaTeX extension for LaTeX rendering
marked.use(markedKatex({ throwOnError: false }));

/**
 * MarkdownRenderer — renders markdown + LaTeX.
 * Supports $inline$ and $$block$$ LaTeX via KaTeX.
 */
export function MarkdownRenderer({ text, isPartial }) {
  if (!text) return null;

  let processedText = text;

  // Fix LaTeX inside parentheses: ($x$) → ( $x$ ) so KaTeX parser recognizes it
  processedText = processedText.replace(/\(\$/g, '( $').replace(/\$\)/g, '$ )');

  if (isPartial) {
    // Close unclosed code blocks for partial renders
    const fenceCount = (processedText.match(/```/g) || []).length;
    if (fenceCount % 2 !== 0) {
      processedText += '\n```';
    }
  }

  const html = marked.parse(processedText, {
    breaks: true,
    gfm: true,
  });

  return <div className="markdownContent" dangerouslySetInnerHTML={{ __html: html }} />;
}
