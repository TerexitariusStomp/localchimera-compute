// app/d3.d.ts — the d3 surface the dial actually calls, declared by hand.
//
// d3 is a CLASSIC script (browser/vendor/d3.v7.min.js, loaded before any
// module), so it is a global rather than an import — hence `declare global`
// rather than a module declaration.
//
// Why not @types/d3: it is not packaged for Guix (only node-types-node and
// node-types-source-map-support are), so depending on it would mean npm inside
// an environment the rest of the repo keeps pure and manifest-declared. A hand
// written subset costs a few lines per call site and stays checkable against the
// vendored v7 build.
//
// POLICY — declare a member the first time a converted module calls it, not
// before. An undeclared member is a type error at the call site, which is the
// point: each entry here is a claim someone made deliberately and can verify
// against the vendored d3, rather than a wholesale import of claims nobody read.
//
// Declared so far (the dial calls 29 distinct members in total; the rest arrive
// with the modules that use them):
//
//   interpolateRgb        geom.ts — paleCol
//   selection, transition  theme.ts — the two prototypes it paints through
//   rgb                    core.ts — lum(), the accessible-ink luminance
//   hierarchy, treemap     taxonomy.ts — the classification spine as a treemap
//   select, selectAll      core.ts, location.ts — and the Selection surface
//                          the drawing code is written in (see the note there)
//   mean, sum, range       bands.ts — the sample walk and the phase-averages
//                          σ flattens toward
//   pointer, drag           ring.ts — the editable arcs, dragged and resized
//
// The dial uses d3 in two quite different ways, and they deserve different
// treatment:
//
//   VALUE HELPERS (mean, sum, max, range, color, interpolate*, geo*, scale*)
//   are pure, small and exactly typable. Declare them as they come up.
//
//   THE SELECTION DSL (select, selectAll, drag, pointer) is a fluent builder
//   whose real types are thousands of lines of datum-generics in @types/d3. A
//   hand-written *precise* version is not achievable; a hand-written
//   *fake-precise* one would be worse than none, because it would look checked.
//   It stays undeclared until a module that actually CALLS it converts —
//   core.js, main.js and eight tabs do; theme.ts does not.
//
// That last point is why the Selection question does not block theme.ts.
// paintThrough() interposes on two prototypes and never constructs or calls a
// selection, so what it needs is not "what is a Selection" but "what does a
// patchable paint method look like".

