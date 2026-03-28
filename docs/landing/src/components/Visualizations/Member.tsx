import { useRef } from 'react';
import { useFrame } from '@react-three/fiber';
import { Sphere, Text, Trail } from '@react-three/drei';
import * as THREE from 'three';

interface MemberProps {
  name: string;
  color: string;
  position: [number, number, number];
  active?: boolean;
  showTrail?: boolean;
}

export function Member({ name, color, position, active = false, showTrail = false }: MemberProps) {
  const meshRef = useRef<THREE.Mesh>(null);
  const groupRef = useRef<THREE.Group>(null);

  useFrame((state) => {
    if (groupRef.current) {
      // Gentle floating motion
      groupRef.current.position.y = position[1] + Math.sin(state.clock.elapsedTime + position[0]) * 0.1;
    }

    if (meshRef.current && active) {
      meshRef.current.rotation.y = state.clock.elapsedTime;
    }
  });

  const memberNode = (
    <group ref={groupRef} position={[position[0], position[1], position[2]]}>
      {/* Outer glow sphere */}
      <Sphere args={[0.35, 32, 32]}>
        <meshBasicMaterial
          color={color}
          transparent
          opacity={active ? 0.3 : 0.15}
        />
      </Sphere>

      {/* Main sphere with nice materials */}
      <Sphere ref={meshRef} args={[0.25, 32, 32]}>
        <meshPhysicalMaterial
          color={color}
          emissive={color}
          emissiveIntensity={active ? 1.2 : 0.6}
          metalness={0.9}
          roughness={0.1}
          clearcoat={1}
          clearcoatRoughness={0.1}
          envMapIntensity={2}
        />
      </Sphere>

      {/* Inner core */}
      <Sphere args={[0.15, 32, 32]}>
        <meshBasicMaterial
          color="white"
          transparent
          opacity={active ? 0.8 : 0.4}
        />
      </Sphere>

      {/* Name label */}
      <Text
        position={[0, -0.5, 0]}
        fontSize={0.18}
        color="white"
        anchorX="center"
        anchorY="middle"
        outlineWidth={0.02}
        outlineColor="#000000"
      >
        {name}
      </Text>
    </group>
  );

  if (showTrail) {
    return (
      <Trail
        width={0.5}
        length={6}
        color={new THREE.Color(color)}
        attenuation={(t) => t * t}
      >
        {memberNode}
      </Trail>
    );
  }

  return memberNode;
}
