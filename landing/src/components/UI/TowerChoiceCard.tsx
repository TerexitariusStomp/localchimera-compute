import { motion } from 'framer-motion';

interface TowerChoiceCardProps {
  title: string;
  description: string;
  impact: string;
  onSelect: () => void;
  index: number;
  color?: string;
}

export function TowerChoiceCard({
  title,
  description,
  impact,
  onSelect,
  index,
  color = '#00d9ff'
}: TowerChoiceCardProps) {
  return (
    <motion.button
      initial={{ opacity: 0, y: 50, scale: 0.9 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      transition={{
        delay: index * 0.15,
        type: 'spring',
        damping: 15,
        stiffness: 100
      }}
      whileHover={{
        scale: 1.03,
        y: -5,
        transition: { duration: 0.2 }
      }}
      whileTap={{ scale: 0.97 }}
      onClick={onSelect}
      className="relative group text-left overflow-hidden rounded-2xl"
      style={{
        background: 'rgba(10, 10, 15, 0.6)',
        backdropFilter: 'blur(20px)',
        border: '1px solid rgba(255, 255, 255, 0.1)',
      }}
    >
      {/* Hover gradient overlay */}
      <motion.div
        className="absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-300"
        style={{
          background: `linear-gradient(135deg, ${color}15 0%, transparent 100%)`
        }}
      />

      {/* Border glow on hover */}
      <motion.div
        className="absolute inset-0 rounded-2xl opacity-0 group-hover:opacity-100 transition-opacity duration-300"
        style={{
          boxShadow: `inset 0 0 20px ${color}40, 0 0 20px ${color}20`
        }}
      />

      {/* Content */}
      <div className="relative z-10 p-6 space-y-3">
        {/* Title with accent */}
        <div className="flex items-start justify-between">
          <h3 className="text-2xl font-bold text-white group-hover:text-transparent group-hover:bg-gradient-to-r group-hover:from-white group-hover:to-gray-300 group-hover:bg-clip-text transition-all duration-300">
            {title}
          </h3>
          <motion.div
            className="w-2 h-2 rounded-full"
            style={{ backgroundColor: color }}
            animate={{
              scale: [1, 1.5, 1],
              opacity: [0.5, 1, 0.5]
            }}
            transition={{
              duration: 2,
              repeat: Infinity,
              ease: "easeInOut"
            }}
          />
        </div>

        {/* Description */}
        <p className="text-gray-200 text-base leading-relaxed">
          {description}
        </p>

        {/* Impact badge */}
        <div className="pt-2">
          <div
            className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full text-sm font-medium"
            style={{
              background: `${color}20`,
              border: `1px solid ${color}40`,
              color: color
            }}
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            {impact}
          </div>
        </div>
      </div>

      {/* Bottom accent line */}
      <motion.div
        className="absolute bottom-0 left-0 right-0 h-1"
        style={{
          background: `linear-gradient(90deg, transparent 0%, ${color} 50%, transparent 100%)`,
          opacity: 0
        }}
        whileHover={{ opacity: 1 }}
        transition={{ duration: 0.3 }}
      />
    </motion.button>
  );
}
