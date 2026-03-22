import { motion } from 'framer-motion';

interface ChoiceCardProps {
  title: string;
  description: string;
  onSelect: () => void;
  index: number;
}

export function ChoiceCard({ title, description, onSelect, index }: ChoiceCardProps) {
  return (
    <motion.button
      initial={{ opacity: 0, y: 50 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: index * 0.2, type: 'spring', damping: 20 }}
      whileHover={{ scale: 1.05 }}
      whileTap={{ scale: 0.95 }}
      onClick={onSelect}
      className="relative bg-deep-space-800 border-2 border-gray-700 rounded-lg p-6 text-left hover:border-electric-blue-500 transition-all group"
    >
      <div className="absolute inset-0 bg-electric-blue-500 opacity-0 group-hover:opacity-10 rounded-lg transition-opacity" />

      <h3 className="text-xl font-bold text-white mb-2 group-hover:text-electric-blue-500 transition-colors">
        {title}
      </h3>
      <p className="text-gray-400 text-sm">
        {description}
      </p>
    </motion.button>
  );
}
