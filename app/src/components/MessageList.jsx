import React from 'react';
import { ContentBlockRenderer } from './ContentBlockRenderer.jsx';

/**
 * MessageList — groups messages into turns (user + assistant responses together).
 * The reference puts user message + all assistant messages in the SAME turn div,
 * so timeline lines (`:after` pseudo-elements) connect consecutive timelineMessages.
 */
export function MessageList({ messages, busy }) {
  // Group into turns: each turn starts with a user message, followed by assistant messages
  const turns = [];
  let currentTurn = null;

  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];
    if (msg.type === 'user') {
      currentTurn = { user: msg, assistants: [], startIdx: i };
      turns.push(currentTurn);
    } else if (msg.type === 'assistant') {
      if (!currentTurn) {
        currentTurn = { user: null, assistants: [], startIdx: i };
        turns.push(currentTurn);
      }
      currentTurn.assistants.push({ msg, idx: i });
    }
  }

  return (
    <div className="messagesList">
      {turns.map((turn, ti) => (
        <div key={ti} className="turn">
          {/* User message */}
          {turn.user && <UserMessage message={turn.user} />}

          {/* Assistant messages — siblings so timeline line connects them */}
          {turn.assistants.map(({ msg, idx }, ai) => {
            const isLast = idx === messages.length - 1;
            return <AssistantMessage key={ai} message={msg} isLast={isLast} busy={busy} />;
          })}

          {/* Spinner if this is the last turn and we're waiting */}
          {busy && ti === turns.length - 1 && turn.assistants.length === 0 && (
            <div className="message timelineMessage dotProgress processingMessage">
              <ThinkingIndicator />
            </div>
          )}
        </div>
      ))}

      {/* Spinner when busy after the last user message with no assistant yet */}
      {
        busy &&
          messages.length > 0 &&
          messages[messages.length - 1]?.type === 'user' &&
          turns.length > 0 &&
          turns[turns.length - 1].assistants.length === 0 &&
          null /* handled above */
      }
    </div>
  );
}

