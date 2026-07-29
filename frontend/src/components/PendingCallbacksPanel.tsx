import { useState } from 'react';
import { api } from '../lib/api';
import type { PendingCallbacksResponse, PermissionRequest, UserQuestion, SecretRequest } from '../types';

interface PendingCallbacksPanelProps {
  sessionId: string;
  callbacks: PendingCallbacksResponse;
  onAnswered: () => void;
}

export function PendingCallbacksPanel({ sessionId, callbacks, onAnswered }: PendingCallbacksPanelProps) {
  const { permissionRequests, userQuestions, secretRequests } = callbacks;
  const totalCount = permissionRequests.length + userQuestions.length + secretRequests.length;

  // Track editable/submitting states per callback ID
  const [editedJson, setEditedJson] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState<Record<string, boolean>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});

  if (totalCount === 0) return null;

  const handleAnswerPermission = async (
    req: PermissionRequest,
    decision: 'allow' | 'deny' | 'allow_always'
  ) => {
    const reqId = req.id;
    const jsonVal = editedJson[reqId] ?? req.inputJson;
    const noteVal = notes[reqId] ?? '';

    // Validate JSON first if approving
    if (decision !== 'deny') {
      try {
        JSON.parse(jsonVal);
      } catch (err) {
        setErrors(prev => ({ ...prev, [reqId]: 'Invalid JSON format' }));
        return;
      }
    }

    setSubmitting(prev => ({ ...prev, [reqId]: true }));
    setErrors(prev => ({ ...prev, [reqId]: '' }));

    try {
      await api.answerPermissionRequest(sessionId, reqId, {
        decision,
        note: noteVal,
        updatedInputJson: jsonVal,
      });
      onAnswered();
    } catch (err) {
      setErrors(prev => ({
        ...prev,
        [reqId]: err instanceof Error ? err.message : 'Failed to submit response',
      }));
    } finally {
      setSubmitting(prev => ({ ...prev, [reqId]: false }));
    }
  };

  const handleAnswerQuestion = async (req: UserQuestion) => {
    const reqId = req.id;
    const answerVal = answers[reqId]?.trim() ?? '';

    if (!answerVal) {
      setErrors(prev => ({ ...prev, [reqId]: 'Please provide an answer' }));
      return;
    }

    setSubmitting(prev => ({ ...prev, [reqId]: true }));
    setErrors(prev => ({ ...prev, [reqId]: '' }));

    try {
      await api.answerUserQuestion(sessionId, reqId, answerVal);
      onAnswered();
    } catch (err) {
      setErrors(prev => ({
        ...prev,
        [reqId]: err instanceof Error ? err.message : 'Failed to submit answer',
      }));
    } finally {
      setSubmitting(prev => ({ ...prev, [reqId]: false }));
    }
  };

  const handleAnswerSecret = async (req: SecretRequest, decision: 'allow' | 'deny') => {
    const reqId = req.id;
    setSubmitting(prev => ({ ...prev, [reqId]: true }));
    setErrors(prev => ({ ...prev, [reqId]: '' }));

    try {
      await api.answerSecretRequest(sessionId, reqId, decision);
      onAnswered();
    } catch (err) {
      setErrors(prev => ({
        ...prev,
        [reqId]: err instanceof Error ? err.message : 'Failed to submit decision',
      }));
    } finally {
      setSubmitting(prev => ({ ...prev, [reqId]: false }));
    }
  };

  return (
    <div style={containerStyle}>
      <div style={titleRowStyle}>
        <div style={titleLeftStyle}>
          <span style={pulseBadgeStyle} />
          <span style={titleTextStyle}>Action Required</span>
          <span style={countBadgeStyle}>{totalCount}</span>
        </div>
        <div style={titleSubTextStyle}>
          The agent is waiting for your authorization or input to continue.
        </div>
      </div>

      <div style={listStyle}>
        {/* Render Permission Requests */}
        {permissionRequests.map(req => {
          const currentJson = editedJson[req.id] ?? req.inputJson;
          let isJsonInvalid = false;
          try {
            JSON.parse(currentJson);
          } catch {
            isJsonInvalid = true;
          }

          return (
            <div key={req.id} style={{ ...cardStyle, borderLeft: '4px solid #d29922' }}>
              <div style={cardHeaderStyle}>
                <span style={{ ...badgeStyle, background: 'rgba(210, 153, 34, 0.15)', color: '#d29922', border: '1px solid rgba(210, 153, 34, 0.3)' }}>
                  Permission Request
                </span>
                <span style={cardTimeStyle}>
                  {new Date(parseInt(req.createdAt, 10) || Date.now()).toLocaleTimeString()}
                </span>
              </div>

              <div style={cardBodyStyle}>
                <div style={toolPromptStyle}>
                  Agent wants to call tool <code style={codeNameStyle}>{req.toolName}</code> with the following arguments:
                </div>

                <div style={editorContainerStyle}>
                  <div style={editorHeaderStyle}>
                    <span>Arguments (Editable)</span>
                    {isJsonInvalid && <span style={errorBadgeStyle}>Invalid JSON</span>}
                  </div>
                  <textarea
                    style={{
                      ...textareaStyle,
                      borderColor: isJsonInvalid ? '#f85149' : '#30363d',
                      boxShadow: isJsonInvalid ? '0 0 0 1px #f85149' : 'none',
                    }}
                    value={currentJson}
                    onChange={e => {
                      const val = e.target.value;
                      setEditedJson(prev => ({ ...prev, [req.id]: val }));
                    }}
                    rows={Math.min(15, currentJson.split('\n').length + 1)}
                    disabled={submitting[req.id]}
                  />
                </div>

                <div style={noteContainerStyle}>
                  <input
                    type="text"
                    placeholder="Add an optional explanation or feedback note for this decision…"
                    style={inputStyle}
                    value={notes[req.id] ?? ''}
                    onChange={e => setNotes(prev => ({ ...prev, [req.id]: e.target.value }))}
                    disabled={submitting[req.id]}
                  />
                </div>

                {errors[req.id] && <div style={cardErrorStyle}>⚠️ {errors[req.id]}</div>}

                <div style={actionsRowStyle}>
                  <button
                    style={{ ...buttonStyle, ...denyButtonStyle }}
                    onClick={() => handleAnswerPermission(req, 'deny')}
                    disabled={submitting[req.id]}
                  >
                    Deny
                  </button>
                  <button
                    style={{
                      ...buttonStyle,
                      ...allowButtonStyle,
                      opacity: isJsonInvalid || submitting[req.id] ? 0.5 : 1,
                      cursor: isJsonInvalid || submitting[req.id] ? 'not-allowed' : 'pointer',
                    }}
                    onClick={() => handleAnswerPermission(req, 'allow')}
                    disabled={isJsonInvalid || submitting[req.id]}
                  >
                    Allow
                  </button>
                  <button
                    style={{
                      ...buttonStyle,
                      ...allowAlwaysButtonStyle,
                      opacity: isJsonInvalid || submitting[req.id] ? 0.5 : 1,
                      cursor: isJsonInvalid || submitting[req.id] ? 'not-allowed' : 'pointer',
                    }}
                    onClick={() => handleAnswerPermission(req, 'allow_always')}
                    disabled={isJsonInvalid || submitting[req.id]}
                    title="Always auto-approve this tool with these inputs for the rest of this session"
                  >
                    Allow Always
                  </button>
                </div>
              </div>
            </div>
          );
        })}

        {/* Render User Questions */}
        {userQuestions.map(req => {
          let parsedOptions: string[] = [];
          if (req.optionsJson) {
            try {
              const parsed = JSON.parse(req.optionsJson);
              if (Array.isArray(parsed)) {
                parsedOptions = parsed.map(String);
              }
            } catch {
              // ignore malformed options
            }
          }

          const currentAnswer = answers[req.id] ?? '';

          return (
            <div key={req.id} style={{ ...cardStyle, borderLeft: '4px solid #58a6ff' }}>
              <div style={cardHeaderStyle}>
                <span style={{ ...badgeStyle, background: 'rgba(56, 139, 253, 0.15)', color: '#58a6ff', border: '1px solid rgba(56, 139, 253, 0.3)' }}>
                  Question from Agent
                </span>
                <span style={cardTimeStyle}>
                  {new Date(parseInt(req.createdAt, 10) || Date.now()).toLocaleTimeString()}
                </span>
              </div>

              <div style={cardBodyStyle}>
                <div style={questionTextStyle}>
                  {req.question}
                </div>

                {parsedOptions.length > 0 && (
                  <div style={optionsContainerStyle}>
                    <div style={optionsLabelStyle}>Select an option:</div>
                    <div style={optionsGridStyle}>
                      {parsedOptions.map(opt => (
                        <button
                          key={opt}
                          style={{
                            ...optionBtnStyle,
                            backgroundColor: currentAnswer === opt ? 'rgba(56, 139, 253, 0.15)' : '#21262d',
                            borderColor: currentAnswer === opt ? '#58a6ff' : '#30363d',
                            color: currentAnswer === opt ? '#58a6ff' : '#c9d1d9',
                          }}
                          onClick={() => setAnswers(prev => ({ ...prev, [req.id]: opt }))}
                          disabled={submitting[req.id]}
                        >
                          {opt}
                        </button>
                      ))}
                    </div>
                  </div>
                )}

                <div style={answerContainerStyle}>
                  <textarea
                    placeholder="Type your answer here…"
                    style={{ ...textareaStyle, fontFamily: 'inherit', fontSize: '13px' }}
                    value={currentAnswer}
                    onChange={e => setAnswers(prev => ({ ...prev, [req.id]: e.target.value }))}
                    rows={2}
                    disabled={submitting[req.id]}
                  />
                </div>

                {errors[req.id] && <div style={cardErrorStyle}>⚠️ {errors[req.id]}</div>}

                <div style={actionsRowStyle}>
                  <button
                    style={{
                      ...buttonStyle,
                      ...allowButtonStyle,
                      opacity: !currentAnswer.trim() || submitting[req.id] ? 0.5 : 1,
                      cursor: !currentAnswer.trim() || submitting[req.id] ? 'not-allowed' : 'pointer',
                    }}
                    onClick={() => handleAnswerQuestion(req)}
                    disabled={!currentAnswer.trim() || submitting[req.id]}
                  >
                    Submit Answer
                  </button>
                </div>
              </div>
            </div>
          );
        })}

        {/* Render Secret Requests */}
        {secretRequests.map(req => {
          return (
            <div key={req.id} style={{ ...cardStyle, borderLeft: '4px solid #bc8cff' }}>
              <div style={cardHeaderStyle}>
                <span style={{ ...badgeStyle, background: 'rgba(188, 140, 255, 0.15)', color: '#bc8cff', border: '1px solid rgba(188, 140, 255, 0.3)' }}>
                  Secret Access Request
                </span>
                <span style={cardTimeStyle}>
                  {new Date(parseInt(req.createdAt, 10) || Date.now()).toLocaleTimeString()}
                </span>
              </div>

              <div style={cardBodyStyle}>
                <div style={toolPromptStyle}>
                  Agent requests access to encrypted credential:{' '}
                  <strong style={secretNameStyle}>{req.name}</strong>
                </div>

                {req.reason && (
                  <div style={reasonContainerStyle}>
                    <div style={reasonLabelStyle}>Stated Reason:</div>
                    <div style={reasonTextStyle}>"{req.reason}"</div>
                  </div>
                )}

                {errors[req.id] && <div style={cardErrorStyle}>⚠️ {errors[req.id]}</div>}

                <div style={actionsRowStyle}>
                  <button
                    style={{ ...buttonStyle, ...denyButtonStyle }}
                    onClick={() => handleAnswerSecret(req, 'deny')}
                    disabled={submitting[req.id]}
                  >
                    Deny
                  </button>
                  <button
                    style={{ ...buttonStyle, ...allowButtonStyle }}
                    onClick={() => handleAnswerSecret(req, 'allow')}
                    disabled={submitting[req.id]}
                  >
                    Allow / Decrypt Fresh
                  </button>
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─── STYLES ──────────────────────────────────────────────────────────────────

const containerStyle: React.CSSProperties = {
  background: 'linear-gradient(135deg, rgba(210, 153, 34, 0.04) 0%, rgba(22, 27, 34, 0) 100%)',
  border: '1px solid rgba(210, 153, 34, 0.25)',
  boxShadow: '0 4px 16px rgba(0, 0, 0, 0.25), inset 0 0 12px rgba(210, 153, 34, 0.05)',
  borderRadius: '8px',
  padding: '16px',
  marginBottom: '20px',
  animation: 'fadeIn 0.3s ease',
};

const titleRowStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '4px',
  marginBottom: '14px',
};

const titleLeftStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
};

const pulseBadgeStyle: React.CSSProperties = {
  width: '8px',
  height: '8px',
  borderRadius: '50%',
  backgroundColor: '#d29922',
  boxShadow: '0 0 0 0 rgba(210, 153, 34, 0.7)',
  animation: 'pulse 1.8s infinite',
};

const titleTextStyle: React.CSSProperties = {
  fontSize: '14px',
  fontWeight: '600',
  color: '#e6edf3',
  textTransform: 'uppercase',
  letterSpacing: '0.05em',
};

const countBadgeStyle: React.CSSProperties = {
  fontSize: '11px',
  fontWeight: '700',
  backgroundColor: '#d29922',
  color: '#0d1117',
  padding: '1px 6px',
  borderRadius: '10px',
  lineHeight: '1',
};

const titleSubTextStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
};

const listStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
};

const cardStyle: React.CSSProperties = {
  backgroundColor: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '6px',
  padding: '14px',
  display: 'flex',
  flexDirection: 'column',
  gap: '10px',
};

const cardHeaderStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
};

