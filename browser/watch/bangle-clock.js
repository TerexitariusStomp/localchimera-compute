// playnet τ-dial — a clock face for Bangle.js 2 (176×176, 3-bit colour).
//
// Satisfaction renders the app.html way, within 3-bit means: each band
// is SOLID colour from its floor to the met boundary, and stripe-dithered
// (alternating colour/background half-steps) beyond it — pale at wrist
// distance. The met boundary is the solid→pale transition itself.
//
// This is the REFERENCE THIN RENDERER of the clock projection
// (docs/dev/clock-projection.md): it draws exactly what it is handed and adds
// one live ingredient — the hand, from the watch's own clock. The brain
// is the playnet PWA (browser/app.html): its "⌚ send to watch" control
// pushes dialProjection(48) over Web Bluetooth into Storage as
// "playnet.proj.json" and calls PLAYNET_RELOAD(). DEMO below is a real
// export of the demo dial, the face's state before any push arrives.
//
// Try it without hardware: paste into the Espruino Web IDE emulator,
// https://www.espruino.com/ide/ → connect → Emulator (Bangle.js 2).

var DEMO = {"v":1,"turn":24,"m":48,"at":12,"tz":120,"needs":[{"name":"rest","col":"#2c4a6e","k":1,"peaks":[3.1,14.7,8.6],"lead":6},{"name":"nourishment","col":"#e8654f","k":4,"peaks":[13,19.4,7.6],"lead":1.5},{"name":"movement","col":"#0e7c7b","k":2,"peaks":[17,6.9,23],"lead":3},{"name":"learning","col":"#e2a512","k":1,"peaks":[10.4,15,23],"lead":6},{"name":"connection","col":"#7a4bb0","k":1,"peaks":[21.4,14.2,5.6],"lead":6}],"bands":{"cum":[[625,691,739,771,790,801,805,803,793,771,731,660,549,417,307,242,218,216,212,195,174,157,145,131,118,118,142,194,263,315,309,256,202,165,140,123,109,98,91,92,103,126,164,216,281,360,450,542,625],[678,741,786,815,832,842,845,843,835,816,780,722,655,611,597,582,534,447,348,280,244,232,246,307,410,511,575,598,585,536,458,370,298,253,236,255,314,393,457,478,454,400,346,327,355,421,508,598,678],[732,792,833,859,875,883,886,885,881,874,865,856,850,849,845,820,757,644,503,391,328,303,313,368,463,557,619,648,652,644,643,663,695,718,723,709,685,660,631,590,531,460,400,380,410,478,564,654,732],[807,863,899,921,933,940,942,942,941,938,935,932,934,940,946,947,941,928,915,907,903,895,876,847,823,812,809,807,805,806,812,823,833,834,821,794,760,724,689,645,586,519,466,452,486,556,644,732,807],[1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000,1000]],"met":[[414,499,575,638,685,714,725,715,687,638,569,476,364,253,169,122,102,94,86,76,65,58,52,47,42,41,50,68,92,110,108,90,71,58,49,43,39,35,33,34,39,49,67,93,131,182,249,328,414],[641,706,753,784,803,813,817,815,805,785,746,680,592,524,516,514,446,343,267,223,195,181,180,207,286,405,489,490,449,411,361,292,231,192,172,174,208,281,364,401,366,296,252,259,306,379,468,559,641],[693,756,799,827,844,853,857,855,848,833,807,770,738,727,727,706,640,527,403,314,269,252,265,324,425,524,588,612,604,569,518,477,469,485,507,518,521,527,532,520,479,418,361,342,371,437,524,614,693],[751,810,850,875,889,897,900,899,896,890,883,876,873,875,876,863,828,770,709,676,666,658,643,633,644,670,693,702,699,690,688,704,730,747,747,730,704,676,645,604,545,475,416,398,429,497,584,673,751],[884,912,933,946,954,958,960,960,959,957,954,953,954,958,962,963,959,950,940,935,932,928,917,904,899,902,905,900,889,879,875,880,886,889,884,874,866,864,869,876,880,877,865,846,827,820,829,853,884]]},"events":[[6.75,8,"breakfast","free","consume",null],[9.5,12,"harvest shift","work","work","nourishment"],[13,14.25,"lunch w/ Ana","free","consume",null],[15,16.5,"repair café","work","work","movement"],[16,17.25,"school run","free","deliver-service","connection"],[19.25,21.25,"band practice","free","use",null]],"proposals":[[5,7,"bakery shift w/ Sam","work","work","nourishment","Sam"],[14,15,"tool-library duty","work","work","movement","the commons"],[18,19,"evening picnic","free","use","connection","Ana"]]};

