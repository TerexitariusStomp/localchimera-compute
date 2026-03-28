import { useState, useEffect } from 'react';
import { AnimatePresence } from 'framer-motion';
import { Scene } from './Scene';
import { DecisionOverlay, ProgressIndicator, Opening } from '../UI';
import { Playground } from '../Playground';
import { useJourneyStore } from '../../store/journeyStore';
import { decisions } from '../../scenes/decisions';
import { evaluate } from '../../simulation';

export function Journey() {
  const [showOpening, setShowOpening] = useState(true);
  const [showDecision, setShowDecision] = useState(false);
  const { currentDecision, makeChoice, simState, updateSimState, togglePlayground } = useJourneyStore();

  const currentScene = decisions[currentDecision];

  useEffect(() => {
    if (!showOpening && currentDecision < decisions.length) {
      const timer = setTimeout(() => {
        setShowDecision(true);
      }, 1000);
      return () => clearTimeout(timer);
    }
  }, [currentDecision, showOpening]);

  const handleChoice = async (choiceId: string) => {
    const choice = currentScene?.choices.find(c => c.id === choiceId);

    // Execute setup code if this is a new scene
    if (currentScene?.setup) {
      try {
        const newState = evaluate(currentScene.setup, simState);
        updateSimState(newState);
      } catch (error) {
        console.error('Setup failed:', error);
      }
    }

    // Execute choice code if any
    if (choice?.code) {
      try {
        const newState = evaluate(choice.code, simState);
        updateSimState(newState);
      } catch (error) {
        console.error('Choice execution failed:', error);
      }
    }

    // Unlock playground if specified
    if (currentScene?.unlockPlayground) {
      togglePlayground();
    }

    makeChoice(choiceId);
    setShowDecision(false);
  };

  const handleBegin = () => {
    setShowOpening(false);
  };

  return (
    <div className="relative w-full h-screen overflow-hidden bg-deep-space-900">
      <Scene />

      <AnimatePresence>
        {showOpening && <Opening onContinue={handleBegin} />}
      </AnimatePresence>

      <AnimatePresence>
        {showDecision && currentScene && (
          <DecisionOverlay scene={currentScene} onChoice={handleChoice} />
        )}
      </AnimatePresence>

      {!showOpening && <ProgressIndicator current={currentDecision} total={decisions.length} />}

      <Playground />
    </div>
  );
}
