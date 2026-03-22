import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import { Sphere, Trail } from '@react-three/drei';
import * as THREE from 'three';

interface MemberNodeProps {
  name: string;
  color: string;
  orbitRadius: number;
  orbitSpeed: number;
  height: number;
  active: boolean;
}

// Custom shader for energy core
const energyCoreShader = {
  vertexShader: `
    varying vec2 vUv;
    varying vec3 vNormal;
    varying vec3 vPosition;

    void main() {
      vUv = uv;
      vNormal = normalize(normalMatrix * normal);
      vPosition = position;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `,
  fragmentShader: `
    uniform float time;
    uniform vec3 color;
    varying vec2 vUv;
    varying vec3 vNormal;
    varying vec3 vPosition;

    // Noise function
    float noise(vec3 p) {
      return fract(sin(dot(p, vec3(12.9898, 78.233, 45.543))) * 43758.5453);
    }

    void main() {
      // Swirling pattern
      float pattern = sin(vPosition.x * 10.0 + time) *
                     cos(vPosition.y * 10.0 + time) *
                     sin(vPosition.z * 10.0 + time);

      // Noise overlay
      float n = noise(vPosition * 5.0 + vec3(time * 0.5));

      // Combine
      float intensity = (pattern + n) * 0.5 + 0.5;

      // Edge glow (Fresnel)
      float fresnel = pow(1.0 - dot(vNormal, vec3(0.0, 0.0, 1.0)), 3.0);

      vec3 finalColor = color * intensity + color * fresnel * 0.5;
      float alpha = intensity * 0.8 + fresnel * 0.2;

      gl_FragColor = vec4(finalColor, alpha);
    }
  `
};

export function MemberNode({ color, orbitRadius, orbitSpeed, height, active }: MemberNodeProps) {
  const groupRef = useRef<THREE.Group>(null);
  const coreRef = useRef<THREE.Mesh>(null);
  const outerRingRef = useRef<THREE.Mesh>(null);
  const timeRef = useRef(0);

  const shaderMaterial = useMemo(() => {
    return new THREE.ShaderMaterial({
      uniforms: {
        time: { value: 0 },
        color: { value: new THREE.Color(color) }
      },
      vertexShader: energyCoreShader.vertexShader,
      fragmentShader: energyCoreShader.fragmentShader,
      transparent: true,
      blending: THREE.AdditiveBlending,
    });
  }, [color]);


  useFrame((state) => {
    if (!groupRef.current) return;

    timeRef.current = state.clock.elapsedTime;

    // Orbital motion
    const angle = timeRef.current * orbitSpeed;
    groupRef.current.position.x = Math.cos(angle) * orbitRadius;
    groupRef.current.position.z = Math.sin(angle) * orbitRadius;
    groupRef.current.position.y = height + Math.sin(timeRef.current * 2) * 0.2;

    // Core pulsing
    if (coreRef.current) {
      const pulse = active ? Math.sin(timeRef.current * 4) * 0.3 + 1.2 : 1;
      coreRef.current.scale.setScalar(pulse);
    }

    // Outer ring rotation
    if (outerRingRef.current) {
      outerRingRef.current.rotation.y = timeRef.current * (active ? 2 : 0.5);
      outerRingRef.current.rotation.x = Math.sin(timeRef.current * 0.5) * 0.3;
    }

    // Update shader time
    if (shaderMaterial) {
      shaderMaterial.uniforms.time.value = timeRef.current;
    }
  });

  return (
    <group ref={groupRef}>
      {/* Particle trail */}
      <Trail
        width={0.3}
        length={8}
        color={new THREE.Color(color)}
        attenuation={(t) => t * t}
      >
        <group>
          {/* Inner energy core with custom shader */}
          <mesh ref={coreRef}>
            <sphereGeometry args={[0.3, 32, 32]} />
            <primitive object={shaderMaterial} attach="material" />
          </mesh>

          {/* Middle membrane layer */}
          <Sphere args={[0.45, 32, 32]}>
            <meshPhysicalMaterial
              color={color}
              transparent
              opacity={0.3}
              transmission={0.9}
              thickness={0.5}
              roughness={0}
              metalness={0.1}
              clearcoat={1}
              clearcoatRoughness={0}
            />
          </Sphere>

          {/* Outer geometric ring */}
          <mesh ref={outerRingRef}>
            <torusGeometry args={[0.6, 0.05, 16, 100]} />
            <meshStandardMaterial
              color={color}
              emissive={color}
              emissiveIntensity={active ? 1.5 : 0.5}
              metalness={0.8}
              roughness={0.2}
            />
          </mesh>

          {/* Additional decorative rings */}
          <mesh rotation={[Math.PI / 2, 0, 0]}>
            <torusGeometry args={[0.7, 0.03, 16, 100]} />
            <meshStandardMaterial
              color={color}
              emissive={color}
              emissiveIntensity={active ? 1 : 0.3}
              metalness={0.9}
              roughness={0.1}
            />
          </mesh>

          {/* Glow sphere */}
          <Sphere args={[0.8, 16, 16]}>
            <meshBasicMaterial
              color={color}
              transparent
              opacity={active ? 0.2 : 0.1}
            />
          </Sphere>
        </group>
      </Trail>
    </group>
  );
}
