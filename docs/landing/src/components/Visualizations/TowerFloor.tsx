import { useRef } from 'react';
import { useFrame } from '@react-three/fiber';
import { Box, Text, RoundedBox } from '@react-three/drei';
import * as THREE from 'three';

interface TowerFloorProps {
  floorNumber: number;
  name: string;
  color: string;
  position: [number, number, number];
  active?: boolean;
  scale?: number;
}

export function TowerFloor({ floorNumber, name, color, position, active = false, scale = 1 }: TowerFloorProps) {
  const meshRef = useRef<THREE.Mesh>(null);
  const glowRef = useRef<THREE.Mesh>(null);

  useFrame((state) => {
    if (meshRef.current && active) {
      meshRef.current.rotation.y = Math.sin(state.clock.elapsedTime * 0.5) * 0.1;
    }
    if (glowRef.current && active) {
      const pulse = Math.sin(state.clock.elapsedTime * 2) * 0.2 + 1;
      glowRef.current.scale.setScalar(pulse);
      const material = glowRef.current.material as THREE.MeshBasicMaterial;
      if (material) {
        material.opacity = (Math.sin(state.clock.elapsedTime * 2) * 0.2 + 0.4);
      }
    }
  });

  return (
    <group position={position}>
      {/* Glow layer */}
      <RoundedBox ref={glowRef} args={[2.2 * scale, 0.4, 2.2 * scale]} radius={0.05} smoothness={4}>
        <meshBasicMaterial
          color={color}
          transparent
          opacity={active ? 0.4 : 0.2}
          side={THREE.DoubleSide}
        />
      </RoundedBox>

      {/* Main floor */}
      <RoundedBox ref={meshRef} args={[2 * scale, 0.3, 2 * scale]} radius={0.05} smoothness={4}>
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={active ? 0.6 : 0.3}
          metalness={0.9}
          roughness={0.1}
          envMapIntensity={1.5}
        />
      </RoundedBox>

      {/* Glass panels on sides */}
      <Box args={[2 * scale, 0.35, 0.05]} position={[0, 0, 1 * scale]}>
        <meshPhysicalMaterial
          color="#88ccff"
          transparent
          opacity={0.3}
          metalness={0.1}
          roughness={0}
          transmission={0.9}
          thickness={0.5}
        />
      </Box>

      {/* Floor number */}
      <Text
        position={[0, 0.25, 0]}
        fontSize={0.25}
        color="white"
        anchorX="center"
        anchorY="middle"
        outlineWidth={0.01}
        outlineColor="#000000"
      >
        Floor {floorNumber}
      </Text>

      {/* Floor name */}
      <Text
        position={[0, -0.3, 1.1 * scale]}
        fontSize={0.15}
        color="#a0a0a0"
        anchorX="center"
        anchorY="middle"
        maxWidth={1.8 * scale}
      >
        {name}
      </Text>
    </group>
  );
}
