import { useRef } from 'react';
import { useFrame } from '@react-three/fiber';
import * as THREE from 'three';

interface ValidatorFieldProps {
  active: boolean;
  strict?: boolean;
}

export function ValidatorField({ active, strict = false }: ValidatorFieldProps) {
  const meshRef = useRef<THREE.Mesh>(null);

  useFrame((state) => {
    if (meshRef.current && active) {
      meshRef.current.rotation.y = state.clock.elapsedTime * 0.2;
      meshRef.current.rotation.x = Math.sin(state.clock.elapsedTime * 0.3) * 0.2;
    }
  });

  if (!active) return null;

  return (
    <mesh ref={meshRef}>
      <torusGeometry args={[5, strict ? 0.3 : 0.15, 16, 100]} />
      <meshStandardMaterial
        color="#a855f7"
        emissive="#a855f7"
        emissiveIntensity={strict ? 0.8 : 0.4}
        transparent
        opacity={strict ? 0.6 : 0.3}
        metalness={0.8}
        roughness={0.2}
      />
    </mesh>
  );
}
