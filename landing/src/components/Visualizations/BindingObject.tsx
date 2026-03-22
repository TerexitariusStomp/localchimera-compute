import { useRef } from 'react';
import { useFrame } from '@react-three/fiber';
import { Box, Text } from '@react-three/drei';
import * as THREE from 'three';
import type { Binding } from '../../simulation';

interface BindingObjectProps {
  binding: Binding;
  position: [number, number, number];
}

export function BindingObject({ binding, position }: BindingObjectProps) {
  const meshRef = useRef<THREE.Mesh>(null);

  useFrame((state) => {
    if (meshRef.current) {
      const time = state.clock.elapsedTime;
      const orbit = 1.5;
      meshRef.current.position.x = position[0] + Math.cos(time + position[0]) * orbit;
      meshRef.current.position.y = position[1] + Math.sin(time + position[1]) * orbit;
      meshRef.current.rotation.x = time * 0.5;
      meshRef.current.rotation.y = time * 0.3;
    }
  });

  const displayValue = typeof binding.value === 'string'
    ? `"${binding.value.slice(0, 20)}"`
    : String(binding.value);

  return (
    <group>
      <Box ref={meshRef} args={[0.3, 0.3, 0.3]} position={position}>
        <meshStandardMaterial
          color="#10b981"
          emissive="#10b981"
          emissiveIntensity={0.4}
          metalness={0.6}
          roughness={0.3}
        />
      </Box>

      <Text
        position={[position[0], position[1] + 0.5, position[2]]}
        fontSize={0.2}
        color="#94a3b8"
        anchorX="center"
        anchorY="middle"
      >
        {`${binding.name}: ${displayValue}`}
      </Text>
    </group>
  );
}
