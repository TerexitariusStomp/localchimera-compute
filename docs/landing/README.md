# playnet Landing Page - Frontier Tower Edition

An immersive, visually stunning 3D landing page that demonstrates playnet's governance capabilities through the story of Frontier Tower — a vertical village where members collectively govern their community.

## ✨ Features

### Visual Experience

- **Premium 3D Graphics**: HDR environment, bloom effects, chromatic aberration, vignette
- **Glassmorphism UI**: Modern frosted glass aesthetic with smooth animations
- **Enhanced Particles**: 2000+ colored particles with additive blending
- **Dynamic Lighting**: Multiple colored point lights with realistic falloff
- **Post-Processing**: Professional color grading and visual effects

### Interactive Journey

- **6 Governance Scenarios**: Real decisions from running a co-owned building
- **Branching Narrative**: Your choices shape how the tower evolves
- **Live Simulation**: Working playnet engine processes every decision
- **Visual Feedback**: Watch the 3D scene transform based on governance choices

### The Frontier Tower Story

1. **New Member**: Sofia wants to join Floor 7 — accept or defer?
2. **Rooftop Garden**: $50k proposal — install rules or vote case-by-case?
3. **Noise Complaint**: Floor 3 vs Floor 4 — strict enforcement or mediation?
4. **Budget Crisis**: Need $100k — proportional dues or cut amenities?
5. **Floor Exit**: Floor 9 wants out — allow fork or negotiate?
6. **Evolution**: What governance model emerges?

## 🎨 Design

### Color Palette

- Deep Space: `#0a0a0f`, `#1a1a2e`
- Electric Blue: `#00d9ff`, `#0066ff`
- Vibrant Purple: `#a855f7`, `#7c3aed`
- Warm Orange: `#ff6b35`, `#f97316`
- Emerald: `#10b981`

### Typography

- **Headings**: Inter Black (900 weight)
- **Body**: Inter Regular (400 weight)
- **Code**: JetBrains Mono

### 3D Elements

- **Tower Floors**: Rounded boxes with metallic materials, glass panels
- **Members**: Spherical nodes with clearcoat, inner glow, trailing effects
- **Decision Beams**: Connecting lines showing governance relationships
- **Particles**: Spherical distribution with color variety and motion

## 🚀 Tech Stack

- **React 18** + TypeScript
- **React Three Fiber** + Drei (3D)
- **@react-three/postprocessing** (effects)
- **Zustand** (state)
- **Framer Motion** (animations)
- **Tailwind CSS** v4
- **Vite** (bundler)

## 📦 Getting Started

```bash
# Install dependencies
npm install

# Start dev server (runs at http://localhost:5173)
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview
```

## 🏗️ Project Structure

```
src/
├── components/
│   ├── Journey/
│   │   ├── TowerJourney.tsx    # Main orchestrator
│   │   └── TowerScene.tsx      # 3D scene with lighting
│   ├── Playground/
│   │   └── Playground.tsx      # Interactive REPL
│   ├── UI/
│   │   ├── TowerOpening.tsx    # Opening scene
│   │   ├── TowerDecisionOverlay.tsx
│   │   └── TowerChoiceCard.tsx # Glassmorphism cards
│   └── Visualizations/
│       ├── TowerFloor.tsx      # Building floor
│       ├── Member.tsx          # Person/organization node
│       ├── DecisionBeam.tsx    # Connecting lines
│       └── EnhancedParticles.tsx
├── simulation/                  # playnet engine (TypeScript)
├── store/                       # Zustand state
└── scenes/
    └── frontierTowerDecisions.ts # Story decisions
```

## 🎮 Interactive Playground

After decisions 2, 4, and 6, a REPL slides in from the right. Try:

```scheme
(modify! 'budget 50000)
(defexpressor 'alice "alice-key")
(as alice (modify! 'proposal "new-idea"))
(enact! (lambda (exp name val old new) (number? val)))
```

## 🎯 Key Improvements

### vs. Original Version

**Visual Quality**

- ❌ Plain materials → ✅ Metallic, glass, clearcoat materials
- ❌ Basic lighting → ✅ Multi-colored dynamic lighting + HDR
- ❌ No effects → ✅ Bloom, chromatic aberration, vignette
- ❌ Simple particles → ✅ 2000 colored particles with additive blending

**UI/UX**

- ❌ Basic cards → ✅ Glassmorphism with gradients and hover effects
- ❌ Plain text → ✅ Gradient text, badges, animated accents
- ❌ Generic opening → ✅ Branded Frontier Tower introduction

**Narrative**

- ❌ Abstract playnet concepts → ✅ Concrete governance scenarios
- ❌ Unclear purpose → ✅ Clear: "What if a building could govern itself?"
- ❌ Technical jargon → ✅ Real-world decisions anyone can understand

## 🌟 About Frontier Tower

Frontier Tower is a 16-floor vertical village in San Francisco housing founders and builders working on frontier technologies. This landing page imagines how playnet could power its governance — members making collective decisions about budgets, rules, conflicts, and community evolution.

## 📝 Customization

**Change the story**: Edit `src/scenes/frontierTowerDecisions.ts`
**Adjust visuals**: Modify components in `src/components/Visualizations/`
**Update colors**: Edit `tailwind.config.js`
**Tweak effects**: Change settings in `TowerScene.tsx`

## 🌐 Browser Support

Requires WebGL 2.0:

- Chrome 119+
- Firefox 121+
- Safari 17+
- Edge 119+

## 💡 Performance

- 60fps at 1080p on modern GPUs
- 2000 particles with instanced rendering
- Post-processing optimized for real-time
- Lazy loading for heavy assets

---

Built with ❤️ to showcase playnet's power for programmable organizations
