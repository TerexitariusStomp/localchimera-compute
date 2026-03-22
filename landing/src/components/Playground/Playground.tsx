import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { useJourneyStore } from '../../store/journeyStore';
import { evaluate } from '../../simulation';

const EXAMPLE_COMMANDS = [
  { label: 'View budget', code: 'budget' },
  { label: 'Change budget', code: "(modify! 'budget 75000)" },
  { label: 'Add member', code: "(defexpressor 'alex \"alex-key\")" },
  { label: 'View history', code: '(show-history)' },
  { label: 'List members', code: '(show-expressors)' },
  { label: 'Set status', code: "(modify! 'proposal-status 'approved)" },
];

export function Playground() {
  const { playgroundOpen, simState, updateSimState } = useJourneyStore();
  const [input, setInput] = useState('');
  const [output, setOutput] = useState<string[]>([
    '💡 Now you control the organization',
    '📝 Click examples below to try them, or write your own',
    '✨ Watch the 3D scene and state update in real-time',
    ''
  ]);

  const handleExecute = () => {
    if (!input.trim()) return;

    try {
      // Check if it's a simple symbol lookup
      if (!input.includes('(') && !input.includes("'")) {
        const binding = simState.bindings.get(input);
        if (binding) {
          setOutput([...output, `play[${simState.currentExpressor}]> ${input}`, `=> ${JSON.stringify(binding.value)}`, '']);
          setInput('');
          return;
        }
      }

      // Special cases for show commands
      if (input.includes('show-history')) {
        const history = simState.history.map((h) =>
          `  v${h.version} [${h.expressor}]: ${h.expression.substring(0, 50)}${h.expression.length > 50 ? '...' : ''}`
        ).join('\n');
        setOutput([...output, `play[${simState.currentExpressor}]> ${input}`, history, '']);
        setInput('');
        return;
      }

      if (input.includes('show-expressors')) {
        const expressors = Array.from(simState.expressors.values()).map(e =>
          `  • ${e.name} (${e.color})`
        ).join('\n');
        setOutput([...output, `play[${simState.currentExpressor}]> ${input}`, expressors, '']);
        setInput('');
        return;
      }

      const newState = evaluate(input, simState);
      updateSimState(newState);

      // Show what changed
      const changes: string[] = [];
      newState.bindings.forEach((binding, key) => {
        const oldBinding = simState.bindings.get(key);
        if (!oldBinding || oldBinding.value !== binding.value) {
          changes.push(`  ✓ ${key}: ${JSON.stringify(binding.value)}`);
        }
      });

      if (changes.length > 0) {
        setOutput([...output, `play[${newState.currentExpressor}]> ${input}`, '✓ Success! Changes:', ...changes, '']);
      } else {
        setOutput([...output, `play[${newState.currentExpressor}]> ${input}`, '✓ Success', '']);
      }
      setInput('');
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : String(error);
      setOutput([...output, `play[${simState.currentExpressor}]> ${input}`, `✗ Error: ${errorMsg}`, '']);
      setInput('');
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleExecute();
    }
  };

  const handleClose = () => {
    useJourneyStore.getState().togglePlayground();
  };

  const handleExampleClick = (code: string) => {
    setInput(code);
  };

  return (
    <AnimatePresence>
      {playgroundOpen && (
        <motion.div
          initial={{ x: '100%' }}
          animate={{ x: 0 }}
          exit={{ x: '100%' }}
          transition={{ type: 'spring', damping: 25, stiffness: 200 }}
          className="fixed right-0 top-0 h-screen w-[600px] z-50 flex flex-col shadow-2xl"
          style={{
            background: 'rgba(10, 10, 15, 0.95)',
            backdropFilter: 'blur(20px)',
            borderLeft: '1px solid rgba(0, 217, 255, 0.2)',
          }}
        >
          {/* Header */}
          <div
            className="p-6 flex justify-between items-center"
            style={{
              background: 'linear-gradient(135deg, rgba(0, 217, 255, 0.1) 0%, rgba(168, 85, 247, 0.1) 100%)',
              borderBottom: '1px solid rgba(255, 255, 255, 0.1)',
            }}
          >
            <div>
              <h3 className="text-2xl font-black text-transparent bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 bg-clip-text">
                Live Playground
              </h3>
              <p className="text-sm text-gray-400 mt-1">
                Make changes and see them happen instantly
              </p>
            </div>
            <button
              onClick={handleClose}
              className="w-10 h-10 rounded-full flex items-center justify-center hover:bg-white/10 transition-colors"
            >
              <svg className="w-6 h-6 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          {/* Examples Section */}
          <div className="p-4 border-b border-white/10">
            <p className="text-xs text-gray-400 mb-2 font-semibold">Try these commands:</p>
            <div className="grid grid-cols-2 gap-2">
              {EXAMPLE_COMMANDS.map((ex, i) => (
                <button
                  key={i}
                  onClick={() => handleExampleClick(ex.code)}
                  className="text-left px-3 py-2 bg-white/5 hover:bg-white/10 rounded-lg border border-white/10 hover:border-electric-blue-500/50 transition-all text-xs"
                >
                  <div className="text-gray-300 font-medium">{ex.label}</div>
                  <div className="text-gray-400 font-mono text-[10px] mt-1 truncate">{ex.code}</div>
                </button>
              ))}
            </div>
          </div>

          {/* Output */}
          <div className="flex-1 overflow-y-auto p-6 font-mono text-sm space-y-1">
            {output.map((line, i) => (
              <div
                key={i}
                className={
                  line.startsWith('✗')
                    ? 'text-red-400'
                    : line.startsWith('✓')
                    ? 'text-green-400'
                    : line.startsWith('play[')
                    ? 'text-electric-blue-400 font-bold'
                    : line.startsWith('  ')
                    ? 'text-gray-400 pl-4'
                    : line.startsWith('💡') || line.startsWith('📝')
                    ? 'text-yellow-400'
                    : 'text-gray-300'
                }
              >
                {line}
              </div>
            ))}
          </div>

          {/* Input */}
          <div
            className="p-6"
            style={{
              borderTop: '1px solid rgba(255, 255, 255, 0.1)',
              background: 'rgba(0, 0, 0, 0.3)',
            }}
          >
            <div className="flex items-start gap-3 mb-3">
              <span className="text-electric-blue-500 font-mono text-sm whitespace-nowrap pt-3 font-bold">
                play[{simState.currentExpressor}]&gt;
              </span>
              <textarea
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder="Type an expression or click an example above"
                className="flex-1 bg-black/40 text-white font-mono text-sm p-3 rounded-lg border border-gray-700 focus:border-electric-blue-500 focus:outline-none resize-none transition-colors"
                rows={2}
                style={{
                  boxShadow: '0 4px 12px rgba(0, 0, 0, 0.3)',
                }}
              />
            </div>
            <div className="flex justify-between items-center text-xs text-gray-400">
              <span>Enter to execute • Shift+Enter for new line</span>
              <button
                onClick={handleExecute}
                disabled={!input.trim()}
                className="px-4 py-2 bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 text-white font-bold rounded-lg hover:scale-105 transition-transform text-xs disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:scale-100"
              >
                Execute
              </button>
            </div>
          </div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
