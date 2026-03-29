import { motion } from 'framer-motion';
import type { TowerDecisionScene } from '../../scenes/frontierTowerDecisions';
import { TowerChoiceCard } from './TowerChoiceCard';

interface TowerDecisionOverlayProps {
  scene: TowerDecisionScene;
  onChoice: (choiceId: string) => void;
}

const choiceColors = ['#00d9ff', '#a855f7', '#ff6b35', '#10b981'];

export function TowerDecisionOverlay({ scene, onChoice }: TowerDecisionOverlayProps) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 flex items-center justify-center z-40 pointer-events-none"
      style={{
        background: 'radial-gradient(circle at 50% 50%, rgba(0, 0, 0, 0.8) 0%, rgba(0, 0, 0, 0.95) 100%)'
      }}
    >
      <div className="max-w-6xl w-full px-8 pointer-events-auto">
        {/* Header with glassmorphism */}
        <motion.div
          initial={{ y: -50, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ delay: 0.2, type: 'spring', damping: 20 }}
          className="text-center mb-8 p-8 rounded-3xl"
          style={{
            background: 'rgba(10, 10, 15, 0.7)',
            backdropFilter: 'blur(20px)',
            border: '1px solid rgba(255, 255, 255, 0.1)',
            boxShadow: '0 8px 32px rgba(0, 0, 0, 0.4)'
          }}
        >
          {/* Context tag */}
          <motion.div
            initial={{ scale: 0 }}
            animate={{ scale: 1 }}
            transition={{ delay: 0.3, type: 'spring' }}
            className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-gradient-to-r from-electric-blue-500/20 to-vibrant-purple-500/20 border border-electric-blue-500/30 mb-6"
          >
            <div className="w-2 h-2 rounded-full bg-electric-blue-500 animate-pulse" />
            <span className="text-sm font-medium text-electric-blue-500">Scenario {scene.id} of 6</span>
          </motion.div>

          <h2 className="text-5xl font-black text-white mb-4 leading-tight">
            {scene.title}
          </h2>
          <p className="text-xl text-gray-300 mb-6 leading-relaxed">
            {scene.description}
          </p>

          {/* What you're deciding */}
          <div className="mt-6 pt-6 border-t border-white/10">
            <p className="text-sm text-gray-500 uppercase tracking-wide mb-2">The Decision</p>
            <p className="text-base text-gray-300 leading-relaxed max-w-3xl mx-auto">
              {scene.context}
            </p>
          </div>
        </motion.div>

        {/* Choices grid */}
        <div className={`grid gap-6 ${scene.choices.length === 2 ? 'grid-cols-2' : scene.choices.length === 3 ? 'grid-cols-3' : 'grid-cols-2'}`}>
          {scene.choices.map((choice, index) => (
            <TowerChoiceCard
              key={choice.id}
              title={choice.title}
              description={choice.description}
              impact={choice.impact}
              onSelect={() => onChoice(choice.id)}
              index={index}
              color={choiceColors[index % choiceColors.length]}
            />
          ))}
        </div>

        {/* Hint */}
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 1 }}
          className="text-center mt-8 text-sm text-gray-400"
        >
          Each choice executes actual playnet code that shapes the organization
        </motion.div>
      </div>
    </motion.div>
  );
}
