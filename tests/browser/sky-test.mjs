// tests/browser/sky-test.mjs — the sun, from where you stand (browser/app/sky.js)
//
// The rim wears the day's own light, and it is worth having the astronomy be
// EXACT rather than a plausible gradient — because the claims it makes are
// checkable against the world. The sun really does rise due east at the
// equinoxes, from everywhere. Days really are longer in a hemisphere's summer.
// Above the Arctic circle the sun really does fail to rise at midwinter, and
// answering "no sunrise" is different from answering a made-up hour.
//
// So this pins the physics, not the pixels: declination through the year, the
// altitude formula's fixed points, sunrise and sunset, and the polar cases the
// caller draws nothing for.
//
// Run: node tests/browser/sky-test.mjs

import { installDomStub, harness } from "./dom-stub.mjs";
installDomStub();

const SKY = await import("../../browser/app/sky.js");
const { USER } = await import("../../browser/app/core.js");

const { check, done } = harness();
const near = (a, b, tol) => Math.abs(a - b) <= tol;
const deg = r => r * 180 / Math.PI;

// The module reads USER.lat live, so a case just moves the observer.
const at = lat => { USER.lat = lat; };

// THE FORMULA'S OWN turning points, not the calendar's.
//
// solarDec is Cooper's approximation, δ = 23.44° · sin(2π(284 + dd + 1)/365),
// whose zeros and extremes fall where that sine's do — dd = 80 and 262.5 for the
// equinoxes, 171.25 and 353.75 for the solstices. Those sit within a day or so
// of the astronomical dates, which is the approximation's known accuracy and
// not something to test around: asked at ITS equinox it must answer exactly
// zero, and a test that asked on the calendar's day would be measuring the
// approximation's error rather than the code.
const MAR_EQUINOX = 80, SEP_EQUINOX = 262.5;
const JUN_SOLSTICE = 171.25, DEC_SOLSTICE = 353.75;

// ── declination: where the sun stands through the year ─────────────────────
{
  check("at the March equinox the sun is over the equator",
        near(deg(SKY.solarDec(MAR_EQUINOX)), 0, 1e-9),
        ` — ${deg(SKY.solarDec(MAR_EQUINOX)).toFixed(2)}°`);
  check("at the September equinox it is over the equator again",
        near(deg(SKY.solarDec(SEP_EQUINOX)), 0, 1e-9),
        ` — ${deg(SKY.solarDec(SEP_EQUINOX)).toFixed(2)}°`);
  // The axial tilt IS the extreme — the solstice declination is not a separate
  // constant, it is 23.44° falling out of the same sine.
  check("at the June solstice it reaches the axial tilt, north",
        near(deg(SKY.solarDec(JUN_SOLSTICE)), 23.44, 1e-9),
        ` — ${deg(SKY.solarDec(JUN_SOLSTICE)).toFixed(2)}°`);
  check("at the December solstice, the same tilt south",
        near(deg(SKY.solarDec(DEC_SOLSTICE)), -23.44, 1e-9),
        ` — ${deg(SKY.solarDec(DEC_SOLSTICE)).toFixed(2)}°`);
  check("declination never leaves the tropics",
        [...Array(365).keys()].every(d => Math.abs(deg(SKY.solarDec(d))) <= 23.45));
}

// ── altitude: the formula's fixed points ───────────────────────────────────
{
  at(0);
  check("on the equator at an equinox, the noon sun is overhead",
        near(SKY.sunAltDeg(12, MAR_EQUINOX), 90, 1e-9),
        ` — ${SKY.sunAltDeg(12, MAR_EQUINOX).toFixed(2)}°`);
  check("…and at midnight it is as far below",
        near(SKY.sunAltDeg(0, MAR_EQUINOX), -90, 1e-9));

  at(52.5);   // Berlin
  check("noon is always higher than midnight",
        SKY.sunAltDeg(12, JUN_SOLSTICE) > SKY.sunAltDeg(0, JUN_SOLSTICE));
  check("midsummer noon stands higher than midwinter noon",
        SKY.sunAltDeg(12, JUN_SOLSTICE) > SKY.sunAltDeg(12, DEC_SOLSTICE));
  // 90 − latitude + declination is the textbook noon altitude
  check("noon altitude is 90° − φ + δ",
        near(SKY.sunAltDeg(12, JUN_SOLSTICE), 90 - 52.5 + 23.44, 1e-9),
        ` — ${SKY.sunAltDeg(12, JUN_SOLSTICE).toFixed(2)}°`);
  check("the day is symmetric about noon",
        near(SKY.sunAltDeg(9, JUN_SOLSTICE), SKY.sunAltDeg(15, JUN_SOLSTICE), 1e-9));
}

