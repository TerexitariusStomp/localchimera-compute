export interface Expressor {
  id: string;
  name: string;
  publicKey: string;
  color: string;
  position: [number, number, number];
}

export interface Binding {
  name: string;
  value: any;
  version: number;
  expressor: string;
}

export interface HistoryEntry {
  version: number;
  expressor: string;
  expression: string;
  parent: number;
}

export type ValidatorFn = (
  expressor: string,
  name: string,
  value: any,
  oldEnv: Environment,
  newEnv: Environment
) => boolean;

export interface Environment {
  bindings: Map<string, Binding>;
  expressors: Map<string, Expressor>;
  validator: ValidatorFn | null;
  history: HistoryEntry[];
  currentExpressor: string;
  version: number;
}

export type Expression =
  | { type: 'literal'; value: any }
  | { type: 'symbol'; name: string }
  | { type: 'quote'; value: any }
  | { type: 'modify'; name: string; value: any }
  | { type: 'defexpressor'; name: string; publicKey: string }
  | { type: 'as'; expressor: string; expr: Expression }
  | { type: 'enact'; validator: string }
  | { type: 'show-history' }
  | { type: 'show-expressors' };
