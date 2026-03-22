import { motion } from 'framer-motion';

interface ProgressIndicatorProps {
  current: number;
  total: number;
}

export function ProgressIndicator({ current, total }: ProgressIndicatorProps) {
  return (
    <div className="fixed top-8 right-8 flex gap-2 z-50">
      {Array.from({ length: total }).map((_, index) => (
        <motion.div
          key={index}
          initial={{ scale: 0 }}
          animate={{ scale: 1 }}
          transition={{ delay: index * 0.1 }}
          className={`w-3 h-3 rounded-full ${
            index < current
              ? 'bg-electric-blue-500'
              : index === current
              ? 'bg-electric-blue-500 ring-2 ring-white'
              : 'bg-gray-700'
          }`}
        />
      ))}
    </div>
  );
}
