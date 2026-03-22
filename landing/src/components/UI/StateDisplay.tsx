import { motion, AnimatePresence } from 'framer-motion';
import { useJourneyStore } from '../../store/journeyStore';

export function StateDisplay() {
  const { simState } = useJourneyStore();

  // Extract key values to display
  const budget = simState.bindings.get('budget')?.value;
  const memberCount = simState.expressors.size;
  const proposalStatus = simState.bindings.get('proposal-status')?.value;
  const amenities = simState.bindings.get('amenities')?.value;
  const governanceModel = simState.bindings.get('governance-model')?.value;

  const displayItems = [
    { label: 'Tower Budget', value: budget ? `$${budget.toLocaleString()}` : 'Not set', show: !!budget },
    { label: 'Members', value: memberCount, show: true },
    { label: 'Proposal', value: proposalStatus, show: !!proposalStatus },
    { label: 'Amenities', value: amenities, show: !!amenities },
    { label: 'Governance', value: governanceModel, show: !!governanceModel },
  ].filter(item => item.show);

  if (displayItems.length === 0) return null;

  return (
    <motion.div
      initial={{ opacity: 0, y: -20 }}
      animate={{ opacity: 1, y: 0 }}
      className="fixed top-20 left-8 z-30"
    >
      <div
        className="p-4 rounded-2xl min-w-[250px]"
        style={{
          background: 'rgba(10, 10, 15, 0.8)',
          backdropFilter: 'blur(20px)',
          border: '1px solid rgba(255, 255, 255, 0.1)',
          boxShadow: '0 8px 32px rgba(0, 0, 0, 0.4)'
        }}
      >
        <h4 className="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wide">
          Tower State
        </h4>
        <div className="space-y-2">
          <AnimatePresence>
            {displayItems.map((item, i) => (
              <motion.div
                key={item.label}
                initial={{ opacity: 0, x: -20 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ delay: i * 0.1 }}
                className="flex justify-between items-center"
              >
                <span className="text-xs text-gray-300">{item.label}:</span>
                <motion.span
                  key={String(item.value)}
                  initial={{ scale: 1.3, color: '#00d9ff' }}
                  animate={{ scale: 1, color: '#ffffff' }}
                  transition={{ duration: 0.5 }}
                  className="text-sm font-bold text-white"
                >
                  {String(item.value)}
                </motion.span>
              </motion.div>
            ))}
          </AnimatePresence>
        </div>
      </div>
    </motion.div>
  );
}
