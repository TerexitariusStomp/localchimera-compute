import type { Expression } from './types';

export function parse(input: string): Expression {
  const tokens = tokenize(input);
  const [expr] = parseExpression(tokens, 0);
  return expr;
}

function tokenize(input: string): string[] {
  return input
    .replace(/\(/g, ' ( ')
    .replace(/\)/g, ' ) ')
    .replace(/'/g, " ' ")
    .split(/\s+/)
    .filter(t => t.length > 0);
}

function parseExpression(tokens: string[], index: number): [Expression, number] {
  if (tokens[index] === '(') {
    return parseList(tokens, index + 1);
  } else if (tokens[index] === "'") {
    const [value, nextIndex] = parseExpression(tokens, index + 1);
    return [{ type: 'quote', value }, nextIndex];
  } else {
    return parseLiteral(tokens[index], index + 1);
  }
}

function parseList(tokens: string[], index: number): [Expression, number] {
  const elements: Expression[] = [];
  let i = index;

  while (tokens[i] !== ')') {
    const [expr, nextIndex] = parseExpression(tokens, i);
    elements.push(expr);
    i = nextIndex;
  }

  i++; // skip ')'

  if (elements.length === 0) {
    return [{ type: 'literal', value: [] }, i];
  }

  const first = elements[0];

  if (first.type === 'symbol') {
    switch (first.name) {
      case 'modify!':
        if (elements.length !== 3) throw new Error('modify! requires 2 arguments');
        const name = elements[1].type === 'quote'
          ? (elements[1].value as any).name
          : (elements[1] as any).name;
        return [{ type: 'modify', name, value: elements[2] }, i];

      case 'defexpressor':
        if (elements.length !== 3) throw new Error('defexpressor requires 2 arguments');
        const expName = elements[1].type === 'quote'
          ? (elements[1].value as any).name
          : (elements[1] as any).name;
        const key = (elements[2] as any).value || (elements[2] as any).name;
        return [{ type: 'defexpressor', name: expName, publicKey: key }, i];

      case 'as':
        if (elements.length !== 3) throw new Error('as requires 2 arguments');
        const exp = (elements[1] as any).name;
        return [{ type: 'as', expressor: exp, expr: elements[2] }, i];

      case 'enact!':
        if (elements.length !== 2) throw new Error('enact! requires 1 argument');
        return [{ type: 'enact', validator: 'custom' }, i];

      case 'show-history':
        return [{ type: 'show-history' }, i];

      case 'show-expressors':
        return [{ type: 'show-expressors' }, i];
    }
  }

  return [{ type: 'literal', value: elements }, i];
}

function parseLiteral(token: string, nextIndex: number): [Expression, number] {
  if (token === '#t') {
    return [{ type: 'literal', value: true }, nextIndex];
  } else if (token === '#f') {
    return [{ type: 'literal', value: false }, nextIndex];
  } else if (!isNaN(Number(token))) {
    return [{ type: 'literal', value: Number(token) }, nextIndex];
  } else if (token.startsWith('"') && token.endsWith('"')) {
    return [{ type: 'literal', value: token.slice(1, -1) }, nextIndex];
  } else {
    return [{ type: 'symbol', name: token }, nextIndex];
  }
}
