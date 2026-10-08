// tests/browser/palette-tokens-test.mjs — every --t-XXXXXX token app.html's
// stylesheet REFERENCES (var(--t-XXXXXX)) must also be DECLARED somewhere in
// a :root block, or theme.js's readTokens() (which only walks declared
// :root custom properties, browser/app/theme.js) never learns the token
// exists — the day/night remap it does for every OTHER color silently
// skips it, and if the token has no static fallback either the whole
// declaration that references it is invalid and simply does nothing.
//
// The real bug this caught: #logmic.rec / #sbmic.rec referenced
// var(--t-fde8e4) as a background fill, but --t-fde8e4 was never declared
// in the static :root block — the mic button's "you're recording" tint
// silently never painted (verified live: adding the .rec class changed
// nothing about the rendered background), while the border-color half of
// the same rule (a real, declared token) still worked, making the bug easy
// to miss by eye.
//
// Run: node tests/browser/palette-tokens-test.mjs

import { readFileSync } from 'node:fs';

import { harness } from './assert.mjs';
const { check, done } = harness();

const html = readFileSync(new URL('../../browser/app.html', import.meta.url), 'utf8');

const used = new Set([...html.matchAll(/var\(--t-([0-9a-f]{6})\)/g)].map(m => m[1]));
const declared = new Set([...html.matchAll(/--t-([0-9a-f]{6}):\s*#[0-9a-f]{6}/gi)].map(m => m[1]));

const dangling = [...used].filter(t => !declared.has(t));

check(`every --t-XXXXXX token var()-referenced in app.html is declared somewhere in :root (${used.size} referenced, ${declared.size} declared)`,
      dangling.length === 0, dangling.map(t => `--t-${t}`).join(', '));

done();
