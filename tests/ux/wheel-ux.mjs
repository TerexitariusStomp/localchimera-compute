/// tests/ux/wheel-ux.mjs — the wheel (app/wheel.js) and its temporal readings
/// (app/rhythm.js). The band click that descends and the centre disc that
/// rises are the wheel's OWN navigation, distinct from the priority bar's;
/// hovering reads a need's rhythm into the glyph and its caption; alt+click is
/// the folksonomy tweak arm, lifting a term for re-nesting; and the priority ⇄
/// spend toggle morphs the same wheel into its credit-flow denomination, where
/// the readout is in embodied-hours per clock-hour.
import { harness, launch, summarize, sleep } from './ux-harness.mjs';
import { serveBrowser } from './ux-serve.mjs';
const { base: BASE, close: closeServer } = await serveBrowser();
const h=harness(); const browser=await launch(); const page=await browser.newPage();
const errs=[]; page.on('pageerror',e=>errs.push(String(e)));
await page.goto(`${BASE}/app.html?face=time`,{waitUntil:'networkidle'}); await sleep(1400);

const labels=()=>page.evaluate(()=>[...document.querySelectorAll('#prioritybar .pribar.current .priseg .pl')].map(n=>n.textContent.trim()));
const bandCount=()=>page.evaluate(()=>document.querySelectorAll('#dial g.clickable').length);
h.rec('the wheel draws clickable bands', await bandCount() > 0, `n=${await bandCount()}`);

// hover a band → the rhythm glyph and its caption fill in
const band = await page.$('#dial g.clickable');
const b = await band.boundingBox();
await page.mouse.move(b.x + b.width*0.5, b.y + b.height*0.2);
await sleep(500);
const cap = await page.evaluate(()=>(document.getElementById('rcap')||{}).textContent||'');
const glyph = await page.evaluate(()=>document.querySelectorAll('#rglyph *').length);
h.rec('hovering a band reads its rhythm', cap.length>0 && glyph>0, `${glyph} marks · ${cap.slice(0,60)}`);

// click a band → the dial descends (the bar gains an ancestor row)
const before = (await labels()).join('|');
await page.mouse.click(b.x + b.width*0.5, b.y + b.height*0.2);
await sleep(1600);
const rows = await page.evaluate(()=>document.querySelectorAll('#prioritybar .pribar').length);
h.rec('clicking a band descends the wheel', rows===2 && (await labels()).join('|')!==before,
      `rows=${rows} ${(await labels()).join(' ')}`);

// the centre disc rises back out
const cd = await page.evaluate(()=>{const r=document.getElementById('dial').getBoundingClientRect();
  return {x:r.x+r.width/2,y:r.y+r.height/2};});
await page.mouse.click(cd.x, cd.y);
await sleep(1600);
h.rec('the centre disc rises one level',
      (await page.evaluate(()=>document.querySelectorAll('#prioritybar .pribar').length))===1);

// alt+click grabs a term (the spine tweak): the band lifts to half opacity
await page.keyboard.down('Alt');
await page.mouse.click(b.x + b.width*0.5, b.y + b.height*0.2);
await page.keyboard.up('Alt');
await sleep(700);
const lifted = await page.evaluate(()=>[...document.querySelectorAll('#dial g')]
  .filter(g=>g.style.opacity==='0.55').length);
h.rec('alt+click lifts a term for re-nesting', lifted===1, `lifted=${lifted}`);
await page.keyboard.press('Escape'); await sleep(700);
h.rec('escape puts it back',
      (await page.evaluate(()=>[...document.querySelectorAll('#dial g')].filter(g=>g.style.opacity==='0.55').length))===0);

// the spend wheel morphs
await page.evaluate(()=>document.getElementById('spendqty')?.dispatchEvent(new MouseEvent('click',{bubbles:true})));
await sleep(1400);
const flow = await page.evaluate(()=>(document.getElementById('spendflow')||{}).textContent||'');
h.rec('the spend wheel reads a flow', /h∕h now/.test(flow), JSON.stringify(flow));
await page.evaluate(()=>document.getElementById('spendpri')?.dispatchEvent(new MouseEvent('click',{bubbles:true})));
await sleep(1400);
h.rec('priority mode blanks it',
      (await page.evaluate(()=>(document.getElementById('spendflow')||{}).textContent||''))==='');
h.rec('no page errors', errs.length===0, errs.slice(0,2).join(' | '));
await browser.close(); closeServer(); summarize(h);
