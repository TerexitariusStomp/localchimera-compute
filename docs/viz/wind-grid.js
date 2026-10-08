// wind-grid.js — vendored u/v vector field for the advect (drift) mode of ecosystem-live-map.
// ---------------------------------------------------------------------------------------------
// This is a REPRESENTATIVE prevailing-SW field over the Netherlands, NOT a specific GFS hour —
// it makes the drift field DATA-DRIVEN (read from a file) rather than the inline synth fallback.
//
// To use REAL data, write the SAME shape from a source fetched over Tor (so your IP isn't leaked):
//   for a grid of (lat,lng):
//     torsocks curl 'https://api.open-meteo.com/v1/forecast?latitude=LAT&longitude=LNG&hourly=wind_speed_10m,wind_direction_10m'
//   then, per cell:  u = speed*sin(dir·π/180);  v = speed*cos(dir·π/180)
//   (meteorological wind_direction is the direction the wind comes FROM; negate u,v for the
//    direction it blows TO, which is what the advect mode follows.)
// Fill u[],v[] row-major (j outer = latitude, i inner = longitude). Replace this file; no code change.
window.__windgrid = (function(){
  const x0=3.5, y0=51.5, dx=0.25, dy=0.25, nx=13, ny=9, u=[], v=[];
  for(let j=0;j<ny;j++) for(let i=0;i<nx;i++){
    const lon=x0+i*dx, lat=y0+j*dy, base=6.5;                 // ~6.5 m/s mean, SW→NE prevailing
    u.push(base*0.8 + 1.6*Math.sin(lat*1.3+lon*0.7));         // eastward component (+ spatial swirl)
    v.push(base*0.6 + 1.6*Math.cos(lon*1.1-lat*0.9));         // northward component
  }
  return { x0, y0, dx, dy, nx, ny, u, v };
})();