// ── sunrise and sunset ─────────────────────────────────────────────────────
{
  at(52.5);
  const jun = SKY.sunFor(JUN_SOLSTICE), dec = SKY.sunFor(DEC_SOLSTICE);
  check("rise and set straddle noon", jun.rise < 12 && jun.set > 12);
  check("they are symmetric about it", near(12 - jun.rise, jun.set - 12, 1e-9));
  check("the midsummer day is the longer one",
        (jun.set - jun.rise) > (dec.set - dec.rise),
        ` — ${(jun.set - jun.rise).toFixed(2)} h vs ${(dec.set - dec.rise).toFixed(2)} h`);
  // Berlin's real solstice daylight is about 16h50m; the formula ignores
  // refraction and the sun's disc, so it lands a little short — and that is the
  // honest geometric answer, not an error to fudge toward the almanac.
  check("midsummer in Berlin is about sixteen and a half hours",
        near(jun.set - jun.rise, 16.5, 0.6),
        ` — ${(jun.set - jun.rise).toFixed(2)} h`);

  at(0);
  const eq = SKY.sunFor(MAR_EQUINOX);
  check("on the equator the day is twelve hours", near(eq.set - eq.rise, 12, 0.05));
  // THE CLAIM WORTH PINNING: at an equinox the sun rises due east, from
  // everywhere on earth. It is the one bearing that does not depend on latitude.
  check("at an equinox the sun rises due east", near(eq.azRise, 90, 1e-9),
        ` — ${eq.azRise.toFixed(2)}°`);
  check("…and sets due west", near(eq.azSet, 270, 1e-9));
  at(52.5);
  const berlinEq = SKY.sunFor(MAR_EQUINOX);
  check("…and that is true at every latitude", near(berlinEq.azRise, 90, 1e-9),
        ` — ${berlinEq.azRise.toFixed(2)}° at 52.5°N`);

  at(52.5);
  check("in midsummer the sun rises north of east", SKY.sunFor(JUN_SOLSTICE).azRise < 90);
  check("in midwinter it rises south of east", SKY.sunFor(DEC_SOLSTICE).azRise > 90);
}

// ── the poles: no answer is the answer ─────────────────────────────────────
{
  at(78);   // Svalbard
  const midwinter = SKY.sunFor(DEC_SOLSTICE), midsummer = SKY.sunFor(JUN_SOLSTICE);
  check("polar night has no sunrise to report", midwinter.rise === undefined);
  check("polar day has no sunset to report", midsummer.set === undefined);
  check("…and both answer an empty object, not a made-up hour",
        Object.keys(midwinter).length === 0 && Object.keys(midsummer).length === 0);
  // altitude still answers there — the sun has a position even when it does not
  // cross the horizon, and that is what keeps the sky ring paintable
  check("the sky is still lit through a polar day",
        SKY.sunAltDeg(0, JUN_SOLSTICE) > 0 && SKY.sunAltDeg(12, JUN_SOLSTICE) > 0);
  check("…and dark right through a polar night",
        SKY.sunAltDeg(0, DEC_SOLSTICE) < 0 && SKY.sunAltDeg(12, DEC_SOLSTICE) < 0);

  at(66.6);   // just inside the Arctic circle
  check("the Arctic circle is where midsummer stops setting",
        SKY.sunFor(JUN_SOLSTICE).set === undefined);
  at(66.0);
  check("…and just outside it, the sun still sets",
        SKY.sunFor(JUN_SOLSTICE).set !== undefined);
}

// ── weather: clear, not guessed ────────────────────────────────────────────
{
  const w = SKY.weatherAt(14);
  check("with no readings and no demo flag, the sky is clear",
        w.cloud === 0 && w.precip === 0);
}

done();
