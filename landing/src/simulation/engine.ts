import type { Environment, Expressor, Binding, ValidatorFn, Expression } from './types';
import { parse } from './parser';

const EXPRESSOR_COLORS = [
  '#00d9ff', // electric blue
  '#a855f7', // vibrant purple
  '#ff6b35', // warm orange
  '#10b981', // green
  '#f59e0b', // amber
];

let colorIndex = 0;

export function makeInitialEnv(initialBindings: Record<string, any> = {}): Environment {
  const bindings = new Map<string, Binding>();

  for (const [name, value] of Object.entries(initialBindings)) {
    bindings.set(name, {
      name,
      value,
      version: 0,
      expressor: 'genesis'
    });
  }

  const expressors = new Map<string, Expressor>();
  expressors.set('genesis', {
    id: 'genesis',
    name: 'genesis',
    publicKey: 'genesis-key',
    color: '#64748b',
    position: [0, 0, 0]
  });

  return {
    bindings,
    expressors,
    validator: null,
    history: [{
      version: 0,
      expressor: 'genesis',
      expression: '(quote initial)',
      parent: 0
    }],
    currentExpressor: 'genesis',
    version: 0
  };
}

export function evaluate(input: string, env: Environment): Environment {
  try {
    const expr = parse(input);
    return evaluateExpression(expr, env, input);
  } catch (error) {
    throw new Error(`Parse error: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function evaluateExpression(expr: Expression, env: Environment, originalExpr: string): Environment {
  switch (expr.type) {
    case 'literal':
    case 'quote':
      return env;

    case 'symbol':
      const binding = env.bindings.get(expr.name);
      if (!binding) throw new Error(`Unbound symbol: ${expr.name}`);
      return env;

    case 'modify':
      return evaluateModify(expr.name, expr.value, env, originalExpr);

    case 'defexpressor':
      return evaluateDefexpressor(expr.name, expr.publicKey, env, originalExpr);

    case 'as':
      return evaluateAs(expr.expressor, expr.expr, env, originalExpr);

    case 'enact':
      return evaluateEnact(env, originalExpr);

    case 'show-history':
    case 'show-expressors':
      return env;

    default:
      throw new Error(`Unknown expression type: ${(expr as any).type}`);
  }
}

function evaluateModify(name: string, valueExpr: Expression, env: Environment, originalExpr: string): Environment {
  const value = extractValue(valueExpr, env);

  const newBindings = new Map(env.bindings);
  const newBinding: Binding = {
    name,
    value,
    version: env.version + 1,
    expressor: env.currentExpressor
  };

  const newEnv: Environment = {
    ...env,
    bindings: newBindings,
    version: env.version + 1
  };

  newBindings.set(name, newBinding);

  if (env.validator) {
    const oldEnv = env;
    const isValid = env.validator(env.currentExpressor, name, value, oldEnv, newEnv);
    if (!isValid) {
      throw new Error(`Validation failed for ${name} = ${JSON.stringify(value)}`);
    }
  }

  const newHistory = [...env.history, {
    version: env.version + 1,
    expressor: env.currentExpressor,
    expression: originalExpr,
    parent: env.version
  }];

  return {
    ...newEnv,
    history: newHistory
  };
}

function evaluateDefexpressor(name: string, publicKey: string, env: Environment, originalExpr: string): Environment {
  if (env.expressors.has(name)) {
    throw new Error(`Expressor ${name} already exists`);
  }

  const color = EXPRESSOR_COLORS[colorIndex % EXPRESSOR_COLORS.length];
  colorIndex++;

  const angle = (env.expressors.size * Math.PI * 2) / 8;
  const radius = 3;
  const position: [number, number, number] = [
    Math.cos(angle) * radius,
    Math.sin(angle) * radius,
    0
  ];

  const newExpressor: Expressor = {
    id: name,
    name,
    publicKey,
    color,
    position
  };

  const newExpressors = new Map(env.expressors);
  newExpressors.set(name, newExpressor);

  const newHistory = [...env.history, {
    version: env.version + 1,
    expressor: env.currentExpressor,
    expression: originalExpr,
    parent: env.version
  }];

  return {
    ...env,
    expressors: newExpressors,
    history: newHistory,
    version: env.version + 1
  };
}

function evaluateAs(expressor: string, expr: Expression, env: Environment, originalExpr: string): Environment {
  if (!env.expressors.has(expressor)) {
    throw new Error(`Unknown expressor: ${expressor}`);
  }

  const newEnv = { ...env, currentExpressor: expressor };
  return evaluateExpression(expr, newEnv, originalExpr);
}

function evaluateEnact(env: Environment, originalExpr: string): Environment {
  const newValidator: ValidatorFn = (_expressor, _name, value) => {
    return typeof value === 'number';
  };

  const testEnv: Environment = {
    ...env,
    validator: newValidator
  };

  if (env.validator) {
    const isValid = env.validator(env.currentExpressor, '_validator', newValidator, env, testEnv);
    if (!isValid) {
      throw new Error('New validator rejected by current validator');
    }
  }

  const newHistory = [...env.history, {
    version: env.version + 1,
    expressor: env.currentExpressor,
    expression: originalExpr,
    parent: env.version
  }];

  return {
    ...testEnv,
    history: newHistory,
    version: env.version + 1
  };
}

function extractValue(expr: Expression, env: Environment): any {
  switch (expr.type) {
    case 'literal':
      return expr.value;
    case 'quote':
      return extractValue(expr.value as Expression, env);
    case 'symbol':
      const binding = env.bindings.get(expr.name);
      if (!binding) throw new Error(`Unbound symbol: ${expr.name}`);
      return binding.value;
    default:
      return expr;
  }
}