const badgeStyle: React.CSSProperties = {
  fontSize: '10px',
  fontWeight: '600',
  padding: '2px 8px',
  borderRadius: '12px',
  textTransform: 'uppercase',
  letterSpacing: '0.02em',
};

const cardTimeStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#6e7681',
};

const cardBodyStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
};

const toolPromptStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#c9d1d9',
  lineHeight: '1.4',
};

const codeNameStyle: React.CSSProperties = {
  fontFamily: 'monospace',
  background: '#21262d',
  color: '#ff7b72',
  padding: '2px 6px',
  borderRadius: '4px',
  fontSize: '12px',
};

const editorContainerStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const editorHeaderStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  fontSize: '11px',
  color: '#8b949e',
  fontWeight: '500',
};

const errorBadgeStyle: React.CSSProperties = {
  color: '#ff7b72',
  fontWeight: '600',
};

const textareaStyle: React.CSSProperties = {
  backgroundColor: '#0d1117',
  color: '#79c0ff',
  fontFamily: '"Fira Code", "Cascadia Code", Consolas, monospace',
  fontSize: '12px',
  border: '1px solid #30363d',
  borderRadius: '6px',
  padding: '8px 10px',
  outline: 'none',
  resize: 'vertical',
  lineHeight: '1.5',
};

