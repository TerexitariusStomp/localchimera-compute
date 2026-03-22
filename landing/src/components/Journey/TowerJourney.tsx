import { useState, useEffect } from 'react';
import { AnimatePresence } from 'framer-motion';
import { TowerScene } from './TowerScene';
import { TowerDecisionOverlay } from '../UI/TowerDecisionOverlay';
import { TowerOpening } from '../UI/TowerOpening';
import { StateDisplay } from '../UI/StateDisplay';
import { ProgressIndicator } from '../UI/ProgressIndicator';
import { Playground } from '../Playground';
import { useJourneyStore } from '../../store/journeyStore';
import { towerDecisions } from '../../scenes/frontierTowerDecisions';
import { evaluate } from '../../simulation';

export function TowerJourney() {
  const [showOpening, setShowOpening] = useState(true);
  const [showDecision, setShowDecision] = useState(false);
  const { currentDecision, makeChoice, simState, updateSimState, togglePlayground, playgroundOpen } = useJourneyStore();

  const currentScene = towerDecisions[currentDecision];

  useEffect(() => {
    console.log('Journey state:', { showOpening, currentDecision, currentScene: currentScene?.title });

    if (!showOpening && currentDecision < towerDecisions.length) {
      // Run setup code when entering a scene
      if (currentScene?.setup) {
        try {
          const newState = evaluate(currentScene.setup, simState);
          updateSimState(newState);
        } catch (error) {
          console.error('Setup failed:', error);
        }
      }

      const timer = setTimeout(() => {
        console.log('Showing decision overlay');
        setShowDecision(true);
      }, 1500);
      return () => clearTimeout(timer);
    }
  }, [currentDecision, showOpening, currentScene, simState, updateSimState]);

  const handleChoice = async (choiceId: string) => {
    console.log('Choice selected:', choiceId);
    const choice = currentScene?.choices.find(c => c.id === choiceId);

    // Execute choice code if any
    if (choice?.code) {
      try {
        const newState = evaluate(choice.code, simState);
        updateSimState(newState);
      } catch (error) {
        console.error('Choice execution failed:', error);
      }
    }

    makeChoice(choiceId);
    setShowDecision(false);

    // Unlock playground if specified - do this AFTER hiding decision overlay
    if (currentScene?.unlockPlayground && !playgroundOpen) {
      setTimeout(() => togglePlayground(), 1000);
    }
  };

  const handleBegin = () => {
    console.log('Begin button clicked');
    setShowOpening(false);
  };

  return (
    <div className="relative w-full h-screen overflow-hidden bg-gradient-to-b from-deep-space-900 via-black to-deep-space-800">
      {/* Always show scene after opening */}
      {!showOpening && <TowerScene />}

      {/* State display - show when not in opening or decision overlay */}
      {!showOpening && !showDecision && <StateDisplay />}

      <AnimatePresence>
        {showOpening && <TowerOpening onContinue={handleBegin} />}
      </AnimatePresence>

      <AnimatePresence>
        {showDecision && currentScene && (
          <TowerDecisionOverlay scene={currentScene} onChoice={handleChoice} />
        )}
      </AnimatePresence>

      {!showOpening && currentDecision < towerDecisions.length && (
        <ProgressIndicator current={currentDecision} total={towerDecisions.length} />
      )}

      {!showOpening && currentDecision >= towerDecisions.length && (
        <div className="fixed inset-0 flex items-center justify-center z-50 bg-black/90">
          <div className="text-center max-w-3xl px-8">
            <h2 className="text-6xl font-black text-white mb-8">
              That's xorg
            </h2>
            <div className="space-y-6 mb-12 text-left">
              <p className="text-xl text-gray-300 leading-relaxed">
                You just watched an organization <span className="text-electric-blue-500 font-semibold">rewrite its own rules</span>.
              </p>
              <p className="text-lg text-gray-400 leading-relaxed">
                Every decision was <span className="text-white">executable code</span>.
                Every rule could <span className="text-white">evolve</span>.
                Every change was <span className="text-white">reversible</span>.
              </p>
              <p className="text-base text-gray-400 leading-relaxed">
                Frontier Tower is one example. xorg works for any group that needs to adapt:
                co-ops, DAOs, research labs, open source projects, or any organization
                that wants its structure to be as flexible as its software.
              </p>
            </div>
            <div className="flex gap-4 justify-center">
              <button
                onClick={() => window.location.reload()}
                className="px-8 py-4 bg-gradient-to-r from-electric-blue-500 to-vibrant-purple-500 text-white text-lg font-bold rounded-full hover:scale-105 transition-transform"
              >
                Try Different Choices
              </button>
              <a
                href="https://github.com/povilas/xorg"
                target="_blank"
                rel="noopener noreferrer"
                className="px-8 py-4 bg-white/10 hover:bg-white/20 text-white text-lg font-bold rounded-full hover:scale-105 transition-all border border-white/20"
              >
                View on GitHub
              </a>
            </div>
          </div>
        </div>
      )}

      {/* Only show playground when NOT showing decision overlay */}
      {!showDecision && <Playground />}
    </div>
  );
}
