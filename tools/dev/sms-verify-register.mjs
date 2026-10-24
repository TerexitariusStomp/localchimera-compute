#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-or-later
/// tools/dev/sms-verify-register.mjs — Playwright account registration via SMS code
///
/// Two modes:
///   1. Standalone: runs sms-verify as subprocess, auto-discovers code
///      $ node tools/dev/sms-verify-register.mjs --service telegram --country 12
///
///   2. Manual code entry (code already retrieved):
///      $ node tools/dev/sms-verify-register.mjs --phone +1234567890 --code 123456 --service telegram
///
/// Requires: node, playwright (or playwright-core), ungoogled-chromium

import { chromium } from 'playwright-core';

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ── CLI parsing ──────────────────────────────────────────────────────────

const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith('--')) {
    const k = a.slice(2);
    const v = process.argv[i + 1];
    if (v && !v.startsWith('--')) { args[k] = v; i++; }
    else { args[k] = true; }
  }
}

function usage() {
  console.log(`
Usage: sms-verify-register.mjs [OPTIONS]

Options:
  --service SERVICE    Target service: telegram, signal, whatsapp (required)
  --phone NUMBER       Phone number (if already purchased)
  --code CODE          SMS verification code (if already retrieved)
  --country ID         Country ID for sms-verify (e.g. 12 = USA)
  --amount USD         Amount for sms-verify (default: 1.00)
  --sms-verify PATH    Path to sms-verify script (default: ./sms-verify.scm)
  --wallet-rpc-password-file PATH  Monero wallet password file
  --manual             Don't auto-pay, print address for manual send
  --browser-path PATH  Chromium executable path
  --gui                Show browser (non-headless)
  -h, --help           Show this help
`);
  process.exit(0);
}

if (args['help'] || args['h']) usage();
if (!args['service']) { console.error('error: --service is required'); usage(); }

// ── SMS code retrieval via sms-verify ─────────────────────────────────────

async function retrieveCode() {
  const smsVerify = args['sms-verify'] || 'tools/dev/sms-verify.scm';
  const country   = args['country']   || '12';
  const amount    = args['amount']    || '1.00';

  // Build the sms-verify command
  const cmdArgs = ['--no-auto-compile', '-L', 'module', smsVerify,
    '--service', args.service,
    '--country', country,
    '--amount', amount];

  if (args['wallet-rpc-password-file']) {
    cmdArgs.push('--wallet-rpc-password-file', args['wallet-rpc-password-file']);
  } else if (!args['manual']) {
    // Default to localchimera's password file
    cmdArgs.push('--wallet-rpc-password-file', '/var/lib/localchimera/monero/rpc-login.txt');
  } else {
    cmdArgs.push('--manual');
  }

  console.log(`\nRunning: guile ${cmdArgs.join(' ')}\n`);

  const { execSync } = await import('child_process');
  const output = execSync('guile', cmdArgs, { timeout: 600000 }); // 10 min
  const text = output.toString();

  const phoneMatch = text.match(/Phone:\s*([^\s]+)/);
  const codeMatch  = text.match(/Code:\s*(\S+)/);

  if (!phoneMatch || !codeMatch) {
    console.error('Failed to parse sms-verify output:', text);
    process.exit(1);
  }

  return { phone: phoneMatch[1], code: codeMatch[1] };
}

// ── Account registration per service ──────────────────────────────────────

async function registerTelegram(page, phone, code) {
  console.log(`Registering Telegram with phone: ${phone}`);
  await page.goto('https://web.telegram.org/k/');

  // Wait for phone input
  await page.waitForSelector('input[type="text"]', { timeout: 15000 });
  await sleep(2000);

  // Enter phone number
  const inputs = await page.locator('input[type="text"]').all();
  if (inputs.length > 0) {
    // Strip + prefix for Telegram
    const cleanPhone = phone.replace(/^\+/, '');
    await inputs[0].fill(cleanPhone);
    console.log('  entered phone number');
  }

  // Click the country-select -> next button
  const nextBtn = page.locator('button:has-text("Next")');
  if (await nextBtn.count() > 0) {
    await nextBtn.click();
    console.log('  clicked Next');
  }

  // Wait for code input
  console.log('  waiting for code input...');
  await sleep(5000);

  const codeInput = page.locator('input[type="text"]').first();
  if (await codeInput.count() > 0) {
    await codeInput.fill(code);
    console.log(`  entered code: ${code}`);
  }

  await sleep(3000);
  console.log('Telegram registration attempt complete');
}

async function registerSignal(page, phone, code) {
  console.log(`Registering Signal via https://signal.me/`);
  console.log('Signal Web does not support direct registration. Use the desktop app.');
  console.log(`Phone: ${phone}, Code: ${code}`);
}

async function registerWhatsApp(page, phone, code) {
  console.log(`Registering WhatsApp with phone: ${phone}`);
  await page.goto('https://web.whatsapp.com/');

  // WhatsApp Web shows a QR code for existing users.
  // For registration, we'd need to use the desktop app or an API.
  console.log('WhatsApp Web requires QR scan from mobile app.');
  console.log(`Phone: ${phone}, Code: ${code}`);
}

// ── Main ──────────────────────────────────────────────────────────────────

async function main() {
  // 1. Get phone + code
  let phone = args['phone'];
  let code  = args['code'];

  if (!phone || !code) {
    const result = await retrieveCode();
    phone = result.phone;
    code  = result.code;
  }

  console.log(`\nUsing phone: ${phone}, code: ${code}\n`);

  // 2. Launch browser
  const browserOpts = { headless: !args['gui'] };
  if (args['browser-path']) browserOpts.executablePath = args['browser-path'];
  if (process.env.CHROMIUM_PATH) browserOpts.executablePath = process.env.CHROMIUM_PATH;

  const browser = await chromium.launch(browserOpts);
  const page = await browser.newPage();
  page.on('console', m => console.log('  [browser]', m.text()));

  try {
    // 3. Run the service-specific registration
    switch (args.service) {
      case 'telegram':
        await registerTelegram(page, phone, code);
        break;
      case 'signal':
        await registerSignal(page, phone, code);
        break;
      case 'whatsapp':
        await registerWhatsApp(page, phone, code);
        break;
      default:
        console.error(`Unknown service: ${args.service}`);
        console.log(`Phone: ${phone}, Code: ${code}`);
    }

    if (args['gui']) {
      console.log('Press Ctrl+C to exit (GUI mode keeps browser open)');
      await sleep(60000);
    }
  } catch (e) {
    console.error('Registration error:', e.message);
    console.log(`Phone: ${phone}, Code: ${code}`);
  } finally {
    await browser.close();
  }
}

main().catch(e => {
  console.error('Fatal:', e);
  process.exit(1);
});
