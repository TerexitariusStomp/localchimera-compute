import { create } from 'zustand';
import type { Environment } from '../simulation';
import { makeInitialEnv } from '../simulation';

export interface JourneyState {
  currentDecision: number;
  pathTaken: string[];
  simState: Environment;
  playgroundOpen: boolean;
  scrollProgress: number;

  // Actions
  makeChoice: (choice: string) => void;
  updateSimState: (newState: Environment) => void;
  togglePlayground: () => void;
  setScrollProgress: (progress: number) => void;
  reset: () => void;
}

export const useJourneyStore = create<JourneyState>((set) => ({
  currentDecision: 0,
  pathTaken: [],
  simState: makeInitialEnv({ x: 0, y: 1 }),
  playgroundOpen: false,
  scrollProgress: 0,

  makeChoice: (choice: string) =>
    set((state) => ({
      pathTaken: [...state.pathTaken, choice],
      currentDecision: state.currentDecision + 1,
    })),

  updateSimState: (newState: Environment) =>
    set({ simState: newState }),

  togglePlayground: () =>
    set((state) => ({ playgroundOpen: !state.playgroundOpen })),

  setScrollProgress: (progress: number) =>
    set({ scrollProgress: progress }),

  reset: () =>
    set({
      currentDecision: 0,
      pathTaken: [],
      simState: makeInitialEnv({ x: 0, y: 1 }),
      playgroundOpen: false,
      scrollProgress: 0,
    }),
}));
