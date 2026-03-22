import { useRef } from 'react';
import { useFrame } from '@react-three/fiber';
import { Sphere, Text } from '@react-three/drei';
import * as THREE from 'three';
import type { Expressor } from '../../simulation';

interface ExpressorNodeProps {
  expressor: Expressor;
  active?: boolean;
}

export function ExpressorNode({ expressor, active = false }: ExpressorNodeProps) {
  const meshRef = useRef<THREE.Mesh>(null);
  const glowRef = useRef<THREE.Mesh>(null);

  useFrame((state) => {
    if (meshRef.current) {
      meshRef.current.rotation.y = state.clock.elapsedTime * 0.3;
    }
    if (glowRef.current && active) {
      const pulse = Math.sin(state.clock.elapsedTime * 2) * 0.3 + 1;
      glowRef.current.scale.setScalar(pulse);
    }
  });

  return (
    <group position={expressor.position}>
      {/* Glow effect */}
      <Sphere ref={glowRef} args={[0.7, 32, 32]}>
        <meshBasicMaterial
          color={expressor.color}
          transparent
          opacity={active ? 0.3 : 0.15}
        />
      </Sphere>

      {/* Main node */}
      <Sphere ref={meshRef} args={[0.4, 32, 32]}>
        <meshStandardMaterial
          color={expressor.color}
          emissive={expressor.color}
          emissiveIntensity={active ? 0.8 : 0.3}
          metalness={0.8}
          roughness={0.2}
        />
      </Sphere>

      {/* Label */}
      <Text
        position={[0, -0.8, 0]}
        fontSize={0.3}
        color="white"
        anchorX="center"
        anchorY="middle"
      >
        {expressor.name}
      </Text>
    </group>
  );
}