// the live projection: what the PWA last pushed, else the demo. The
// reload hook is what the bridge calls after writing Storage — the face
// swaps data without rebooting.
var P = require("Storage").readJSON("playnet.proj.json", 1) || DEMO;
global.PLAYNET_RELOAD = function () {
  P = require("Storage").readJSON("playnet.proj.json", 1) || DEMO;
  draw();
};

// ------------------------------------------------------------ geometry
// hour 0 at the top, clockwise; area-true r(f) = R√f — both are canon
// (docs/dev/clock-projection.md), identical to app.html's ang/rad.
var CX = 88, CY = 88, R = 56;          // the dial
var LANE0 = 62, LANEW = 4, LANEG = 2;  // rim event lanes, outward
var ang = function (t) { return Math.PI / 2 - t * 2 * Math.PI / P.turn; };
var rad = function (f) { return R * Math.sqrt(f > 0 ? f : 0); };
var px = function (r, a) { return CX + r * Math.cos(a); };
var py = function (r, a) { return CY - r * Math.sin(a); };

// 3-bit colour: each channel thresholded — the demo palette lands on
// blue/red/cyan/yellow/magenta, as close as 8 colours get to app.html
function c3(hex) {
  var v = parseInt(hex.substr(1), 16);
  g.setColor((v >> 16 & 255) > 104 ? 1 : 0,
             (v >> 8 & 255) > 104 ? 1 : 0,
             (v & 255) > 104 ? 1 : 0);
}
var WORK = "#1581a8", FREE = "#e2a512";  // app.html's cWarm / cYea

// ring-segment fill between radii f0..f1 (permil) over one sample step:
// one quad per step is plenty at m=24 on 176 px
function quad(r00, r01, r10, r11, a0, a1) {
  g.fillPoly([px(r00, a0), py(r00, a0), px(r01, a0), py(r01, a0),
              px(r11, a1), py(r11, a1), px(r10, a1), py(r10, a1)]);
}

function drawBands() {
  var M = P.m, cum = P.bands.cum, met = P.bands.met;
  for (var i = 0; i < M; i++) {
    var a0 = ang(P.turn * i / M);
    var a1 = ang(P.turn * (i + 1) / M);
    var lo0 = 0, lo1 = 0;
    for (var k = 0; k < P.needs.length; k++) {
      var hi0 = rad(cum[k][i] / 1000), hi1 = rad(cum[k][i + 1] / 1000);
      var mt0 = rad(met[k][i] / 1000), mt1 = rad(met[k][i + 1] / 1000);
      c3(P.needs[k].col);
      // satisfied: solid from the band floor to the met boundary
      quad(lo0, mt0, lo1, mt1, a0, a1);
      // unmet desire: quarter-step stripes, phase offset per band —
      // ~2px at these radii, the eye fuses them into a PALE tint of the
      // band's own colour (app.html's met/unmet reading, in 3-bit means)
      for (var q = 0; q < 4; q++) {
        if ((i * 4 + q + k) % 2) continue;
        var b0 = ang(P.turn * (i + q / 4) / M);
        var b1 = ang(P.turn * (i + (q + 1) / 4) / M);
        var u0 = q / 4, u1 = (q + 1) / 4;
        quad(mt0 + (mt1 - mt0) * u0, hi0 + (hi1 - hi0) * u0,
             mt0 + (mt1 - mt0) * u1, hi0 + (hi1 - hi0) * u1, b0, b1);
      }
      lo0 = hi0; lo1 = hi1;
    }
  }
}