function UserMessage({ message }) {
  const [showPopup, setShowPopup] = React.useState(false);
  const textBlocks = message.content
    ?.filter((b) => b.content?.type === 'text')
    .map((b) => b.content.text)
    .join('\n');
  const imageBlocks = message.content?.filter((b) => b.content?.type === 'image') || [];

  return (
    <div className="message userMessageContainer stickyHeader">
      <div className="userMessageContainer">
        <div className="actionContainer ">
          <button
            className={`actionButton ${showPopup ? 'actionVisible actionSubtleVisible' : ''}`}
            title="Message actions"
            aria-expanded={showPopup}
            onClick={(e) => {
              e.stopPropagation();
              setShowPopup(!showPopup);
            }}
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              strokeWidth="3"
              stroke="currentColor"
              style={{ transform: 'scale(0.9)' }}
            >
              <path strokeLinecap="round" strokeLinejoin="round" d="M9 15 3 9m0 0 6-6M3 9h12a6 6 0 0 1 0 12h-3" />
            </svg>
          </button>
          {showPopup && (
            <div className="actionPopup actionPopupVisible" onClick={(e) => e.stopPropagation()}>
              <button
                className="actionPopupOption"
                onClick={() => {
                  setShowPopup(false);
                  import('../lib/protocol.js')
                    .then(({ request }) =>
                      request('fork_conversation', {
                        forkedFromSession: message._sessionId,
                        resumeSessionAt: message._uuid,
                      }),
                    )
                    .then((res) => {
                      if (res?.sessionId)
                        import('../state/sessions.js').then(({ resumeSession }) => resumeSession(res.sessionId));
                    });
                }}
              >
                <span className="actionOptionText">Fork conversation from here</span>
              </button>
              <button
                className="actionPopupOption"
                onClick={() => {
                  setShowPopup(false);
                  import('../lib/protocol.js').then(({ request }) =>
                    request('rewind_code', { userMessageId: message._uuid }),
                  );
                }}
              >
                <span className="actionOptionText">Rewind code to here</span>
              </button>
              <button
                className="actionPopupOption"
                onClick={() => {
                  setShowPopup(false);
                  import('../lib/protocol.js')
                    .then(({ request }) =>
                      Promise.all([
                        request('rewind_code', { userMessageId: message._uuid }),
                        request('fork_conversation', {
                          forkedFromSession: message._sessionId,
                          resumeSessionAt: message._uuid,
                        }),
                      ]),
                    )
                    .then(([, forkRes]) => {
                      if (forkRes?.sessionId)
                        import('../state/sessions.js').then(({ resumeSession }) => resumeSession(forkRes.sessionId));
                    });
                }}
              >
                <span className="actionOptionText">Fork conversation and rewind code</span>
              </button>
            </div>
          )}
        </div>
        <div className="userMessage">
          <div className="expandableContainer">
            <div className="contentWrapper ">
              <div className="expandableContent ">
                <span>{textBlocks || '(empty)'}</span>
                {imageBlocks.map((b, i) => (
                  <img
                    key={i}
                    src={`data:${b.content.source?.media_type || 'image/png'};base64,${b.content.source?.data}`}
                    alt="attachment"
                    style={{
                      maxWidth: '200px',
                      maxHeight: '150px',
                      borderRadius: '8px',
                      marginTop: '4px',
                      display: 'block',
                    }}
                  />
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function AssistantMessage({ message, isLast, busy }) {
  if (!message.content || message.content.length === 0) {
    if (isLast && busy) {
      return (
        <div className="message timelineMessage dotProgress processingMessage">
          <ThinkingIndicator />
        </div>
      );
    }
    return null;
  }

  const dotClass = isLast && busy ? 'dotProgress' : 'dotSuccess';

  // Each content block that's a tool_use gets its own timelineMessage
  // Text blocks can share a timelineMessage
  const blocks = message.content;
  const groups = [];
  let textGroup = [];

  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i];
    if (block.content?.type === 'tool_use') {
      if (textGroup.length > 0) {
        groups.push({ type: 'text', blocks: textGroup });
        textGroup = [];
      }
      groups.push({ type: 'tool', block, idx: i });
    } else {
      textGroup.push({ block, idx: i });
    }
  }
  if (textGroup.length > 0) {
    groups.push({ type: 'text', blocks: textGroup });
  }

  return (
    <div data-msg-id={message._uuid} style={{ display: 'contents' }}>
      {groups.map((group, gi) => {
        const isLastGroup = gi === groups.length - 1;
        const groupDot = isLastGroup && isLast && busy ? 'dotProgress' : dotClass;

        if (group.type === 'tool') {
          return (
            <div
              key={gi}
              data-testid="assistant-message"
              className={`message timelineMessage ${groupDot}`}
            >
              <ContentBlockRenderer block={group.block} isLast={isLastGroup && isLast} busy={busy} />
            </div>
          );
        }

        return (
          <div key={gi} data-testid="assistant-message" className={`message timelineMessage ${groupDot}`}>
            {group.blocks.map(({ block, idx }) => (
              <ContentBlockRenderer
                key={idx}
                block={block}
                isLast={isLastGroup && isLast && idx === blocks.length - 1}
                busy={busy}
              />
            ))}
          </div>
        );
      })}
    </div>
  );
}

function ThinkingIndicator() {
  const [dotCount, setDotCount] = React.useState(1);

  React.useEffect(() => {
    const interval = setInterval(() => {
      setDotCount((d) => (d % 3) + 1);
    }, 500);
    return () => clearInterval(interval);
  }, []);

  return (
    <div className="spinnerRow">
      <div>
        <div className="statusContainer" data-permission-mode="bypassPermissions">
          <span className="statusText">Processing{'.'.repeat(dotCount)}</span>
        </div>
      </div>
    </div>
  );
}