const noteContainerStyle: React.CSSProperties = {
  display: 'flex',
};

const inputStyle: React.CSSProperties = {
  flex: 1,
  backgroundColor: '#0d1117',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  padding: '8px 10px',
  fontSize: '12px',
  outline: 'none',
};

const cardErrorStyle: React.CSSProperties = {
  color: '#ff7b72',
  fontSize: '12px',
  fontWeight: '500',
};

const actionsRowStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'flex-end',
  gap: '8px',
};

const buttonStyle: React.CSSProperties = {
  border: '1px solid #30363d',
  borderRadius: '6px',
  padding: '6px 12px',
  fontSize: '12px',
  fontWeight: '600',
  cursor: 'pointer',
  transition: 'all 0.15s ease',
  outline: 'none',
};

const denyButtonStyle: React.CSSProperties = {
  backgroundColor: '#21262d',
  color: '#ff7b72',
  borderColor: '#30363d',
  WebkitUserSelect: 'none',
  userSelect: 'none',
};

const allowButtonStyle: React.CSSProperties = {
  backgroundColor: '#238636',
  color: '#ffffff',
  borderColor: '#2ea043',
};

const allowAlwaysButtonStyle: React.CSSProperties = {
  backgroundColor: '#1f6feb',
  color: '#ffffff',
  borderColor: '#388bfd',
};

