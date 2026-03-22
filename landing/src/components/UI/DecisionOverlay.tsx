import { motion } from 'framer-motion';
import type { DecisionScene } from '../../scenes/decisions';
import { ChoiceCard } from './ChoiceCard';

interface DecisionOverlayProps {
  scene: DecisionScene;
  onChoice: (choiceId: string) => void;
}

export function DecisionOverlay({ scene, onChoice }: DecisionOverlayProps) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 flex items-center justify-center z-40 pointer-events-none"
    >
      <div className="max-w-4xl w-full px-8 pointer-events-auto">
        <motion.div
          initial={{ y: 50, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ delay: 0.2 }}
          className="text-center mb-8"
        >
          <h2 className="text-4xl font-bold text-white mb-4">
            {scene.title}
          </h2>
          <p className="text-xl text-gray-400">
            {scene.description}
          </p>
        </motion.div>

        <div className={`grid gap-4 ${scene.choices.length <= 2 ? 'grid-cols-2' : 'grid-cols-2'}`}>
          {scene.choices.map((choice, index) => (
            <ChoiceCard
              key={choice.id}
              title={choice.title}
              description={choice.description}
              onSelect={() => onChoice(choice.id)}
              index={index}
            />
          ))}
        </div>
      </div>
    </motion.div>
  );
}
