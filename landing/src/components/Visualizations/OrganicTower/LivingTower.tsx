import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import * as THREE from 'three';
import { TowerSegment } from './TowerGeometry';

interface Floor {
  num: number;
  name: string;
  color: string;
  yPosition: number;
}

interface LivingTowerProps {
  floors: Floor[];
  activeFloor?: number;
  scale?: number;
}

export function LivingTower({ floors, activeFloor, scale = 1 }: LivingTowerProps) {
  const groupRef = useRef<THREE.Group>(null);
  const breathingRef = useRef(0);

  // Create particle system for energy flow
  const particles = useMemo(() => {
    const count = 2000;
    const positions = new Float32Array(count * 3);
    const colors = new Float32Array(count * 3);
    const sizes = new Float32Array(count);

    for (let i = 0; i < count; i++) {
      // Distribute particles in cylindrical volume around tower
      const angle = Math.random() * Math.PI * 2;
      const radius = 2 + Math.random() * 3;
      const height = (Math.random() - 0.5) * 20;

      positions[i * 3] = Math.cos(angle) * radius;
      positions[i * 3 + 1] = height;
      positions[i * 3 + 2] = Math.sin(angle) * radius;

      // Color variation
      const colorChoice = Math.floor(Math.random() * 3);
      if (colorChoice === 0) {
        colors[i * 3] = 0;
        colors[i * 3 + 1] = 0.85;
        colors[i * 3 + 2] = 1;
      } else if (colorChoice === 1) {
        colors[i * 3] = 0.66;
        colors[i * 3 + 1] = 0.33;
        colors[i * 3 + 2] = 0.93;
      } else {
        colors[i * 3] = 1;
        colors[i * 3 + 1] = 0.42;
        colors[i * 3 + 2] = 0.21;
      }

      sizes[i] = Math.random() * 0.1 + 0.05;
    }

    return { positions, colors, sizes, count };
  }, []);

  useFrame((state) => {
    if (!groupRef.current) return;

    // Breathing animation
    breathingRef.current = Math.sin(state.clock.elapsedTime * 0.5) * 0.05 + 1;
    groupRef.current.scale.set(
      scale * breathingRef.current,
      scale,
      scale * breathingRef.current
    );

    // Gentle rotation
    groupRef.current.rotation.y = Math.sin(state.clock.elapsedTime * 0.1) * 0.2;

    // Animate particles (energy flow upward)
    const positions = particles.positions;
    for (let i = 0; i < particles.count; i++) {
      positions[i * 3 + 1] += 0.02; // Move up

      // Reset if too high
      if (positions[i * 3 + 1] > 10) {
        positions[i * 3 + 1] = -10;
      }
    }
  });

  return (
    <group ref={groupRef}>
      {/* Particle energy system */}
      <points>
        <bufferGeometry>
          <bufferAttribute
            attach="attributes-position"
            count={particles.count}
            array={particles.positions}
            itemSize={3}
            args={[particles.positions, 3]}
          />
          <bufferAttribute
            attach="attributes-color"
            count={particles.count}
            array={particles.colors}
            itemSize={3}
            args={[particles.colors, 3]}
          />
          <bufferAttribute
            attach="attributes-size"
            count={particles.count}
            array={particles.sizes}
            itemSize={1}
            args={[particles.sizes, 1]}
          />
        </bufferGeometry>
        <pointsMaterial
          size={0.08}
          vertexColors
          transparent
          opacity={0.7}
          sizeAttenuation
          blending={THREE.AdditiveBlending}
          depthWrite={false}
        />
      </points>

      {/* Tower segments */}
      {floors.map((floor) => (
        <TowerSegment
          key={floor.num}
          floorNumber={floor.num}
          height={2}
          radius={1.5}
          color={floor.color}
          position={[0, floor.yPosition, 0]}
          active={activeFloor === floor.num}
        />
      ))}

      {/* Central core light */}
      <pointLight
        position={[0, 0, 0]}
        intensity={2}
        distance={20}
        decay={2}
        color="#00d9ff"
      />
      <pointLight
        position={[0, 10, 0]}
        intensity={1.5}
        distance={15}
        decay={2}
        color="#a855f7"
      />
    </group>
  );
}
