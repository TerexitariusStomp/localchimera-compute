import { useRef, useEffect } from 'react';
import { useFrame } from '@react-three/fiber';
import * as THREE from 'three';

interface EnergyBeamProps {
  active: boolean;
  color: string;
  onComplete?: () => void;
}

export function EnergyBeam({ active, color, onComplete }: EnergyBeamProps) {
  const meshRef = useRef<THREE.Mesh>(null);
  const timeRef = useRef(0);
  const durationRef = useRef(1.5); // 1.5 seconds duration

  useEffect(() => {
    if (active) {
      timeRef.current = 0;
    }
  }, [active]);

  useFrame((_state, delta) => {
    if (!active || !meshRef.current) return;

    timeRef.current += delta;

    // Animate scale and opacity
    const progress = Math.min(timeRef.current / durationRef.current, 1);

    // Beam grows upward, then fades
    if (progress < 0.5) {
      const scaleProgress = progress * 2;
      meshRef.current.scale.y = scaleProgress;
      meshRef.current.position.y = 5 * scaleProgress;
      (meshRef.current.material as THREE.MeshBasicMaterial).opacity = scaleProgress;
    } else {
      const fadeProgress = (progress - 0.5) * 2;
      (meshRef.current.material as THREE.MeshBasicMaterial).opacity = 1 - fadeProgress;
    }

    // Complete when done
    if (progress >= 1 && onComplete) {
      onComplete();
    }
  });

  if (!active) return null;

  return (
    <mesh ref={meshRef} position={[0, 0, 0]}>
      <cylinderGeometry args={[0.1, 0.1, 10, 16]} />
      <meshBasicMaterial
        color={color}
        transparent
        opacity={0}
        blending={THREE.AdditiveBlending}
        depthWrite={false}
      />
    </mesh>
  );
}
