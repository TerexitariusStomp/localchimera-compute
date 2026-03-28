import { useState, useCallback } from 'react';
import { motion } from 'framer-motion';
import type { TowerDecisionScene } from '../../scenes/frontierTowerDecisions';

export type StoryPhase = 'intro' | 'scene-text' | 'code-input' | 'result' | 'transition';

interface StoryManagerProps {
  scenes: TowerDecisionScene[];
  onSceneComplete: (sceneId: number, choiceId: string) => void;
  onJourneyComplete: () => void;
  children: (state: StoryState) => React.ReactNode;
}

export interface StoryState {
  currentSceneIndex: number;
  currentScene: TowerDecisionScene | null;
  phase: StoryPhase;
  showTerminal: boolean;
  terminalCode: string;
  advanceToNextPhase: () => void;
  executeCode: (code: string) => void;
  makeChoice: (choiceId: string) => void;
}

export function StoryManager({ scenes, onSceneComplete, onJourneyComplete, children }: StoryManagerProps) {
  const [currentSceneIndex, setCurrentSceneIndex] = useState(0);
  const [phase, setPhase] = useState<StoryPhase>('intro');

  const currentScene = currentSceneIndex < scenes.length ? scenes[currentSceneIndex] : null;

  const advanceToNextPhase = useCallback(() => {
    if (phase === 'intro') {
      setPhase('scene-text');
    } else if (phase === 'scene-text') {
      setPhase('code-input');
    } else if (phase === 'code-input') {
      // User executed code, waiting for makeChoice
    } else if (phase === 'result') {
      setPhase('transition');
      setTimeout(() => {
        // Move to next scene
        const nextIndex = currentSceneIndex + 1;
        if (nextIndex < scenes.length) {
          setCurrentSceneIndex(nextIndex);
          setPhase('scene-text');
        } else {
          onJourneyComplete();
        }
      }, 2000);
    }
  }, [phase, currentSceneIndex, scenes.length, onJourneyComplete]);

  const executeCode = useCallback((_code: string) => {
    // Code was executed, now show choices
    // This doesn't advance phase - waiting for user to select choice
  }, []);

  const makeChoice = useCallback((choiceId: string) => {
    if (!currentScene) return;

    setPhase('result');

    // Notify parent
    onSceneComplete(currentScene.id, choiceId);

    // After showing result animation, advance
    setTimeout(() => {
      advanceToNextPhase();
    }, 3000);
  }, [currentScene, onSceneComplete, advanceToNextPhase]);

  const state: StoryState = {
    currentSceneIndex,
    currentScene,
    phase,
    showTerminal: phase === 'code-input',
    terminalCode: currentScene?.choices.find(c => c.code)?.code || '',
    advanceToNextPhase,
    executeCode,
    makeChoice,
  };

  return <>{children(state)}</>;
}

// Scene text component
interface SceneTextProps {
  scene: TowerDecisionScene;
  onContinue: () => void;
}

export function SceneText({ scene, onContinue }: SceneTextProps) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 flex items-center justify-center z-40 bg-black/70"
    >
      <div className="max-w-3xl px-8 text-center">
        <motion.div
          initial={{ y: 50, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ delay: 0.3 }}
        >
          <h2 className="text-5xl font-black text-white mb-6 leading-tight">
            {scene.title}
          </h2>
          <p className="text-2xl text-gray-300 mb-4">
            {scene.description}
          </p>
          <p className="text-lg text-gray-400">
            {scene.context}
          </p>
        </motion.div>

        <motion.button
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 1.5 }}
          onClick={onContinue}
          className="mt-12 px-10 py-4 bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 text-white text-xl font-bold rounded-full hover:scale-105 transition-transform"
        >
          Continue
        </motion.button>
      </div>
    </motion.div>
  );
}

// Choice selector component
interface ChoiceSelectorProps {
  scene: TowerDecisionScene;
  onSelect: (choiceId: string) => void;
}

export function ChoiceSelector({ scene, onSelect }: ChoiceSelectorProps) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed bottom-40 left-0 right-0 z-40 flex justify-center gap-6 px-8"
    >
      {scene.choices.map((choice, index) => (
        <motion.button
          key={choice.id}
          initial={{ y: 50, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ delay: index * 0.15 }}
          whileHover={{ scale: 1.05, y: -5 }}
          whileTap={{ scale: 0.95 }}
          onClick={() => onSelect(choice.id)}
          className="bg-deep-space-800/90 backdrop-blur-xl border-2 border-electric-blue-500/30 hover:border-electric-blue-500 rounded-2xl p-6 max-w-sm transition-all"
        >
          <h3 className="text-xl font-bold text-white mb-2">{choice.title}</h3>
          <p className="text-sm text-gray-300 mb-3">{choice.description}</p>
          <div className="text-xs text-electric-blue-400 font-mono">
            → {choice.impact}
          </div>
        </motion.button>
      ))}
    </motion.div>
  );
}
