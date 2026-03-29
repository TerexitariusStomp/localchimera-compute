import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';

interface HolographicTerminalProps {
  visible: boolean;
  prefilledCode?: string;
  onExecute: (code: string) => void;
  onComplete?: () => void;
  prompt?: string;
}

export function HolographicTerminal({
  visible,
  prefilledCode = '',
  onExecute,
  onComplete,
  prompt = 'playnet'
}: HolographicTerminalProps) {
  const [code, setCode] = useState('');
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [isTyping, setIsTyping] = useState(false);
  const [cursorVisible, setCursorVisible] = useState(true);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Cursor blink
  useEffect(() => {
    const interval = setInterval(() => {
      setCursorVisible(v => !v);
    }, 530);
    return () => clearInterval(interval);
  }, []);

  // Typewriter effect for prefilled code
  useEffect(() => {
    if (prefilledCode && visible) {
      setIsTyping(true);
      setCode('');

      let index = 0;
      const interval = setInterval(() => {
        setCode(prefilledCode.slice(0, index + 1));
        index++;

        if (index >= prefilledCode.length) {
          clearInterval(interval);
          setIsTyping(false);
        }
      }, 30);

      return () => clearInterval(interval);
    }
  }, [prefilledCode, visible]);

  const handleExecute = () => {
    if (!code.trim() || isTyping) return;

    onExecute(code);
    setHistory([...history, code]);
    setHistoryIndex(-1);

    // Visual feedback
    const textarea = textareaRef.current;
    if (textarea) {
      textarea.classList.add('execute-flash');
      setTimeout(() => {
        textarea.classList.remove('execute-flash');
      }, 300);
    }

    setTimeout(() => {
      if (onComplete) onComplete();
    }, 500);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (isTyping) {
      e.preventDefault();
      return;
    }

    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleExecute();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      if (history.length > 0) {
        const newIndex = historyIndex < history.length - 1 ? historyIndex + 1 : historyIndex;
        setHistoryIndex(newIndex);
        setCode(history[history.length - 1 - newIndex]);
      }
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (historyIndex > 0) {
        const newIndex = historyIndex - 1;
        setHistoryIndex(newIndex);
        setCode(history[history.length - 1 - newIndex]);
      } else if (historyIndex === 0) {
        setHistoryIndex(-1);
        setCode('');
      }
    }
  };

  // Syntax highlighting (simple scheme)
  const highlightCode = (text: string) => {
    return text
      .replace(/(\(|\))/g, '<span class="paren">$1</span>')
      .replace(/(modify!|defexpressor|enact!|as|show-history|show-expressors)/g, '<span class="keyword">$1</span>')
      .replace(/('[a-zA-Z0-9-]+)/g, '<span class="symbol">$1</span>')
      .replace(/(".*?")/g, '<span class="string">$1</span>')
      .replace(/(\d+)/g, '<span class="number">$1</span>');
  };

  return (
    <AnimatePresence>
      {visible && (
        <motion.div
          initial={{ y: '100%', opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          exit={{ y: '100%', opacity: 0 }}
          transition={{
            type: 'spring',
            damping: 30,
            stiffness: 300,
            opacity: { duration: 0.2 }
          }}
          className="fixed bottom-0 left-0 right-0 z-50"
          style={{
            height: '35vh',
            background: 'linear-gradient(to top, rgba(10, 10, 15, 0.98), rgba(10, 10, 15, 0.95))',
            backdropFilter: 'blur(20px)',
            borderTop: '2px solid rgba(0, 217, 255, 0.5)',
            boxShadow: '0 -10px 60px rgba(0, 217, 255, 0.2), inset 0 1px 0 rgba(255, 255, 255, 0.1)',
          }}
        >
          {/* Scan lines effect */}
          <div
            className="absolute inset-0 pointer-events-none"
            style={{
              backgroundImage: 'repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0, 217, 255, 0.03) 2px, rgba(0, 217, 255, 0.03) 4px)',
              animation: 'scan 8s linear infinite'
            }}
          />

          {/* Holographic edge glow */}
          <motion.div
            className="absolute top-0 left-0 right-0 h-1"
            style={{
              background: 'linear-gradient(90deg, transparent, #00d9ff, #a855f7, #00d9ff, transparent)',
              filter: 'blur(4px)'
            }}
            animate={{
              opacity: [0.5, 1, 0.5],
            }}
            transition={{
              duration: 2,
              repeat: Infinity,
              ease: 'easeInOut'
            }}
          />

          <div className="relative h-full p-8 flex flex-col">
            {/* Terminal header */}
            <div className="flex items-center gap-3 mb-4">
              <motion.div
                className="w-3 h-3 rounded-full bg-electric-blue-500"
                animate={{
                  opacity: [0.5, 1, 0.5],
                  scale: [1, 1.2, 1]
                }}
                transition={{
                  duration: 2,
                  repeat: Infinity,
                }}
              />
              <div className="text-electric-blue-500 font-mono text-sm font-bold tracking-wider">
                {prompt.toUpperCase()} LIVE TERMINAL
              </div>
              <div className="text-xs text-gray-500 font-mono">
                // Type or edit code below
              </div>
            </div>

            {/* Code input area */}
            <div className="flex-1 relative">
              <div className="flex items-start gap-3">
                {/* Prompt */}
                <div className="text-electric-blue-500 font-mono text-lg pt-2 whitespace-nowrap select-none">
                  {prompt}[genesis]&gt;
                </div>

                {/* Code editor */}
                <div className="flex-1 relative">
                  <textarea
                    ref={textareaRef}
                    value={code}
                    onChange={(e) => !isTyping && setCode(e.target.value)}
                    onKeyDown={handleKeyDown}
                    disabled={isTyping}
                    className="w-full h-32 bg-transparent text-white font-mono text-lg p-2 outline-none resize-none"
                    style={{
                      caretColor: cursorVisible ? '#00d9ff' : 'transparent'
                    }}
                    placeholder="(modify! 'value 42)"
                    spellCheck={false}
                  />

                  {/* Syntax highlighting overlay */}
                  <div
                    className="absolute inset-0 pointer-events-none font-mono text-lg p-2 opacity-0"
                    dangerouslySetInnerHTML={{ __html: highlightCode(code) }}
                  />
                </div>
              </div>
            </div>

            {/* Execute button */}
            <div className="flex justify-end gap-4 items-center">
              <div className="text-xs text-gray-500 font-mono">
                ENTER to execute • SHIFT+ENTER new line • ↑↓ history
              </div>
              <motion.button
                onClick={handleExecute}
                disabled={!code.trim() || isTyping}
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                className="relative px-8 py-3 font-mono font-bold text-sm overflow-hidden disabled:opacity-50 disabled:cursor-not-allowed"
                style={{
                  background: 'linear-gradient(135deg, #00d9ff, #a855f7)',
                  borderRadius: '4px',
                  boxShadow: '0 0 20px rgba(0, 217, 255, 0.5)',
                }}
              >
                <span className="relative z-10">EXECUTE</span>
                <motion.div
                  className="absolute inset-0 bg-white"
                  initial={{ opacity: 0 }}
                  animate={{ opacity: [0, 0.2, 0] }}
                  transition={{ duration: 1.5, repeat: Infinity }}
                />
              </motion.button>
            </div>
          </div>

          <style>{`
            @keyframes scan {
              0% { transform: translateY(-100%); }
              100% { transform: translateY(100%); }
            }

            .execute-flash {
              animation: flash 0.3s;
            }

            @keyframes flash {
              0%, 100% { opacity: 1; }
              50% { opacity: 0.5; }
            }

            .paren { color: #94a3b8; }
            .keyword { color: #a855f7; font-weight: bold; }
            .symbol { color: #00d9ff; }
            .string { color: #10b981; }
            .number { color: #f59e0b; }
          `}</style>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
