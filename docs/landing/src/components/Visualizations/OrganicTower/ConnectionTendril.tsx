import { useRef, useMemo } from 'react';
import { useFrame } from '@react-three/fiber';
import * as THREE from 'three';

interface ConnectionTendrilProps {
  startPos: THREE.Vector3;
  endPos: THREE.Vector3;
  color: string;
  active: boolean;
  animated?: boolean;
}

export function ConnectionTendril({ startPos, endPos, color, active, animated = true }: ConnectionTendrilProps) {
  const meshRef = useRef<THREE.Mesh>(null);
  const timeRef = useRef(0);

  // Create organic curved path with sub-branches
  const { curve, subCurves } = useMemo(() => {
    // Main curve with organic bezier
    const midPoint = new THREE.Vector3()
      .lerpVectors(startPos, endPos, 0.5)
      .add(new THREE.Vector3(
        (Math.random() - 0.5) * 2,
        (Math.random() - 0.5) * 1,
        (Math.random() - 0.5) * 2
      ));

    const controlPoint1 = new THREE.Vector3()
      .lerpVectors(startPos, midPoint, 0.5)
      .add(new THREE.Vector3(
        (Math.random() - 0.5) * 1,
        Math.random() * 0.5,
        (Math.random() - 0.5) * 1
      ));

    const controlPoint2 = new THREE.Vector3()
      .lerpVectors(midPoint, endPos, 0.5)
      .add(new THREE.Vector3(
        (Math.random() - 0.5) * 1,
        Math.random() * 0.5,
        (Math.random() - 0.5) * 1
      ));

    const mainCurve = new THREE.CubicBezierCurve3(
      startPos,
      controlPoint1,
      controlPoint2,
      endPos
    );

    // Create sub-branches
    const branches: THREE.Curve<THREE.Vector3>[] = [];
    const branchCount = 5;

    for (let i = 0; i < branchCount; i++) {
      const t = (i + 1) / (branchCount + 1);
      const branchStart = mainCurve.getPoint(t);
      const branchEnd = branchStart.clone().add(
        new THREE.Vector3(
          (Math.random() - 0.5) * 0.8,
          (Math.random() - 0.5) * 0.5,
          (Math.random() - 0.5) * 0.8
        )
      );

      const branchControl = branchStart.clone().lerp(branchEnd, 0.5).add(
        new THREE.Vector3(
          (Math.random() - 0.5) * 0.3,
          Math.random() * 0.3,
          (Math.random() - 0.5) * 0.3
        )
      );

      branches.push(new THREE.QuadraticBezierCurve3(
        branchStart,
        branchControl,
        branchEnd
      ));
    }

    return { curve: mainCurve, subCurves: branches };
  }, [startPos, endPos]);

  const mainTube = useMemo(() => {
    return new THREE.TubeGeometry(curve, 64, 0.05, 8, false);
  }, [curve]);

  const subTubes = useMemo(() => {
    return subCurves.map(subCurve =>
      new THREE.TubeGeometry(subCurve, 32, 0.02, 6, false)
    );
  }, [subCurves]);

  useFrame((state) => {
    timeRef.current = state.clock.elapsedTime;

    if (meshRef.current && animated) {
      // Pulsing effect
      const pulse = active
        ? Math.sin(timeRef.current * 3) * 0.3 + 1
        : Math.sin(timeRef.current * 0.5) * 0.1 + 1;

      meshRef.current.scale.setScalar(pulse);
    }
  });

  return (
    <group ref={meshRef}>
      {/* Main tendril */}
      <mesh geometry={mainTube}>
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={active ? 1.2 : 0.4}
          transparent
          opacity={active ? 0.9 : 0.5}
          metalness={0.8}
          roughness={0.2}
        />
      </mesh>

      {/* Sub-branches */}
      {subTubes.map((tube, i) => (
        <mesh key={i} geometry={tube}>
          <meshStandardMaterial
            color={color}
            emissive={color}
            emissiveIntensity={active ? 0.8 : 0.2}
            transparent
            opacity={active ? 0.7 : 0.3}
            metalness={0.7}
            roughness={0.3}
          />
        </mesh>
      ))}

      {/* Energy flow particles along main path */}
      {animated && active && (
        <mesh>
          <sphereGeometry args={[0.08, 16, 16]} />
          <meshBasicMaterial color={color} />
        </mesh>
      )}
    </group>
  );
}