function drawChrome() {
  g.setColor(0, 0, 0);
  g.drawCircle(CX, CY, R + 1);
  for (var j = 0; j < 4; j++) {              // 0, τ∕4, τ∕2, 3τ∕4
    var a = ang(P.turn * j / 4);
    g.drawLine(px(R + 1, a), py(R + 1, a), px(R + 5, a), py(R + 5, a));
  }
}

// rhythm marks: solid dot at the strongest peak, hollow "begin" dot one
// anticipation lead earlier — the quarter-period law, on the wrist
function drawLeads() {
  for (var k = 0; k < P.needs.length; k++) {
    var nd = P.needs[k];
    if (!nd.k || !nd.peaks.length) continue;
    var lo = k ? P.bands.cum[k - 1] : null, hi = P.bands.cum[k];
    var mid = function (t) {
      var i = Math.round(t / P.turn * P.m) % P.m;
      return rad(((lo ? lo[i] : 0) + hi[i]) / 2000);
    };
    var tp = nd.peaks[0], tb = (tp - nd.lead + P.turn) % P.turn;
    g.setColor(0, 0, 0);
    g.fillCircle(px(mid(tp), ang(tp)), py(mid(tp), ang(tp)), 2);
    g.drawCircle(px(mid(tb), ang(tb)), py(mid(tb), ang(tb)), 2);
  }
}

// rim arcs: events solid, proposals dotted; overlaps stack outward
function drawArcs(rows, dotted, laneBase) {
  var ends = [];                              // per-lane last end hour
  for (var e = 0; e < rows.length; e++) {
    var t0 = rows[e][0], t1 = rows[e][1], kind = rows[e][3];
    var lane = 0;
    while (lane < ends.length && ends[lane] > t0) lane++;
    ends[lane] = t1;
    var r0 = laneBase + lane * (LANEW + LANEG), r1 = r0 + LANEW;
    c3(kind === "work" ? WORK : FREE);
    var steps = Math.max(2, Math.ceil((t1 - t0) * 4));
    for (var s = 0; s < steps; s++) {
      if (dotted && s % 2) continue;
      var a0 = ang(t0 + (t1 - t0) * s / steps);
      var a1 = ang(t0 + (t1 - t0) * (s + 1) / steps);
      quad(r0, r1, r0, r1, a0, a1);
    }
  }
}

function drawHand(now) {
  var a = ang(now);
  g.setColor(0, 0, 0);
  g.drawLine(px(6, a), py(6, a), px(R, a), py(R, a));
  g.drawLine(px(6, a) + 1, py(6, a), px(R, a) + 1, py(R, a));
  g.fillCircle(px(R, a), py(R, a), 3);
}

var two = function (x) { return (x < 10 ? "0" : "") + x; };
function nextEvent(now) {
  var best = null, bd = 1e9;
  for (var e = 0; e < P.events.length; e++) {
    var d = (P.events[e][0] - now + P.turn) % P.turn;
    if (d < bd) { bd = d; best = P.events[e]; }
  }
  return best;
}

function draw() {
  var d = new Date();
  var now = d.getHours() + d.getMinutes() / 60;
  g.setBgColor(1, 1, 1);
  g.clear();
  drawBands();
  drawChrome();
  drawLeads();
  drawArcs(P.events, false, LANE0);
  drawArcs(P.proposals, true, LANE0 + LANEW + LANEG);
  drawHand(now);
  g.setColor(0, 0, 0);
  g.setFont("6x8");
  g.setFontAlign(-1, -1);
  g.drawString(two(d.getHours()) + ":" + two(d.getMinutes()), 3, 3);
  var nx = nextEvent(now);
  if (nx) {
    g.setFontAlign(0, 1);
    g.drawString("→ " + two(Math.floor(nx[0])) + ":" +
                 two(Math.round((nx[0] % 1) * 60)) + " " + nx[2], CX, 175);
  }
}

g.clear();
Bangle.setUI("clock");
draw();
// a minute step is 0.25° of turn — redraw on the minute, no finer
var tick;
function onMin() { draw(); tick = setTimeout(onMin, 60000 - (Date.now() % 60000)); }
tick = setTimeout(onMin, 60000 - (Date.now() % 60000));
Bangle.on("lcdPower", function (on) { if (on) draw(); });
