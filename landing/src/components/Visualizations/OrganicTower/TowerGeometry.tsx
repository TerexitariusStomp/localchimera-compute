import { useMemo } from 'react';
import * as THREE from 'three';

interface TowerSegmentProps {
  floorNumber: number;
  height: number;
  radius: number;
  color: string;
  position: [number, number, number];
  active: boolean;
}

// Create detailed rectangular tower geometry with windows and architectural features
function createRectangularTowerSegment(width: number, depth: number, height: number): THREE.BufferGeometry {
  const geometry = new THREE.BufferGeometry();
  const vertices: number[] = [];
  const indices: number[] = [];
  const uvs: number[] = [];
  const normals: number[] = [];

  const hw = width / 2; // half width
  const hd = depth / 2; // half depth
  const hh = height / 2; // half height

  // Helper to add a quad face
  const addQuad = (v1: number[], v2: number[], v3: number[], v4: number[], normal: number[]) => {
    const startIdx = vertices.length / 3;

    vertices.push(...v1, ...v2, ...v3, ...v4);

    // Add normals for all 4 vertices
    for (let i = 0; i < 4; i++) {
      normals.push(...normal);
    }

    // UVs
    uvs.push(0, 0, 1, 0, 1, 1, 0, 1);

    // Two triangles
    indices.push(
      startIdx, startIdx + 1, startIdx + 2,
      startIdx, startIdx + 2, startIdx + 3
    );
  };

  // Front face (+Z)
  addQuad(
    [-hw, -hh, hd], [hw, -hh, hd], [hw, hh, hd], [-hw, hh, hd],
    [0, 0, 1]
  );

  // Back face (-Z)
  addQuad(
    [hw, -hh, -hd], [-hw, -hh, -hd], [-hw, hh, -hd], [hw, hh, -hd],
    [0, 0, -1]
  );

  // Right face (+X)
  addQuad(
    [hw, -hh, hd], [hw, -hh, -hd], [hw, hh, -hd], [hw, hh, hd],
    [1, 0, 0]
  );

  // Left face (-X)
  addQuad(
    [-hw, -hh, -hd], [-hw, -hh, hd], [-hw, hh, hd], [-hw, hh, -hd],
    [-1, 0, 0]
  );

  // Top face
  addQuad(
    [-hw, hh, hd], [hw, hh, hd], [hw, hh, -hd], [-hw, hh, -hd],
    [0, 1, 0]
  );

  // Bottom face
  addQuad(
    [-hw, -hh, -hd], [hw, -hh, -hd], [hw, -hh, hd], [-hw, -hh, hd],
    [0, -1, 0]
  );

  geometry.setAttribute('position', new THREE.Float32BufferAttribute(vertices, 3));
  geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
  geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
  geometry.setIndex(indices);

  return geometry;
}

// Create window geometry for a single window
function createWindow(width: number, height: number, depth: number): THREE.BufferGeometry {
  const geometry = new THREE.BoxGeometry(width, height, depth);
  return geometry;
}

// Create decorative architectural elements
function createCornerColumn(width: number, height: number): THREE.BufferGeometry {
  const geometry = new THREE.BoxGeometry(width, height, width);
  return geometry;
}

// Create balcony geometry
function createBalcony(width: number, depth: number): THREE.BufferGeometry {
  const geometry = new THREE.BoxGeometry(width, 0.05, depth);
  return geometry;
}

