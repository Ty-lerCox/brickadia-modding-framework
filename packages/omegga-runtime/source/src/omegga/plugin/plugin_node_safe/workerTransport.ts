import { Buffer } from 'node:buffer';

export interface WorkerTransportLimits {
  maxDepth: number;
  maxNodes: number;
  maxBytes: number;
}

export const DEFAULT_WORKER_TRANSPORT_LIMITS: WorkerTransportLimits =
  Object.freeze({
    maxDepth: 32,
    maxNodes: 16_384,
    maxBytes: 1024 * 1024,
  });

const INTEROP_KIND = 'omegga.plugin-interop.result';
const INTEROP_VERSION = 1;
const NODE_OVERHEAD_BYTES = 8;
const MAX_ERROR_NAME_CHARS = 128;
const MAX_ERROR_MESSAGE_CHARS = 2048;
const MAX_ERROR_CODE_CHARS = 128;

export class WorkerTransportError extends Error {
  code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'WorkerTransportError';
    this.code = code;
  }
}

export interface PluginInteropErrorData {
  name: string;
  message: string;
  code?: string;
}

export type PluginInteropWireResult =
  | {
      kind: typeof INTEROP_KIND;
      version: typeof INTEROP_VERSION;
      ok: true;
      value: unknown;
    }
  | {
      kind: typeof INTEROP_KIND;
      version: typeof INTEROP_VERSION;
      ok: false;
      error: PluginInteropErrorData;
    };

interface CloneState {
  limits: WorkerTransportLimits;
  nodes: number;
  bytes: number;
  seen: WeakMap<object, unknown>;
}

function normalizedLimit(value: number, fallback: number, minimum: number) {
  return Number.isFinite(value)
    ? Math.max(minimum, Math.floor(value))
    : fallback;
}

function normalizeLimits(
  limits: Partial<WorkerTransportLimits> = {},
): WorkerTransportLimits {
  return {
    maxDepth: normalizedLimit(
      Number(limits.maxDepth),
      DEFAULT_WORKER_TRANSPORT_LIMITS.maxDepth,
      0,
    ),
    maxNodes: normalizedLimit(
      Number(limits.maxNodes),
      DEFAULT_WORKER_TRANSPORT_LIMITS.maxNodes,
      1,
    ),
    maxBytes: normalizedLimit(
      Number(limits.maxBytes),
      DEFAULT_WORKER_TRANSPORT_LIMITS.maxBytes,
      1,
    ),
  };
}

function consumeNode(state: CloneState) {
  state.nodes += 1;
  if (state.nodes > state.limits.maxNodes) {
    throw new WorkerTransportError(
      'TRANSPORT_NODE_LIMIT',
      `Plugin interop result exceeds ${state.limits.maxNodes} transport nodes.`,
    );
  }
  consumeBytes(state, NODE_OVERHEAD_BYTES);
}

function consumeBytes(state: CloneState, bytes: number) {
  state.bytes += Math.max(0, bytes);
  if (state.bytes > state.limits.maxBytes) {
    throw new WorkerTransportError(
      'TRANSPORT_BYTE_LIMIT',
      `Plugin interop result exceeds ${state.limits.maxBytes} transport bytes.`,
    );
  }
}

function consumeString(state: CloneState, value: string) {
  if (value.length > state.limits.maxBytes - state.bytes) {
    consumeBytes(state, value.length);
    return;
  }
  consumeBytes(state, Buffer.byteLength(value, 'utf8'));
}