// User Question Styles
const questionTextStyle: React.CSSProperties = {
  fontSize: '14px',
  fontWeight: '500',
  color: '#f0f6fc',
  lineHeight: '1.5',
  padding: '6px 8px',
  backgroundColor: '#0d1117',
  borderLeft: '2px solid #58a6ff',
  borderRadius: '0 4px 4px 0',
};

const optionsContainerStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const optionsLabelStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
};

const optionsGridStyle: React.CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  gap: '8px',
};

const optionBtnStyle: React.CSSProperties = {
  border: '1px solid',
  borderRadius: '6px',
  padding: '6px 12px',
  fontSize: '12px',
  fontWeight: '500',
  cursor: 'pointer',
  transition: 'all 0.15s ease',
  outline: 'none',
};

const answerContainerStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
};

// Secret styles
const secretNameStyle: React.CSSProperties = {
  fontFamily: 'monospace',
  color: '#bc8cff',
  background: 'rgba(188, 140, 255, 0.1)',
  padding: '2px 6px',
  borderRadius: '4px',
};

const reasonContainerStyle: React.CSSProperties = {
  backgroundColor: '#0d1117',
  padding: '8px 10px',
  borderRadius: '6px',
  border: '1px solid #21262d',
};

const reasonLabelStyle: React.CSSProperties = {
  fontSize: '10px',
  color: '#8b949e',
  textTransform: 'uppercase',
  marginBottom: '2px',
};

const reasonTextStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  fontStyle: 'italic',
};
