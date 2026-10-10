// flows-map-data.js — geographic nutrient / economic flows for ecosystem-live-map.html
// ---------------------------------------------------------------------------------
// COORDINATES are real, named, satellite-verifiable places.
// MAGNITUDES are order-of-magnitude ESTIMATES of Amsterdam's (~0.9 M people) nitrogen
//   metabolism, from typical per-capita figures (food N intake ≈ excretion at steady
//   state ≈ 4.4 kg N / person / yr; P ≈ 0.6; K ≈ 1.0). They are illustrative, NOT a
//   measured inventory. `value` is the flow's NITROGEN throughput in kt N / yr and
//   drives particle density; `els` lists the elements the bundle carries.
//
// The story (the metabolic rift, quantified): the city eats ~4 kt N/yr grown in the
//   countryside, excretes it to the sewage works, which denitrifies ~2 to the air and
//   discharges ~1.5 to the sea, returning only ~0.3 to the land — so the farms import
//   ~4 kt N/yr of *synthetic fertiliser* to replace what never came back. The loop is
//   broken; "close the loop" routes the nutrients home instead.
//
// To drive this from the PLANNER instead of estimates: emit this same shape from a
//   located matter solve — `service.scm matter-results->wire` gives per-process
//   consume/produce events with quantities; multiply by `substances.scm` composition
//   for per-element masses, and map each process id to a place [lng,lat]. (Mirror
//   tools/emit/emit-matter-snapshot.scm, adding a process→coordinate table.)
window.__flowmap = {
  meta: { title: "Amsterdam nutrient metabolism (estimate)",
          note: "particle density ∝ kt N/yr (order-of-magnitude estimate) · coordinates real" },
  view: { center: [4.83, 52.40], zoom: 10.0 },
  // A place is a POINT (lng/lat) or a REGION (a `area` ring of [lng,lat]). `in` is the
  // spatial containment parent — the SAME contained-in relation as resource containment,
  // one scale up (homes ⊂ city ⊂ province). The renderer rolls flows up this tree by zoom:
  // a flow between two children of one region is internal; flows crossing a region's edge
  // aggregate into one banded ribbon that terminates AT the boundary (ray ∩ ring).
  // Rings are illustrative hand-traced outlines (swap for real admin/parcel boundaries).
  places: [
    // PROVINCE (top of the containment tree → a 3-deep rollup: point ⊂ city ⊂ province)
    { id:"noordholland", name:"Noord-Holland", kind:"province", emoji:"🗺️", area:[
        [4.45,52.25],[4.50,52.85],[4.95,52.95],[5.20,52.65],[5.25,52.40],[5.05,52.27],[4.75,52.24] ] },
    // regions (extent + containment). `area` may instead be a string id into a vendored
    // window.__boundaries file (real admin/parcel polygons); `radiusKm` makes a CIRCLE region.
    // `emoji` (optional): an economic resource / place can be shown as an emoji too — click it for info.
    { id:"ams",   name:"Amsterdam",                     kind:"city", emoji:"🏙️", in:"noordholland", area:[
        [4.755,52.305],[4.760,52.420],[4.880,52.430],[4.990,52.395],[4.980,52.320],[4.840,52.292] ] },
    { id:"flevo", name:"Flevopolder farmland",          kind:"farm", emoji:"🌾", area:[
        [5.280,52.420],[5.300,52.620],[5.620,52.660],[5.780,52.550],[5.700,52.400],[5.450,52.392] ] },
    // points inside Amsterdam
    { id:"food",  name:"Food Center Amsterdam",         lng:4.8360, lat:52.3766, kind:"market", emoji:"🏬", in:"ams" },
    { id:"dam",   name:"Amsterdam · centre",            lng:4.8926, lat:52.3731, kind:"city",   emoji:"🏛️", in:"ams" },
    { id:"pijp",  name:"De Pijp · homes",               lng:4.8915, lat:52.3550, kind:"homes",  emoji:"🏘️", in:"ams" },
    { id:"wwtp",  name:"RWZI Amsterdam-West · sewage",  lng:4.8350, lat:52.4020, kind:"works",  emoji:"🏭", in:"ams" },
    // points outside
    { id:"sea",   name:"IJmuiden · North Sea Canal",    lng:4.5780, lat:52.4600, kind:"sea",   emoji:"🌊" },
    // a CIRCLE region: the port is a round catchment — ribbons terminate flush on its arc
    { id:"fert",  name:"Port of Rotterdam",             lng:4.0450, lat:51.9550, kind:"port", emoji:"⚓", radiusKm:7 },
  ],
  // each flow names the economic resource transported and its carrier (the container).
  // containment: carrier ⊃ resource ⊃ els — the bundle of C·N·P·K it ultimately holds.
  // `recipe` = the transition (process) that FIRES the flow, run at its `from` place.
  // `comp` = the element masses (kt/yr) actually inside the resource — the squares in each
  //   container are sized by each element's share of that element's own total (its "kind").
  //   `value` (= the N throughput) drives the average-ribbon width per flow-kind.
  // `emoji` (optional): draw the moving container as an emoji instead of the nested box; click any
  //   container (emoji or box) to open an info card on what that part of the plan is flowing.
  flows: [
    { from:"flevo", to:"food", recipe:"grow",      value:4.0, carrier:"truck", resource:"produce",    emoji:"🥬", comp:{C:60,N:4.0,P:0.7,K:4.0}, kind:"food",   label:"food: countryside → city" },
    { from:"food",  to:"dam",  recipe:"market",    value:2.4, carrier:"van",   resource:"groceries",  emoji:"🛒", comp:{C:36,N:2.4,P:0.4,K:2.4}, kind:"food",   label:"food: market → centre" },
    { from:"dam",   to:"pijp", recipe:"deliver",   value:1.6, carrier:"cart",  resource:"meals",      emoji:"🍽️", comp:{C:24,N:1.6,P:0.3,K:1.6}, kind:"food",   label:"food: to homes" },
    { from:"pijp",  to:"wwtp", recipe:"consume",   value:2.2, carrier:"sewer", resource:"wastewater", comp:{C:6,N:2.2,P:0.3,K:2.0},  kind:"sewage", label:"excreta → sewage works" },
    { from:"dam",   to:"wwtp", recipe:"consume",   value:1.8, carrier:"sewer", resource:"wastewater", comp:{C:5,N:1.8,P:0.25,K:1.6}, kind:"sewage", label:"excreta → sewage works" },
    { from:"wwtp",  to:"sea",  recipe:"treat",     value:1.5, carrier:"outfall",resource:"effluent",  comp:{N:1.5,P:0.2},            kind:"sewage", label:"effluent → sea (rift)", rift:true },
    { from:"fert",  to:"flevo",recipe:"fertilise", value:4.0, carrier:"truck", resource:"fertiliser", emoji:"🧪", comp:{N:4.0,P:0.6,K:1.0},      kind:"fert",   label:"synthetic fertiliser → fields (replaces the unreturned)" },
    { from:"fert",  to:"food", recipe:"import",    value:2.0, carrier:"ship",  resource:"imports",    emoji:"🚢", comp:{},                       kind:"goods",  label:"imported goods" },
    { from:"wwtp",  to:"flevo",recipe:"compost",   value:3.5, carrier:"truck", resource:"biosolids",  emoji:"♻️", comp:{C:5,N:3.5,P:0.9,K:2.7},  kind:"compost",label:"compost / biosolids → fields (the closed loop)", loop:true },
  ],
  emissions: [
    { at:"wwtp", value:2.0, kind:"N2O" },   // denitrification at the plant → to the air
    { at:"dam",  value:3.0, kind:"CO2" },
    { at:"dam",  value:1.5, kind:"heat" },
  ],
  // DIFFUSE fields: a substance seeping through a medium DOWN A GRADIENT toward a sink, NOT a
  // routed container. Rendered as streaklets that advect along −∇φ (here φ = distance-to-sink,
  // a synthesized gravity potential) clipped to the region, coloured by element. This is the
  // metabolic rift made continuous: what escapes routing and runs downhill to the water.
  // mode "runoff" (default): advect down −∇φ (φ = elevation + drainage bias) toward `sink` — gravity.
  // mode "advect": carried by a vector field v (wind / current) sampled from window.__windgrid if
  //   vendored, else a synthesized prevailing field — the LIC atmospheric/marine case.
  fields: [
    { region:"flevo", sink:[5.10,52.52], comp:{N:1.4,P:0.35,K:0.25}, recipe:"leach",      rift:true, label:"nutrient leaching → Markermeer (gravity)" },
    { region:"ams",   mode:"advect",     comp:{N:0.7,P:0.05},        recipe:"deposition", rift:true, label:"airborne N drift / deposition (prevailing SW wind)" },
  ],
};