function inspectObject(value: object) {
  let keys: (string | symbol)[];
  let prototype: object | null;
  try {
    keys = Reflect.ownKeys(value);
    prototype = Reflect.getPrototypeOf(value);
  } catch {
    throw new WorkerTransportError(
      'TRANSPORT_INSPECTION_FAILED',
      'Plugin interop result could not be safely inspected.',
    );
  }

  const descriptors = new Map<string, PropertyDescriptor>();
  for (const key of keys) {
    if (typeof key === 'symbol') {
      throw new WorkerTransportError(
        'TRANSPORT_SYMBOL_UNSUPPORTED',
        'Plugin interop results cannot contain symbol properties.',
      );
    }

    let descriptor: PropertyDescriptor | undefined;
    try {
      descriptor = Reflect.getOwnPropertyDescriptor(value, key);
    } catch {
      throw new WorkerTransportError(
        'TRANSPORT_INSPECTION_FAILED',
        'Plugin interop result properties could not be safely inspected.',
      );
    }
    if (!descriptor) {
      throw new WorkerTransportError(
        'TRANSPORT_UNSTABLE_OBJECT',
        'Plugin interop result changed while it was being inspected.',
      );
    }
    if ('get' in descriptor || 'set' in descriptor) {
      throw new WorkerTransportError(
        'TRANSPORT_ACCESSOR_UNSUPPORTED',
        `Plugin interop property ${JSON.stringify(key)} is an accessor.`,
      );
    }
    descriptors.set(key, descriptor);
  }

  return { descriptors, prototype };
}

function constructorName(prototype: object | null) {
  if (prototype === null) return 'Object';
  try {
    const descriptor = Reflect.getOwnPropertyDescriptor(
      prototype,
      'constructor',
    );
    if (descriptor && 'value' in descriptor) {
      const constructor = descriptor.value;
      if (typeof constructor === 'function') {
        return String(constructor.name || 'anonymous');
      }
    }
  } catch {
    // The caller reports the resulting unknown object type deterministically.
  }
  return 'unknown';
}

function defineTransportProperty(
  target: object,
  key: string,
  value: unknown,
) {
  Object.defineProperty(target, key, {
    configurable: true,
    enumerable: true,
    writable: true,
    value,
  });
}

function cloneTransportValue(
  value: unknown,
  state: CloneState,
  depth: number,
): unknown {
  if (depth > state.limits.maxDepth) {
    throw new WorkerTransportError(
      'TRANSPORT_DEPTH_LIMIT',
      `Plugin interop result exceeds transport depth ${state.limits.maxDepth}.`,
    );
  }

  consumeNode(state);
  if (value === null) {
    consumeBytes(state, 1);
    return null;
  }

  switch (typeof value) {
    case 'undefined':
      consumeBytes(state, 1);
      return undefined;
    case 'boolean':
      consumeBytes(state, 1);
      return value;
    case 'number':
      consumeBytes(state, 8);
      return value;
    case 'bigint': {
      const encoded = value.toString();
      consumeString(state, encoded);
      return value;
    }
    case 'string':
      consumeString(state, value);
      return value;
    case 'symbol':
      throw new WorkerTransportError(
        'TRANSPORT_SYMBOL_UNSUPPORTED',
        'Plugin interop results cannot contain symbols.',
      );
    case 'function':
      throw new WorkerTransportError(
        'TRANSPORT_FUNCTION_UNSUPPORTED',
        'Plugin interop results cannot contain functions.',
      );
  }

  const objectValue = value as object;
  const existing = state.seen.get(objectValue);
  if (existing !== undefined) return existing;

  const { descriptors, prototype } = inspectObject(objectValue);
  if (Array.isArray(objectValue)) {
    const length = Number(descriptors.get('length')?.value ?? 0);
    if (
      !Number.isSafeInteger(length) ||
      length < 0 ||
      length > state.limits.maxNodes
    ) {
      throw new WorkerTransportError(
        'TRANSPORT_NODE_LIMIT',
        `Plugin interop array length exceeds ${state.limits.maxNodes}.`,
      );
    }

    const clone: unknown[] = new Array(length);
    state.seen.set(objectValue, clone);
    for (const [key, descriptor] of descriptors) {
      if (key === 'length' || !descriptor.enumerable) continue;
      consumeString(state, key);
      consumeBytes(state, 4);
      defineTransportProperty(
        clone,
        key,
        cloneTransportValue(descriptor.value, state, depth + 1),
      );
    }
    return clone;
  }

  const typeName = constructorName(prototype);
  if (typeName !== 'Object') {
    throw new WorkerTransportError(
      'TRANSPORT_TYPE_UNSUPPORTED',
      `Plugin interop object type ${typeName} is not supported.`,
    );
  }

  const clone: Record<string, unknown> = {};
  state.seen.set(objectValue, clone);
  for (const [key, descriptor] of descriptors) {
    if (!descriptor.enumerable) continue;
    consumeString(state, key);
    consumeBytes(state, 4);
    defineTransportProperty(
      clone,
      key,
      cloneTransportValue(descriptor.value, state, depth + 1),
    );
  }
  return clone;
}

