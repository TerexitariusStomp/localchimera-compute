import { Canvas } from '@react-three/fiber';
import { OrbitControls, PerspectiveCamera } from '@react-three/drei';
import { useJourneyStore } from '../../store/journeyStore';
import {
  ExpressorNode,
  BindingObject,
  ValidatorField,
  HistoryTrail,
  ParticleSystem
} from '../Visualizations';

export function Scene() {
  const { simState, currentDecision } = useJourneyStore();

  const expressors = Array.from(simState.expressors.values());
  const bindings = Array.from(simState.bindings.values());

  const showValidator = currentDecision >= 2 && simState.validator !== null;
  const showHistory = currentDecision >= 5;
  const strictValidator = currentDecision === 3;

  return (
    <Canvas className="w-full h-full">
      <PerspectiveCamera makeDefault position={[0, 0, 10]} />
      <OrbitControls
        enableZoom={true}
        enablePan={false}
        maxDistance={20}
        minDistance={5}
        autoRotate={currentDecision === 0}
        autoRotateSpeed={0.5}
      />

      <ambientLight intensity={0.3} />
      <pointLight position={[10, 10, 10]} intensity={1} />
      <pointLight position={[-10, -10, -10]} intensity={0.5} color="#a855f7" />

      <ParticleSystem />

      {expressors.map((expressor) => (
        <ExpressorNode
          key={expressor.id}
          expressor={expressor}
          active={expressor.id === simState.currentExpressor}
        />
      ))}

      {bindings.map((binding, index) => (
        <BindingObject
          key={`${binding.name}-${binding.version}`}
          binding={binding}
          position={[
            Math.cos(index * Math.PI * 0.5) * 2,
            Math.sin(index * Math.PI * 0.5) * 2,
            0
          ]}
        />
      ))}

      <ValidatorField active={showValidator} strict={strictValidator} />
      <HistoryTrail history={simState.history} visible={showHistory} />
    </Canvas>
  );
}
