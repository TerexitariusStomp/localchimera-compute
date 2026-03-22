import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import * as THREE from 'three';

export function EnhancedParticles() {
  const pointsRef = useRef<THREE.Points>(null);

  const particlesCount = 2000;
  const { positions, sizes, colors } = useMemo(() => {
    const positions = new Float32Array(particlesCount * 3);
    const sizes = new Float32Array(particlesCount);
    const colors = new Float32Array(particlesCount * 3);

    const colorPalette = [
      new THREE.Color('#00d9ff'),
      new THREE.Color('#a855f7'),
      new THREE.Color('#ff6b35'),
      new THREE.Color('#10b981'),
    ];

    for (let i = 0; i < particlesCount; i++) {
      // Spherical distribution
      const radius = 15 + Math.random() * 10;
      const theta = Math.random() * Math.PI * 2;
      const phi = Math.acos(2 * Math.random() - 1);

      positions[i * 3] = radius * Math.sin(phi) * Math.cos(theta);
      positions[i * 3 + 1] = radius * Math.sin(phi) * Math.sin(theta);
      positions[i * 3 + 2] = radius * Math.cos(phi);

      sizes[i] = Math.random() * 0.15 + 0.05;

      const color = colorPalette[Math.floor(Math.random() * colorPalette.length)];
      colors[i * 3] = color.r;
      colors[i * 3 + 1] = color.g;
      colors[i * 3 + 2] = color.b;
    }

    return { positions, sizes, colors };
  }, []);

  useFrame((state) => {
    if (pointsRef.current) {
      pointsRef.current.rotation.y = state.clock.elapsedTime * 0.03;
      pointsRef.current.rotation.x = Math.sin(state.clock.elapsedTime * 0.02) * 0.1;
    }
  });

  return (
    <points ref={pointsRef}>
      <bufferGeometry>
        <bufferAttribute
          attach="attributes-position"
          count={particlesCount}
          array={positions}
          itemSize={3}
          args={[positions, 3]}
        />
        <bufferAttribute
          attach="attributes-size"
          count={particlesCount}
          array={sizes}
          itemSize={1}
          args={[sizes, 1]}
        />
        <bufferAttribute
          attach="attributes-color"
          count={particlesCount}
          array={colors}
          itemSize={3}
          args={[colors, 3]}
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
  );
}
