// Minimal s-expression reader.
//
// Corpus manifests and domain profiles are written in Scheme so that the
// planner side (Guile) and the ingest side (Node) read the SAME file. This
// reader covers the subset those files use: lists, strings, symbols, numbers,
// keywords (#:foo), booleans, quote, and ; comments.

const DELIM = new Set([...'()"; \t\n\r']);

export function readAll(text) {
  const s = { text, i: 0 };
  const forms = [];
  for (;;) {
    skipAtmosphere(s);
    if (s.i >= text.length) return forms;
    forms.push(readForm(s));
  }
}

function skipAtmosphere(s) {
  for (;;) {
    while (s.i < s.text.length && /\s/.test(s.text[s.i])) s.i++;
    if (s.text[s.i] === ';') {
      while (s.i < s.text.length && s.text[s.i] !== '\n') s.i++;
      continue;
    }
    // #| block comment |#
    if (s.text.startsWith('#|', s.i)) {
      const end = s.text.indexOf('|#', s.i + 2);
      s.i = end === -1 ? s.text.length : end + 2;
      continue;
    }
    return;
  }
}

function readForm(s) {
  skipAtmosphere(s);
  const c = s.text[s.i];
  if (c === undefined) throw new Error('unexpected end of input');
  if (c === '(' || c === '[') return readList(s, c === '(' ? ')' : ']');
  if (c === ')' || c === ']') throw new Error(`unbalanced ${c} at ${s.i}`);
  if (c === '"') return readString(s);
  if (c === "'") { s.i++; return { quote: readForm(s) }; }
  return readAtom(s);
}

function readList(s, close) {
  s.i++; // opening paren
  const items = [];
  for (;;) {
    skipAtmosphere(s);
    const c = s.text[s.i];
    if (c === undefined) throw new Error('unterminated list');
    if (c === close || c === ')' || c === ']') { s.i++; return items; }
    items.push(readForm(s));
  }
}

function readString(s) {
  s.i++; // opening quote
  let out = '';
  for (;;) {
    const c = s.text[s.i];
    if (c === undefined) throw new Error('unterminated string');
    if (c === '"') { s.i++; return out; }
    if (c === '\\') {
      const esc = s.text[s.i + 1];
      out += esc === 'n' ? '\n' : esc === 't' ? '\t' : esc;
      s.i += 2;
      continue;
    }
    out += c;
    s.i++;
  }
}

function readAtom(s) {
  const start = s.i;
  while (s.i < s.text.length && !DELIM.has(s.text[s.i])) s.i++;
  const tok = s.text.slice(start, s.i);
  if (tok === '#t' || tok === '#true') return true;
  if (tok === '#f' || tok === '#false') return false;
  if (tok.startsWith('#:')) return { keyword: tok.slice(2) };
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(tok)) return Number(tok);
  return { symbol: tok };
}

// ---- accessors over the parsed shape -------------------------------------

export const isSymbol = (x, name) =>
  x !== null && typeof x === 'object' && 'symbol' in x &&
  (name === undefined || x.symbol === name);

export const symbolName = (x) => (isSymbol(x) ? x.symbol : null);

/** Value of a (key value ...) entry inside an alist-style form. */
export function field(form, key) {
  for (const item of form) {
    if (Array.isArray(item) && isSymbol(item[0], key)) {
      return item.length === 2 ? item[1] : item.slice(1);
    }
  }
  return undefined;
}

/** All (key ...) entries with the given head symbol. */
export function fields(form, key) {
  return form.filter((item) => Array.isArray(item) && isSymbol(item[0], key));
}

/** Strip {symbol}/{quote} wrappers down to plain JS where unambiguous. */
export function plain(x) {
  if (Array.isArray(x)) return x.map(plain);
  if (x !== null && typeof x === 'object') {
    if ('symbol' in x) return x.symbol;
    if ('keyword' in x) return x.keyword;
    if ('quote' in x) return plain(x.quote);
  }
  return x;
}
