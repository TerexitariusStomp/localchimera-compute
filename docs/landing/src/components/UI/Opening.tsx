import { motion } from 'framer-motion';

interface OpeningProps {
  onContinue: () => void;
}

export function Opening({ onContinue }: OpeningProps) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 flex items-center justify-center z-50 bg-deep-space-900"
    >
      <div className="text-center max-w-3xl px-8">
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.5, duration: 1 }}
          className="text-6xl font-bold text-white mb-8 leading-tight"
        >
          What if your organization was code
          <br />
          <span className="text-electric-blue-500">that could rewrite itself?</span>
        </motion.h1>

        <motion.button
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 2 }}
          whileHover={{ scale: 1.05 }}
          whileTap={{ scale: 0.95 }}
          onClick={onContinue}
          className="px-8 py-4 bg-electric-blue-500 text-white text-xl font-bold rounded-lg hover:bg-electric-blue-600 transition-colors"
        >
          Begin Journey
        </motion.button>
      </div>
    </motion.div>
  );
}