// VM plugin values are proxies. Rebuild a deliberately small structured-clone
// subset as host-owned values before crossing a worker_threads boundary.
export function cloneForWorkerTransport<T>(
  value: T,
  limits: Partial<WorkerTransportLimits> = {},
): T {
  const state: CloneState = {
    limits: normalizeLimits(limits),
    nodes: 0,
    bytes: 0,
    seen: new WeakMap(),
  };
  return cloneTransportValue(value, state, 0) as T;
}

function boundedErrorText(value: unknown, fallback: string, maxChars: number) {
  let text = fallback;
  try {
    if (value !== undefined && value !== null) text = String(value);
  } catch {
    text = fallback;
  }
  return text.slice(0, maxChars);
}

function errorField(error: unknown, field: string) {
  if (
    (typeof error !== 'object' || error === null) &&
    typeof error !== 'function'
  ) {
    return undefined;
  }
  try {
    return Reflect.get(error as object, field);
  } catch {
    return undefined;
  }
}

export function sanitizePluginInteropError(
  error: unknown,
): PluginInteropErrorData {
  const name = boundedErrorText(
    errorField(error, 'name'),
    'Error',
    MAX_ERROR_NAME_CHARS,
  );
  const message = boundedErrorText(
    errorField(error, 'message') ?? error,
    'Plugin interop failed.',
    MAX_ERROR_MESSAGE_CHARS,
  );
  const rawCode = errorField(error, 'code');
  const code =
    rawCode === undefined || rawCode === null
      ? undefined
      : boundedErrorText(rawCode, '', MAX_ERROR_CODE_CHARS);
  return code ? { name, message, code } : { name, message };
}

export function pluginInteropSuccess(
  value: unknown,
): PluginInteropWireResult {
  return {
    kind: INTEROP_KIND,
    version: INTEROP_VERSION,
    ok: true,
    value,
  };
}

export function pluginInteropFailure(
  error: unknown,
): PluginInteropWireResult {
  return {
    kind: INTEROP_KIND,
    version: INTEROP_VERSION,
    ok: false,
    error: sanitizePluginInteropError(error),
  };
}

export function isPluginInteropWireResult(
  value: unknown,
): value is PluginInteropWireResult {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as Partial<PluginInteropWireResult>;
  return (
    candidate.kind === INTEROP_KIND &&
    candidate.version === INTEROP_VERSION &&
    typeof candidate.ok === 'boolean'
  );
}

export function unwrapPluginInteropResult<T>(value: unknown): T {
  // Accept legacy raw responses while main and workers are upgraded together.
  if (!isPluginInteropWireResult(value)) return value as T;
  if (value.ok) return value.value as T;

  const error = new Error(value.error.message) as Error & { code?: string };
  error.name = value.error.name || 'Error';
  if (value.error.code) error.code = value.error.code;
  throw error;
}

export async function runPluginInteropForWorker(
  invoke: () => unknown | Promise<unknown>,
  limits: Partial<WorkerTransportLimits> = {},
): Promise<PluginInteropWireResult> {
  try {
    const result = await invoke();
    return pluginInteropSuccess(cloneForWorkerTransport(result, limits));
  } catch (error) {
    return pluginInteropFailure(error);
  }
}
