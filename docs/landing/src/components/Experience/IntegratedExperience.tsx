import { Suspense, useState } from 'react';
import { Canvas } from '@react-three/fiber';
import { OrbitControls, PerspectiveCamera, Environment } from '@react-three/drei';
import { EffectComposer, Bloom } from '@react-three/postprocessing';
import { AnimatePresence, motion } from 'framer-motion';
import { LivingTower } from '../Visualizations/OrganicTower/LivingTower';
import { MemberNode } from '../Visualizations/OrganicTower/MemberNode';
import { HolographicTerminal } from '../Terminal/HolographicTerminal';
import { towerDecisions } from '../../scenes/frontierTowerDecisions';
import { evaluate } from '../../simulation';
import { useJourneyStore } from '../../store/journeyStore';
import * as THREE from 'three';

type Phase = 'opening' | 'scene-intro' | 'code-input' | 'choices' | 'result';

export function IntegratedExperience() {
  const [phase, setPhase] = useState<Phase>('opening');
  const [currentSceneIndex, setCurrentSceneIndex] = useState(0);
  const { simState, updateSimState } = useJourneyStore();

  const currentScene = towerDecisions[currentSceneIndex];

  const handleBegin = () => {
    setPhase('scene-intro');
  };

  const handleSceneIntroContinue = () => {
    setPhase('code-input');
  };

  const handleCodeExecute = (code: string) => {
    try {
      // Execute setup if first time
      if (currentScene.setup) {
        const setupState = evaluate(currentScene.setup, simState);
        updateSimState(setupState);
      }

      const newState = evaluate(code, simState);
      updateSimState(newState);
    } catch (error) {
      console.error('Code execution failed:', error);
    }

    setTimeout(() => {
      setPhase('choices');
    }, 1500);
  };

  const handleChoice = (choiceId: string) => {
    const choice = currentScene.choices.find(c => c.id === choiceId);

    if (choice?.code) {
      try {
        const newState = evaluate(choice.code, simState);
        updateSimState(newState);
      } catch (error) {
        console.error('Choice execution failed:', error);
      }
    }

    setPhase('result');

    setTimeout(() => {
      const nextIndex = currentSceneIndex + 1;
      if (nextIndex < towerDecisions.length) {
        setCurrentSceneIndex(nextIndex);
        setPhase('scene-intro');
      } else {
        setPhase('opening'); // Could show completion screen instead
      }
    }, 2000);
  };

  const floors = [
    { num: 1, name: 'Lobby', color: '#6b7280', yPosition: -15 },
    { num: 2, name: 'Coworking', color: '#8b5cf6', yPosition: -13 },
    { num: 3, name: 'Events & Social', color: '#ff6b35', yPosition: -11 },
    { num: 4, name: 'Quiet Study', color: '#10b981', yPosition: -9 },
    { num: 5, name: 'Maker Space', color: '#eab308', yPosition: -7 },
    { num: 6, name: 'Artist Studios', color: '#ec4899', yPosition: -5 },
    { num: 7, name: 'Robotics Lab', color: '#00d9ff', yPosition: -3 },
    { num: 8, name: 'Music Rooms', color: '#f97316', yPosition: -1 },
    { num: 9, name: 'Independent', color: '#f59e0b', yPosition: 1 },
    { num: 10, name: 'Reading Lounge', color: '#14b8a6', yPosition: 3 },
    { num: 11, name: 'Game Room', color: '#6366f1', yPosition: 5 },
    { num: 12, name: 'Garden Advocates', color: '#a855f7', yPosition: 7 },
    { num: 13, name: 'Fitness Center', color: '#ef4444', yPosition: 9 },
    { num: 14, name: 'Co-living', color: '#3b82f6', yPosition: 11 },
    { num: 15, name: 'Private Units', color: '#84cc16', yPosition: 13 },
    { num: 16, name: 'Rooftop', color: '#fbbf24', yPosition: 15 },
  ];

  const members = Array.from(simState.expressors.values())
    .filter(e => e.id !== 'genesis')
    .map((e, idx) => ({
      name: e.name,
      color: e.color,
      orbitRadius: 4 + idx * 0.5,
      orbitSpeed: 0.2 + idx * 0.05,
      height: idx * 2 - 2,
    }));

  return (
    <div className="relative w-full h-screen overflow-hidden bg-black">
      {/* Opening Screen */}
      <AnimatePresence>
        {phase === 'opening' && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 flex items-center justify-center bg-black z-[100]"
          >
            <div className="text-center max-w-4xl px-8">
              <div className="text-8xl font-black mb-8 bg-gradient-to-r from-electric-blue-500 via-vibrant-purple-500 to-warm-orange-500 bg-clip-text text-transparent leading-tight">
                playnet
              </div>
              <div className="text-3xl text-gray-200 mb-6 font-light">
                Symbolic Governance in a Persistent REPL
              </div>
              <h1 className="text-6xl font-bold mb-8 leading-tight text-white">
                Organizations that<br />
                <span className="text-electric-blue-400">
                  rewrite their own rules
                </span>
              </h1>
              <p className="text-2xl text-gray-300 mb-12 leading-relaxed">
                Homoiconic governance where code is data and rules evolve through symbolic reasoning. Built on Scheme's metaprogramming power.
              </p>
              <motion.button
                whileHover={{ scale: 1.05 }}
                whileTap={{ scale: 0.95 }}
                onClick={handleBegin}
                className="px-12 py-5 bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 text-white text-2xl font-bold rounded-full shadow-2xl"
              >
                Begin
              </motion.button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* 3D Canvas - Only show after opening */}
      {phase !== 'opening' && (
        <div className="absolute inset-0">
          <Canvas
            gl={{
              antialias: true,
              toneMapping: THREE.ACESFilmicToneMapping,
              toneMappingExposure: 1.2,
            }}
          >
            <PerspectiveCamera makeDefault position={[8, 3, 8]} fov={60} />
            <OrbitControls
              enableZoom={false}
              enablePan={false}
              autoRotate={phase !== 'code-input'}
              autoRotateSpeed={0.5}
            />

            <Suspense fallback={null}>
              <ambientLight intensity={0.4} />
              <directionalLight position={[10, 20, 10]} intensity={1.5} castShadow />
              <pointLight position={[0, 10, 0]} intensity={2} distance={30} color="#00d9ff" />

              <Environment preset="night" />
              <fog attach="fog" args={['#000000', 10, 40]} />

              <LivingTower
                floors={floors}
                activeFloor={currentScene?.id}
                scale={1}
              />

              {members.map((member) => (
                <MemberNode
                  key={member.name}
                  {...member}
                  active={phase === 'result'}
                />
              ))}

              <EffectComposer>
                <Bloom intensity={1} luminanceThreshold={0.2} luminanceSmoothing={0.9} />
              </EffectComposer>
            </Suspense>
          </Canvas>
        </div>
      )}

      {/* Scene Introduction */}
      <AnimatePresence>
        {phase === 'scene-intro' && currentScene && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 flex items-center justify-center z-50 bg-black/80"
          >
            <div className="max-w-3xl px-8 text-center">
              <motion.h2
                initial={{ y: 20, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                className="text-5xl font-black text-white mb-6"
              >
                {currentScene.title}
              </motion.h2>
              <motion.p
                initial={{ y: 20, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ delay: 0.2 }}
                className="text-2xl text-gray-300 mb-4"
              >
                {currentScene.description}
              </motion.p>
              <motion.p
                initial={{ y: 20, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ delay: 0.4 }}
                className="text-lg text-gray-400 mb-8"
              >
                {currentScene.context}
              </motion.p>
              <motion.button
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ delay: 0.8 }}
                onClick={handleSceneIntroContinue}
                className="px-10 py-4 bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 text-white text-xl font-bold rounded-full"
              >
                Continue
              </motion.button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Holographic Terminal */}
      <HolographicTerminal
        visible={phase === 'code-input'}
        prefilledCode={currentScene?.choices[0]?.code || ''}
        onExecute={handleCodeExecute}
      />

      {/* Choices */}
      <AnimatePresence>
        {phase === 'choices' && currentScene && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed bottom-20 left-0 right-0 z-40 flex justify-center gap-6 px-8"
          >
            {currentScene.choices.map((choice, idx) => (
              <motion.button
                key={choice.id}
                initial={{ y: 50, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ delay: idx * 0.15 }}
                whileHover={{ scale: 1.05, y: -5 }}
                onClick={() => handleChoice(choice.id)}
                className="bg-deep-space-800/90 backdrop-blur-xl border-2 border-electric-blue-500/30 hover:border-electric-blue-500 rounded-2xl p-6 max-w-sm"
              >
                <h3 className="text-xl font-bold text-white mb-2">{choice.title}</h3>
                <p className="text-sm text-gray-300 mb-3">{choice.description}</p>
                <div className="text-xs text-electric-blue-400">→ {choice.impact}</div>
              </motion.button>
            ))}
          </motion.div>
        )}
      </AnimatePresence>

      {/* Progress */}
      {phase !== 'opening' && (
        <div className="fixed top-8 right-8 flex gap-2 z-50">
          {towerDecisions.map((_, idx) => (
            <div
              key={idx}
              className={`w-3 h-3 rounded-full ${
                idx < currentSceneIndex
                  ? 'bg-electric-blue-500'
                  : idx === currentSceneIndex
                  ? 'bg-electric-blue-500 ring-2 ring-white'
                  : 'bg-gray-700'
              }`}
            />
          ))}
        </div>
      )}
    </div>
  );
}
