import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import * as THREE from 'three';

export function StarField() {
  const pointsRef = useRef<THREE.Points>(null);

  const { positions, colors, sizes } = useMemo(() => {
    const count = 5000;
    const positions = new Float32Array(count * 3);
    const colors = new Float32Array(count * 3);
    const sizes = new Float32Array(count);

    for (let i = 0; i < count; i++) {
      // Spherical distribution
      const radius = 50 + Math.random() * 50;
      const theta = Math.random() * Math.PI * 2;
      const phi = Math.acos(2 * Math.random() - 1);

      positions[i * 3] = radius * Math.sin(phi) * Math.cos(theta);
      positions[i * 3 + 1] = radius * Math.sin(phi) * Math.sin(theta);
      positions[i * 3 + 2] = radius * Math.cos(phi);

      // Color variation - blues, purples, whites
      const colorChoice = Math.random();
      if (colorChoice < 0.3) {
        colors[i * 3] = 1;
        colors[i * 3 + 1] = 1;
        colors[i * 3 + 2] = 1;
      } else if (colorChoice < 0.6) {
        colors[i * 3] = 0.5;
        colors[i * 3 + 1] = 0.7;
        colors[i * 3 + 2] = 1;
      } else {
        colors[i * 3] = 0.7;
        colors[i * 3 + 1] = 0.5;
        colors[i * 3 + 2] = 1;
      }

      sizes[i] = Math.random() * 0.2 + 0.05;
    }

    return { positions, colors, sizes };
  }, []);

  useFrame((state) => {
    if (pointsRef.current) {
      pointsRef.current.rotation.y = state.clock.elapsedTime * 0.01;
    }
  });

  return (
    <points ref={pointsRef}>
      <bufferGeometry>
        <bufferAttribute
          attach="attributes-position"
          count={5000}
          array={positions}
          itemSize={3}
          args={[positions, 3]}
        />
        <bufferAttribute
          attach="attributes-color"
          count={5000}
          array={colors}
          itemSize={3}
          args={[colors, 3]}
        />
        <bufferAttribute
          attach="attributes-size"
          count={5000}
          array={sizes}
          itemSize={1}
          args={[sizes, 1]}
        />
      </bufferGeometry>
      <pointsMaterial
        size={0.1}
        vertexColors
        transparent
        opacity={0.8}
        sizeAttenuation
        blending={THREE.AdditiveBlending}
        depthWrite={false}
      />
    </points>
  );
}