declare global {
  namespace d3 {
    /**
     * Interpolate between two CSS colours in RGB space.
     * Returns the interpolator: call it with t in [0, 1].
     */
    function interpolateRgb(a: string | Color, b: string | Color): (t: number) => string;

    /** A parsed colour. Structural: the three channels the dial reads off it. */
    interface RGBColor {
      r: number;
      g: number;
      b: number;
    }
    function rgb(colour: string): RGBColor;

    /** A colour you can shade and re-format. */
    interface Color {
      rgb(): RGBColor;
      darker(k?: number): Color;
      brighter(k?: number): Color;
      formatHex(): string;
      toString(): string;
    }
    function color(spec: string): Color;

    /**
     * The arc generator: configured by chaining, then CALLED with the datum
     * whose angles and radii it reads. The dial passes those inline, so the
     * datum is exactly the four fields d3-shape looks for.
     */
    interface ArcDatum {
      startAngle: number;
      endAngle: number;
      innerRadius: number;
      outerRadius: number;
      padAngle?: number;
      cornerRadius?: number;
    }
    interface ArcGenerator {
      (d: ArcDatum): string | null;
      cornerRadius(r: number): ArcGenerator;
      padAngle(a: number): ArcGenerator;
    }
    function arc(): ArcGenerator;

    /**
     * A geographic projection: called with [lng, lat], answers [x, y] in the
     * output frame, or null where the point does not project (geoAlbersUsa
     * returns null outside the United States, which is how law.ts knows a
     * place is off its inset).
     */
    interface GeoProjection {
      (coordinates: [number, number]): [number, number] | null;
      /**
       * The projection's scale. On an orthographic globe this is how the whole
       * earth grows continuously into a neighbourhood without re-projecting.
       */
      fitExtent(extent: [[number, number], [number, number]], object: unknown): GeoProjection;
      fitSize(size: [number, number], object: unknown): GeoProjection;
      scale(k: number): GeoProjection;
      translate(t: [number, number]): GeoProjection;
    }
    /**
     * A piecewise-linear scale. Generic in the OUTPUT, because the dial uses it
     * for colours as often as for numbers: the sky reads an altitude in degrees
     * and answers a hex string.
     */
    interface LinearScale<Out> {
      (value: number): Out;
      domain(values: number[]): LinearScale<Out>;
      range(values: Out[]): LinearScale<Out>;
      /** How to move BETWEEN two range values — Lab, for perceptual colour. */
      interpolate(fn: (a: Out, b: Out) => (t: number) => Out): LinearScale<Out>;
      /** Hold the ends rather than extrapolating past the domain. */
      clamp(yes: boolean): LinearScale<Out>;
    }
    function scaleLinear<Out = number>(): LinearScale<Out>;
    /** The same surface over a logarithmic domain (strictly positive). */
    function scaleLog<Out = number>(): LinearScale<Out>;

    /**
     * A colour in HCL (CIELCh): hue, chroma, luminance. The channels are
     * MUTABLE and the object stringifies back to CSS, which is what lets a
     * colour be softened — chroma eased, lightness lifted — without going
     * through a hex round-trip.
     */
    interface HCLColor {
      h: number;
      c: number;
      l: number;
      toString(): string;
    }
    function hcl(colour: string): HCLColor;

    /**
     * Interpolate two colours through HCL, which walks the HUE CIRCLE — gold to
     * cyan passes through green, the way pigments mix. Lab would cut across
     * grey instead.
     */
    function interpolateHcl(a: string, b: string): (t: number) => string;

    /** Interpolate two colours through CIELAB, so the path reads as even light. */
    function interpolateLab(a: string, b: string): (t: number) => string;

    /**
     * The orthographic projection: the earth as a globe seen from far away.
     * `rotate` puts a coordinate at the centre, which is how the dial's globe
     * is always centred on YOU, and `precision` trades adaptive resampling for
     * frame cost — coarser while it moves, finer when it stands still.
     */
    interface Orthographic extends GeoProjection {
      rotate(angles: [number, number] | [number, number, number]): Orthographic;
      precision(delta: number): Orthographic;
      // re-declared so the chain keeps its own type rather than widening to
      // GeoProjection at the first call
      scale(k: number): Orthographic;
      translate(t: [number, number]): Orthographic;
    }
    function geoOrthographic(): Orthographic;

    /** The graticule at ten degrees, as one MultiLineString. */
    function geoGraticule10(): unknown;

    /** The spherical area of a GeoJSON object, in steradians. */
    function geoArea(object: unknown): number;

    /** The great-circle distance between two points, in radians. */
    function geoDistance(a: [number, number], b: [number, number]): number;

    function geoNaturalEarth1(): GeoProjection;
    function geoAlbersUsa(): GeoProjection;

    /** The path generator for a projection: a GeoJSON object → an SVG "d". */
    interface GeoPath {
      (object: unknown): string | null;
      centroid(object: unknown): [number, number];
      bounds(object: unknown): [[number, number], [number, number]];
    }
    function geoPath(projection?: GeoProjection): GeoPath;

    /**
     * The arithmetic mean, or undefined over an empty (or all-undefined)
     * input — which is the honest signature, and the reason `centroid` in
     * containers.ts asserts: it is only ever called with a non-empty cloud.
     */
    function mean<T>(values: T[], accessor: (d: T, i: number) => number | undefined | null): number | undefined;
    /** The direct form, over numbers already. Same skipping, same undefined. */
    function mean(values: Iterable<number | undefined | null>): number | undefined;

    /**
     * The sum, which — unlike mean — answers 0 rather than undefined over an
     * empty or all-unreadable input. That asymmetry is d3's, and bands.ts
     * depends on it: a total of 0 divides to Infinity, which is visible, where
     * an undefined would have to be guarded for.
     */
    function sum<T>(values: T[], accessor?: (d: T, i: number) => number | undefined | null): number;

    /**
     * The largest readable value, or undefined when there is none. Like mean,
     * it SKIPS what it cannot read — which is why the rhythm reading uses it
     * rather than Math.max: one unreadable harmonic would otherwise poison the
     * comparison and report a peaked need as standing capacity.
     */
    function max(values: Iterable<number | undefined | null>): number | undefined;
    /**
     * The largest value an accessor pulls out. Like mean and sum, it SKIPS
     * entries the accessor cannot read — which is why the plain reduction is
     * not a drop-in replacement for it.
     */
    function max<T>(values: T[], accessor: (d: T, i: number) => number | undefined | null): number | undefined;

    /** [start, stop) by step — the sample index the dial walks the turn with. */
    function range(stop: number): number[];
    function range(start: number, stop: number, step?: number): number[];

    /**
     * The convex hull of a point cloud, counter-clockwise, or null for fewer
     * than three points (or collinear ones) — the null is the case
     * containers.ts falls back to a covering disc for.
     *
     * Generic in the point so a caller may keep its own richer point type;
     * d3 reads [0] and [1] and returns the SAME objects, in hull order.
     * It also SORTS the array it is given, hence the defensive copy at the
     * one call site.
     */
    function polygonHull<P extends number[]>(points: P[]): P[] | null;

    /**
     * The line and area generators (d3-shape): configured with accessors,
     * then CALLED with the data, answering an SVG path string — which is how
     * the runway plot (tabs/family.ts) draws through the html template rather
     * than through a selection. Generic in the datum the accessors read.
     */
    interface LineGenerator<T> {
      (data: T[]): string | null;
      x(fn: (d: T, i: number) => number): LineGenerator<T>;
      y(fn: (d: T, i: number) => number): LineGenerator<T>;
      defined(fn: (d: T, i: number) => boolean): LineGenerator<T>;
    }
    function line<T>(): LineGenerator<T>;
    interface AreaGenerator<T> {
      (data: T[]): string | null;
      x(fn: (d: T, i: number) => number): AreaGenerator<T>;
      y0(fn: (d: T, i: number) => number): AreaGenerator<T>;
      y1(fn: (d: T, i: number) => number): AreaGenerator<T>;
      defined(fn: (d: T, i: number) => boolean): AreaGenerator<T>;
    }
    function area<T>(): AreaGenerator<T>;

    /**
     * A d3 selection.
     *
     * WHAT THIS MODELS, exactly, because a type that overstates itself is worse
     * than none:
     *
     *   · CHAINING — every method returns a selection, which is the shape all
     *     the dial's drawing code is written in.
     *   · METHOD EXISTENCE — a typo or a wrong arity is a compile error.
     *   · THE DATUM, through `data()` → the accessors that follow. That is the
     *     one generic worth carrying, because it is the one the drawing code
     *     actually reads: `.attr("x", d => …)` knows what d is.
     *
     * WHAT IT DOES NOT MODEL, and must not be read as modelling: the element
     * type, the parent's datum, the enter/update/exit distinction that `join`
     * collapses, or the difference between a selection and a transition
     * (theme.ts patches both prototypes identically, which is why one interface
     * serves). Real d3's types carry all of that in several thousand lines of
     * generics; this is the useful tenth of it.
     *
     * Declared as a SET rather than one method at a time — unlike the value
     * helpers above. A fluent builder used by a dozen modules would otherwise
     * make every conversion an edit to this file, and the members below are one
     * coherent surface, not independent claims.
     */
    /** What a setter accepts as a literal value. */
    type Primitive = string | number | boolean | null | undefined;

    /**
     * The per-datum accessor form every setter also takes. Separating it from
     * Primitive is what lets `d` be CONTEXTUALLY TYPED at the call site —
     * `.attr("x", d => d.x0)` knows what d is. A bare `unknown` in the value
     * position collapses the union and the inference with it.
     */
    type ValueFn<Datum> = (this: Element, d: Datum, i: number) => Primitive;

    interface Selection<Datum = unknown> {
      select(selector: string): Selection<Datum>;
      selectAll(selector: string): Selection<unknown>;
      append(name: string): Selection<Datum>;
      /**
       * `before` may be a SELECTOR or a function answering the node to insert
       * ahead of. The function form is how the recipe card slips a chip's
       * background rect immediately behind the text it was measured from.
       */
      insert(name: string, before?: string | (() => Element | null)): Selection<Datum>;

      // Each of these is a GETTER with one argument (or none) and a SETTER with
      // the value — d3's own convention, and the reason they are overloads
      // rather than one signature. Typing only the setter form is what made a
      // `.property("value")` read look like a chain and get rewritten around.
      attr(name: string): string | null;
      attr(name: string, value: Primitive | ValueFn<Datum>): Selection<Datum>;
      style(name: string): string;
      style(name: string, value: Primitive | ValueFn<Datum>, priority?: string): Selection<Datum>;
      classed(names: string): boolean;
      classed(names: string, value: boolean | ValueFn<Datum>): Selection<Datum>;
      property(name: string): unknown;
      property(name: string, value: Primitive | ValueFn<Datum>): Selection<Datum>;
      text(): string;
      text(value: Primitive | ValueFn<Datum>): Selection<Datum>;
      html(): string;
      html(value: Primitive | ValueFn<Datum>): Selection<Datum>;

      /**
       * d3 v6+ hands the listener (event, datum). The event is generic so a
       * handler may declare the kind it expects — `on("mousemove", ev => …)`
       * with ev: MouseEvent — which is how the call sites are written.
       */
      on<E extends Event = Event>(type: string, listener?: ((this: Element, event: E, d: Datum) => void) | null): Selection<Datum>;
      each(fn: (this: Element, d: Datum, i: number) => void): Selection<Datum>;
      call(fn: (selection: Selection<Datum>, ...args: never[]) => void, ...args: never[]): Selection<Datum>;

      /** The one real generic: what follows knows what a datum is. */
      data<T>(values: T[], key?: (d: T, i: number) => string): Selection<T>;
      join(name: string): Selection<Datum>;
      /** The callback form: build the entering nodes, get the merged selection. */
      join(onEnter: (enter: Selection<Datum>) => Selection<Datum>): Selection<Datum>;
      enter(): Selection<Datum>;
      exit(): Selection<Datum>;
      merge(other: Selection<Datum>): Selection<Datum>;
      datum(value?: unknown): Selection<Datum>;

      filter(match: string | ((d: Datum, i: number) => boolean)): Selection<Datum>;
      remove(): Selection<Datum>;
      raise(): Selection<Datum>;
      lower(): Selection<Datum>;
      /**
       * Start a transition on this selection. It answers the same attr/style
       * calls a selection does — which is what lets a drawer set a value the
       * same way whether it is painting or animating — plus the chaining a
       * transition adds.
       */
      transition(): Selection<Datum> & Transition;
      /**
       * Fire a DOM event on every node — the way a restored setting re-enters
       * the app through the SAME handler a user's click would, rather than
       * through a second path that has to be kept in step with it.
       */
      dispatch(type: string): Selection<Datum>;
      /** Stop any transition running on this selection, leaving it where it is. */
      interrupt(name?: string): Selection<Datum>;

      node(): Element | null;
      nodes(): Element[];
      empty(): boolean;
      size(): number;
    }
    function select(selector: string | Element): Selection;
    function selectAll(selector: string): Selection;

    /**
     * Where a pointer event happened, in the coordinate system of `target`.
     * The two-argument form is the one the dial uses: the ring reads a click
     * against its own <g>, never against the page.
     */
    function pointer(event: Event, target?: Element): [number, number];

    /**
     * What a drag handler is handed. d3 supplies the position in the
     * CONTAINER's coordinates and the step since the last tick, which is what
     * lets the ring unwrap a drag across midnight without tracking it itself.
     */
    interface DragEvent {
      x: number;
      y: number;
      dx: number;
      dy: number;
      sourceEvent: Event;
      /** The datum under the gesture — the node the web face pins while it is held. */
      subject: unknown;
    }

    /**
     * The drag behaviour: configured by chaining, then attached with `.call`.
     *
     * `container` matters more than it looks. By default d3 reads coordinates
     * against the dragged element, and the ring RECREATES its arc on every
     * tick — so without a stable container the frame moves out from under the
     * gesture. The dial passes the parent <g> for exactly that reason.
     */
    interface DragBehavior<E = DragEvent> {
      (selection: Selection): void;
      container(accessor: () => Element): DragBehavior<E>;
      on(type: string, listener: (event: E) => void): DragBehavior<E>;
    }
    function drag<E = DragEvent>(): DragBehavior<E>;

    /**
     * A node of a hierarchy. `x0/y0/x1/y1` are written by a LAYOUT (treemap
     * below) rather than by hierarchy() itself, and are declared required
     * because every reader here runs after the layout has been applied.
     */
    interface HierarchyNode<T> {
      data: T;
      depth: number;
      height: number;
      parent: HierarchyNode<T> | null;
      children?: HierarchyNode<T>[];
      /** Set by sum(). */
      value?: number;
      x0: number;
      y0: number;
      x1: number;
      y1: number;
      sum(value: (d: T) => number): HierarchyNode<T>;
      sort(compare: (a: HierarchyNode<T>, b: HierarchyNode<T>) => number): HierarchyNode<T>;
      descendants(): HierarchyNode<T>[];
      ancestors(): HierarchyNode<T>[];
      leaves(): HierarchyNode<T>[];
      each(fn: (node: HierarchyNode<T>) => void): HierarchyNode<T>;
    }
    function hierarchy<T>(data: T, children?: (d: T) => T[] | null | undefined): HierarchyNode<T>;

    /** The treemap layout: configured by chaining, then CALLED on a root. */
    interface TreemapLayout {
      <T>(root: HierarchyNode<T>): HierarchyNode<T>;
      size(dimensions: [number, number]): TreemapLayout;
      padding(value: number): TreemapLayout;
      paddingOuter(value: number): TreemapLayout;
      paddingTop(value: number): TreemapLayout;
      paddingInner(value: number): TreemapLayout;
      round(value: boolean): TreemapLayout;
    }
    function treemap(): TreemapLayout;

    /**
     * One of d3's paint methods, as seen by code that WRAPS it rather than
     * calls it.
     *
     * `unknown` throughout: the wrapper hands d3's own arguments back to d3's
     * own method unread, and narrows the one it does inspect (`name`, by
     * typeof). This wanted `any` only while paintThrough forwarded the
     * `arguments` object, which is not an array and so will not pass as
     * unknown[]; forwarding rest params instead removed the need, and nothing
     * here has to be told to stop checking.
     */
    type PaintMethod = (this: unknown, ...args: unknown[]) => unknown;

    /**
     * A prototype theme.ts interposes on. Deliberately NOT a Selection: these
     * are the only three members the patch touches, plus the idempotence flag
     * it stamps so a second paintThrough() is a no-op.
     */
    interface PaintProto {
      __themedPaint?: boolean;
      attr: PaintMethod;
      style: PaintMethod;
      html: PaintMethod;
    }

    /** Something carrying a patchable prototype. */
    interface Paintable {
      prototype: PaintProto;
    }

    /**
     * A named transition chain: `.tween` runs a per-frame function, `.transition`
     * queues the next stage after this one ends, and `.on("end", …)` fires once
     * the whole chain has. Named so a second call to d3.transition(NAME)
     * INTERRUPTS the first — which is what keeps a reveal and an exit from
     * animating over each other.
     */
    interface Transition {
      /**
       * A transition answers attr and style the way a selection does — that is
       * the whole point of the API: a drawer sets a value the same way whether
       * it is painting the value or animating toward it.
       */
      attr(name: string, value: Primitive | ValueFn<unknown>): Transition;
      style(name: string, value: Primitive | ValueFn<unknown>): Transition;
      duration(ms: number): Transition;
      ease(fn: (t: number) => number): Transition;
      tween(name: string, factory: () => (t: number) => void): Transition;
      transition(): Transition;
      on(type: string, listener: () => void): Transition;
    }

    const selection: Paintable;
    /** Both a factory for named transition chains AND a patchable prototype. */
    const transition: Paintable & ((name?: string) => Transition);

    // ── the force layout and the zoom (d3-force, d3-zoom) — tabs/web.ts ──────
    // The recipe web is a graph with cycles, so no hierarchy layout fits it;
    // a force simulation settles it and the zoom lets the reader move through
    // it. d3 MUTATES the node objects (x, y, vx, vy) and rewrites each link's
    // source/target from an id to the node itself once initialised — both are
    // stated in the types rather than left for a reader to discover.

    /** What the simulation writes onto a node; fx/fy pin one under a drag. */
    interface SimulationNode {
      x?: number;
      y?: number;
      vx?: number;
      vy?: number;
      fx?: number | null;
      fy?: number | null;
      index?: number;
    }
    /** A link: an id (or index) before the simulation starts, the node after. */
    interface SimulationLink<N extends SimulationNode> {
      source: N | string | number;
      target: N | string | number;
      index?: number;
    }
    interface Force<N extends SimulationNode> {
      (alpha: number): void;
      initialize?(nodes: N[]): void;
    }
    interface ForceLink<N extends SimulationNode, L extends SimulationLink<N>> extends Force<N> {
      id(fn: (d: N) => string): ForceLink<N, L>;
      distance(d: number | ((l: L) => number)): ForceLink<N, L>;
      strength(s: number | ((l: L) => number)): ForceLink<N, L>;
      links(): L[];
      links(l: L[]): ForceLink<N, L>;
    }
    interface ForceManyBody<N extends SimulationNode> extends Force<N> {
      strength(s: number | ((d: N) => number)): ForceManyBody<N>;
      distanceMax(d: number): ForceManyBody<N>;
    }
    interface ForceCenter<N extends SimulationNode> extends Force<N> {
      strength(s: number): ForceCenter<N>;
    }
    interface ForceCollide<N extends SimulationNode> extends Force<N> {
      radius(r: number | ((d: N) => number)): ForceCollide<N>;
      strength(s: number): ForceCollide<N>;
    }
    interface ForceAxis<N extends SimulationNode> extends Force<N> {
      strength(s: number | ((d: N) => number)): ForceAxis<N>;
    }
    interface Simulation<N extends SimulationNode> {
      nodes(): N[];
      nodes(n: N[]): Simulation<N>;
      force(name: string, f: Force<N> | null): Simulation<N>;
      alpha(a: number): Simulation<N>;
      alphaTarget(a: number): Simulation<N>;
      alphaDecay(d: number): Simulation<N>;
      velocityDecay(d: number): Simulation<N>;
      restart(): Simulation<N>;
      stop(): Simulation<N>;
      tick(n?: number): Simulation<N>;
      on(type: string, listener: (() => void) | null): Simulation<N>;
    }
    function forceSimulation<N extends SimulationNode>(nodes?: N[]): Simulation<N>;
    function forceLink<N extends SimulationNode, L extends SimulationLink<N>>(links?: L[]): ForceLink<N, L>;
    function forceManyBody<N extends SimulationNode>(): ForceManyBody<N>;
    function forceCenter<N extends SimulationNode>(x?: number, y?: number): ForceCenter<N>;
    function forceCollide<N extends SimulationNode>(r?: number | ((d: N) => number)): ForceCollide<N>;
    function forceX<N extends SimulationNode>(x?: number | ((d: N) => number)): ForceAxis<N>;
    function forceY<N extends SimulationNode>(y?: number | ((d: N) => number)): ForceAxis<N>;

    /** A pan-and-scale: k the scale, x and y the translation; prints as an SVG transform. */
    interface ZoomTransform {
      k: number;
      x: number;
      y: number;
      translate(x: number, y: number): ZoomTransform;
      scale(k: number): ZoomTransform;
      toString(): string;
    }
    interface ZoomEvent {
      transform: ZoomTransform;
      sourceEvent: Event | null;
    }
    /** The zoom behaviour: configured by chaining, attached with `.call`, driven with `.transform`. */
    interface ZoomBehavior {
      (selection: Selection): void;
      scaleExtent(e: [number, number]): ZoomBehavior;
      on(type: string, listener: (event: ZoomEvent) => void): ZoomBehavior;
      transform(selection: Selection | Transition, t: ZoomTransform): void;
    }
    function zoom(): ZoomBehavior;
    const zoomIdentity: ZoomTransform;

    /** Cubic ease in and out — the dial's one easing curve. */
    function easeCubicInOut(t: number): number;
  }
}

export {};
