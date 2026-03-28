import { Suspense } from 'react';
import { Canvas } from '@react-three/fiber';
import { OrbitControls, PerspectiveCamera, Environment, Stars, Text } from '@react-three/drei';
import { useJourneyStore } from '../../store/journeyStore';
import { TowerFloor, Member, EnhancedParticles } from '../Visualizations';

function SceneContent() {
  const { currentDecision, simState } = useJourneyStore();

  // Define floors with personality
  const floors = [
    { num: 3, name: 'Events & Social', color: '#ff6b35', y: -2 },
    { num: 4, name: 'Quiet Study', color: '#10b981', y: -1 },
    { num: 7, name: 'Robotics Lab', color: '#00d9ff', y: 0 },
    { num: 9, name: 'Independent', color: '#f59e0b', y: 1 },
    { num: 12, name: 'Garden Advocates', color: '#a855f7', y: 2 },
  ];

  // Get dynamic members from simState
  const members = Array.from(simState.expressors.values())
    .filter(e => e.id !== 'genesis')
    .map((e) => ({
      name: e.name,
      color: e.color,
      position: e.position
    }));

  // Show specific elements based on decision
  const showMembers = members.length > 0;
  const showAllFloors = currentDecision >= 2;

  // Get budget to scale tower
  const budget = simState.bindings.get('budget')?.value || 50000;
  const budgetScale = Math.max(0.8, Math.min(1.5, budget / 50000));

  // Check if amenities are reduced
  const amenitiesReduced = simState.bindings.get('amenities')?.value === 'reduced';

  return (
    <>
      <PerspectiveCamera makeDefault position={[0, 0, 12]} fov={60} />
      <OrbitControls
        enableZoom={true}
        enablePan={false}
        maxDistance={25}
        minDistance={6}
        maxPolarAngle={Math.PI / 1.8}
        minPolarAngle={Math.PI / 4}
        autoRotate={currentDecision === 0 && members.length === 0}
        autoRotateSpeed={0.3}
      />

      {/* Lighting setup - adjust based on budget */}
      <ambientLight intensity={amenitiesReduced ? 0.2 : 0.3} />
      <pointLight
        position={[0, 8, 0]}
        intensity={amenitiesReduced ? 1 : 2}
        color="#00d9ff"
        distance={20}
        decay={2}
      />
      <pointLight position={[-8, 0, 4]} intensity={1.5} color="#a855f7" distance={15} decay={2} />
      <pointLight position={[8, 0, -4]} intensity={1.5} color="#ff6b35" distance={15} decay={2} />

      {/* Environment */}
      <Environment preset="city" />
      <fog attach="fog" args={['#0a0a0f', 10, 35]} />
      <Stars radius={100} depth={50} count={3000} factor={4} saturation={0} fade speed={0.5} />

      {/* Enhanced particles */}
      <EnhancedParticles />

      {/* Central label showing what's happening */}
      {currentDecision === 0 && members.length === 0 && (
        <Text
          position={[0, 3, 0]}
          fontSize={0.4}
          color="#00d9ff"
          anchorX="center"
          anchorY="middle"
          maxWidth={5}
        >
          Frontier Tower
        </Text>
      )}

      {/* Tower floors - scale based on budget */}
      {floors.slice(0, showAllFloors ? 5 : 2).map((floor, idx) => (
        <TowerFloor
          key={floor.num}
          floorNumber={floor.num}
          name={floor.name}
          color={amenitiesReduced && floor.num === 12 ? '#666666' : floor.color}
          position={[0, floor.y * 1.5, 0]}
          active={currentDecision === idx + 1}
          scale={budgetScale}
        />
      ))}

      {/* Members - position them around the tower */}
      {showMembers && members.map((member, idx) => (
        <Member
          key={member.name}
          name={member.name}
          color={member.color}
          position={member.position}
          active={idx === 0}
          showTrail={currentDecision >= 4}
        />
      ))}

      {/* Show budget indicator */}
      {budget && (
        <Text
          position={[0, -4, 0]}
          fontSize={0.3}
          color={budget > 50000 ? '#10b981' : budget < 30000 ? '#ff6b35' : '#00d9ff'}
          anchorX="center"
          anchorY="middle"
        >
          ${(budget / 1000).toFixed(0)}k Budget
        </Text>
      )}
    </>
  );
}

export function TowerScene() {
  return (
    <div className="w-full h-full">
      <Canvas
        className="w-full h-full"
        gl={{
          antialias: true,
        }}
      >
        <Suspense fallback={null}>
          <SceneContent />
        </Suspense>
      </Canvas>
    </div>
  );
}