export function TowerSegment({ height, radius, color, position, active }: TowerSegmentProps) {
  const width = radius * 2.2;
  const depth = radius * 2.2;

  const mainGeometry = useMemo(() => createRectangularTowerSegment(width, depth, height), [width, depth, height]);

  const windowGeometry = useMemo(() => createWindow(0.3, 0.4, 0.05), []);
  const cornerColumnGeometry = useMemo(() => createCornerColumn(0.15, height + 0.1), [height]);
  const balconyGeometry = useMemo(() => createBalcony(width * 0.4, 0.3), [width]);

  // Calculate window positions - 4x4 grid per face
  const windowsPerRow = 4;
  const windowsPerColumn = 3;
  const windowSpacingX = (width * 0.8) / (windowsPerRow - 1);
  const windowSpacingY = (height * 0.7) / (windowsPerColumn - 1);
  const startX = -width * 0.35;
  const startY = -height * 0.3;

  const windows: { position: [number, number, number]; rotation?: [number, number, number] }[] = [];

  // Generate window positions for all 4 faces
  for (let row = 0; row < windowsPerColumn; row++) {
    for (let col = 0; col < windowsPerRow; col++) {
      const x = startX + col * windowSpacingX;
      const y = startY + row * windowSpacingY;

      // Front face (+Z)
      windows.push({ position: [x, y, depth / 2 + 0.02] });
      // Back face (-Z) - no rotation needed, faces opposite direction
      windows.push({ position: [x, y, -depth / 2 - 0.02] });
    }
  }

  // Side face windows (fewer)
  for (let row = 0; row < windowsPerColumn; row++) {
    for (let col = 0; col < 3; col++) {
      const z = -depth * 0.3 + col * (depth * 0.6) / 2;
      const y = startY + row * windowSpacingY;

      // Right face (+X) - rotate 90 degrees around Y axis
      windows.push({ position: [width / 2 + 0.02, y, z], rotation: [0, Math.PI / 2, 0] });
      // Left face (-X) - rotate -90 degrees around Y axis
      windows.push({ position: [-width / 2 - 0.02, y, z], rotation: [0, -Math.PI / 2, 0] });
    }
  }

  return (
    <group position={position}>
      {/* Main building body */}
      <mesh geometry={mainGeometry} castShadow receiveShadow>
        <meshStandardMaterial
          color={color}
          metalness={0.1}
          roughness={0.7}
        />
      </mesh>

      {/* Windows */}
      {windows.map((window, idx) => (
        <mesh
          key={`window-${idx}`}
          geometry={windowGeometry}
          position={window.position}
          rotation={window.rotation}
          castShadow
        >
          <meshStandardMaterial
            color={active ? '#00d9ff' : '#1a3a4a'}
            emissive={active ? '#00d9ff' : '#0a1a2a'}
            emissiveIntensity={active ? 0.8 : 0.3}
            metalness={0.9}
            roughness={0.1}
          />
        </mesh>
      ))}

      {/* Corner columns for architectural detail - moved further out to prevent z-fighting */}
      <mesh
        geometry={cornerColumnGeometry}
        position={[width / 2 + 0.12, 0, depth / 2 + 0.12]}
        castShadow
      >
        <meshStandardMaterial
          color={color}
          metalness={0.3}
          roughness={0.5}
        />
      </mesh>
      <mesh
        geometry={cornerColumnGeometry}
        position={[-width / 2 - 0.12, 0, depth / 2 + 0.12]}
        castShadow
      >
        <meshStandardMaterial
          color={color}
          metalness={0.3}
          roughness={0.5}
        />
      </mesh>
      <mesh
        geometry={cornerColumnGeometry}
        position={[width / 2 + 0.12, 0, -depth / 2 - 0.12]}
        castShadow
      >
        <meshStandardMaterial
          color={color}
          metalness={0.3}
          roughness={0.5}
        />
      </mesh>
      <mesh
        geometry={cornerColumnGeometry}
        position={[-width / 2 - 0.12, 0, -depth / 2 - 0.12]}
        castShadow
      >
        <meshStandardMaterial
          color={color}
          metalness={0.3}
          roughness={0.5}
        />
      </mesh>

      {/* Balconies on front face (every other floor gets one) */}
      {active && (
        <>
          <mesh
            geometry={balconyGeometry}
            position={[width * 0.2, height / 2 - 0.3, depth / 2 + 0.15]}
            castShadow
          >
            <meshStandardMaterial
              color={color}
              metalness={0.4}
              roughness={0.6}
            />
          </mesh>
          <mesh
            geometry={balconyGeometry}
            position={[-width * 0.2, height / 2 - 0.3, depth / 2 + 0.15]}
            castShadow
          >
            <meshStandardMaterial
              color={color}
              metalness={0.4}
              roughness={0.6}
            />
          </mesh>
        </>
      )}

      {/* Floor separator bands */}
      <mesh position={[0, height / 2, 0]}>
        <boxGeometry args={[width + 0.1, 0.08, depth + 0.1]} />
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={active ? 0.4 : 0.1}
          metalness={0.5}
          roughness={0.3}
        />
      </mesh>

      {/* Roof details for top floor */}
      {active && (
        <group position={[0, height / 2 + 0.15, 0]}>
          {/* Central antenna/spire */}
          <mesh position={[0, 0.5, 0]}>
            <cylinderGeometry args={[0.03, 0.05, 1, 8]} />
            <meshStandardMaterial
              color="#ffffff"
              metalness={0.9}
              roughness={0.1}
              emissive="#00d9ff"
              emissiveIntensity={0.5}
            />
          </mesh>

          {/* Rooftop structure */}
          <mesh position={[0, 0.1, 0]}>
            <boxGeometry args={[width * 0.3, 0.2, depth * 0.3]} />
            <meshStandardMaterial
              color={color}
              metalness={0.3}
              roughness={0.6}
            />
          </mesh>
        </group>
      )}

      {/* Entrance awning at bottom */}
      {position[1] < -3 && (
        <mesh position={[0, -height / 2 - 0.05, depth / 2 + 0.2]}>
          <boxGeometry args={[width * 0.6, 0.05, 0.4]} />
          <meshStandardMaterial
            color={color}
            metalness={0.2}
            roughness={0.7}
          />
        </mesh>
      )}

      {/* Vertical accent strips */}
      <mesh position={[0, 0, depth / 2 + 0.01]}>
        <boxGeometry args={[0.05, height, 0.02]} />
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={active ? 0.3 : 0.05}
          metalness={0.7}
          roughness={0.2}
        />
      </mesh>
      <mesh position={[0, 0, -depth / 2 - 0.01]}>
        <boxGeometry args={[0.05, height, 0.02]} />
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={active ? 0.3 : 0.05}
          metalness={0.7}
          roughness={0.2}
        />
      </mesh>
    </group>
  );
}
