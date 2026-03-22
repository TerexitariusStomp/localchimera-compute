import { useRef } from 'react';
import { useFrame } from '@react-three/fiber';
import { Line, Cylinder } from '@react-three/drei';
import * as THREE from 'three';

interface DecisionBeamProps {
  start: [number, number, number];
  end: [number, number, number];
  color: string;
  active?: boolean;
}

export function DecisionBeam({ start, end, color, active = false }: DecisionBeamProps) {
  const meshRef = useRef<THREE.Mesh>(null);

  useFrame((state) => {
    if (meshRef.current && active) {
      const pulse = Math.sin(state.clock.elapsedTime * 4) * 0.5 + 0.5;
      meshRef.current.scale.y = 0.8 + pulse * 0.4;
      (meshRef.current.material as THREE.MeshStandardMaterial).emissiveIntensity = 0.5 + pulse;
    }
  });

  const direction = new THREE.Vector3(...end).sub(new THREE.Vector3(...start));
  const length = direction.length();
  const midpoint = new THREE.Vector3(...start).add(direction.multiplyScalar(0.5));

  const quaternion = new THREE.Quaternion();
  quaternion.setFromUnitVectors(
    new THREE.Vector3(0, 1, 0),
    direction.clone().normalize()
  );

  return (
    <group>
      {/* Main beam */}
      <Cylinder
        ref={meshRef}
        args={[0.02, 0.02, length, 16]}
        position={midpoint.toArray()}
        quaternion={quaternion}
      >
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={active ? 1 : 0.5}
          transparent
          opacity={active ? 0.8 : 0.4}
        />
      </Cylinder>

      {/* Glowing line for emphasis */}
      <Line
        points={[start, end]}
        color={color}
        lineWidth={active ? 3 : 1.5}
        transparent
        opacity={active ? 0.6 : 0.3}
      />
    </group>
  );
}
