import { useMemo } from 'react';
import { Line } from '@react-three/drei';
import * as THREE from 'three';
import type { HistoryEntry } from '../../simulation';

interface HistoryTrailProps {
  history: HistoryEntry[];
  visible: boolean;
}

export function HistoryTrail({ history, visible }: HistoryTrailProps) {
  const points = useMemo(() => {
    return history.map((_, index) => {
      const t = index / Math.max(history.length - 1, 1);
      return new THREE.Vector3(
        Math.cos(t * Math.PI * 4) * 2,
        Math.sin(t * Math.PI * 4) * 2,
        -t * 5
      );
    });
  }, [history]);

  if (!visible || points.length < 2) return null;

  return (
    <Line
      points={points}
      color="#64748b"
      lineWidth={2}
      transparent
      opacity={0.6}
    />
  );
}
