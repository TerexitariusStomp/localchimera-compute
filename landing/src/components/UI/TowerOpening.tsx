import { motion } from 'framer-motion';

interface TowerOpeningProps {
  onContinue: () => void;
}

export function TowerOpening({ onContinue }: TowerOpeningProps) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.8 }}
      className="fixed inset-0 flex items-center justify-center z-50 bg-gradient-to-b from-deep-space-900 via-deep-space-800 to-black"
      style={{
        backgroundImage: 'radial-gradient(circle at 50% 50%, rgba(0, 217, 255, 0.1) 0%, transparent 50%)'
      }}
    >
      <div className="text-center max-w-5xl px-8">
        <motion.div
          initial={{ scale: 0.9, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          transition={{ delay: 0.3, duration: 1, ease: "easeOut" }}
          className="mb-12"
        >
          <div className="text-8xl font-black mb-6 bg-gradient-to-r from-electric-blue-500 via-vibrant-purple-500 to-warm-orange-500 bg-clip-text text-transparent leading-tight">
            xorg
          </div>
          <div className="text-2xl text-gray-300 font-light tracking-wide mb-8">
            Express and Experiment with Organization
          </div>
        </motion.div>

        <motion.div
          initial={{ y: 20, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ delay: 1, duration: 0.8 }}
          className="space-y-8 mb-12"
        >
          <h1 className="text-5xl font-bold text-white leading-tight">
            Organizations that
            <br />
            <span className="bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 bg-clip-text text-transparent">
              rewrite their own rules
            </span>
          </h1>

          <p className="text-xl text-gray-300 max-w-3xl mx-auto leading-relaxed">
            Every decision is code. Every rule can evolve. Every change is reversible.
            <br />
            <span className="text-gray-300">Watch how Frontier Tower governs itself.</span>
          </p>
        </motion.div>

        <motion.button
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 1.8, duration: 0.6 }}
          whileHover={{ scale: 1.05, boxShadow: "0 0 30px rgba(0, 217, 255, 0.6)" }}
          whileTap={{ scale: 0.95 }}
          onClick={onContinue}
          className="group relative px-12 py-5 bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 text-white text-xl font-bold rounded-full overflow-hidden transition-all duration-300"
        >
          <span className="relative z-10">See it in Action</span>
          <motion.div
            className="absolute inset-0 bg-gradient-to-r from-vibrant-purple-500 to-warm-orange-500 opacity-0 group-hover:opacity-100 transition-opacity duration-300"
          />
        </motion.button>

        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 2.5, duration: 1 }}
          className="mt-12 text-sm text-gray-400"
        >
          An interactive introduction to programmable governance
        </motion.div>
      </div>
    </motion.div>
  );
}
