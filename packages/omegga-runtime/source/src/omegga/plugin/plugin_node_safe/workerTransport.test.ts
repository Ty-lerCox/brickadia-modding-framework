import { describe, expect, it } from 'vitest';
import { NodeVM } from 'vm2';
import {
  WorkerTransportError,
  cloneForWorkerTransport,
  pluginInteropFailure,
  runPluginInteropForWorker,
  unwrapPluginInteropResult,
} from './workerTransport';

function transportErrorCode(run: () => unknown) {
  try {
    run();
  } catch (error) {
    expect(error).toBeInstanceOf(WorkerTransportError);
    return (error as WorkerTransportError).code;
  }
  throw new Error('expected worker transport operation to fail');
}

describe('cloneForWorkerTransport', () => {
  it('converts a VM-proxied plain result into a structured-cloneable value', () => {
    const vm = new NodeVM({ sandbox: {} });
    const proxiedResult = vm.run(
      `module.exports = {
        nested: { value: 42, missing: undefined },
        list: [1, { ok: true }],
      };`,
      'plugin-event-result.js',
    );

    expect(() => structuredClone(proxiedResult)).toThrow();

    const transportResult = cloneForWorkerTransport(proxiedResult);
    expect(structuredClone(transportResult)).toEqual({
      nested: { value: 42, missing: undefined },
      list: [1, { ok: true }],
    });
  });

  it('preserves top-level undefined and cyclic references', () => {
    expect(cloneForWorkerTransport(undefined)).toBeUndefined();

    const vm = new NodeVM({ sandbox: {} });
    const cycle = vm.run(
      'const value = { ok: true }; value.self = value; module.exports = value;',
      'plugin-event-cycle.js',
    );
    const cloned = cloneForWorkerTransport(cycle) as {
      ok: boolean;
      self: unknown;
    };
    expect(cloned.ok).toBe(true);
    expect(cloned.self).toBe(cloned);
    expect(() => structuredClone(cloned)).not.toThrow();
  });

  it.each([
    ['function', 'module.exports = function result() {}'],
    ['symbol', 'module.exports = Symbol("result")'],
    ['promise', 'module.exports = Promise.resolve(1)'],
    ['weak map', 'module.exports = new WeakMap()'],
    ['weak set', 'module.exports = new WeakSet()'],
  ])('rejects unsupported %s values deterministically', (_label, source) => {
    const vm = new NodeVM({ sandbox: {} });
    const value = vm.run(source, 'unsupported-plugin-result.js');
    expect(() => cloneForWorkerTransport(value)).toThrow(
      WorkerTransportError,
    );
  });

  it('rejects accessors without invoking them', () => {
    const vm = new NodeVM({ sandbox: {} });
    const value = vm.run(
      `module.exports = Object.defineProperty({}, 'danger', {
        enumerable: true,
        get() { throw new Error('getter must not run'); },
      });`,
      'accessor-plugin-result.js',
    );
    expect(transportErrorCode(() => cloneForWorkerTransport(value))).toBe(
      'TRANSPORT_ACCESSOR_UNSUPPORTED',
    );
  });

  it('enforces byte, node, and depth limits at deterministic boundaries', () => {
    expect(
      cloneForWorkerTransport('four', {
        maxBytes: 12,
        maxNodes: 1,
        maxDepth: 0,
      }),
    ).toBe('four');
    expect(
      transportErrorCode(() =>
        cloneForWorkerTransport('four', {
          maxBytes: 11,
          maxNodes: 1,
          maxDepth: 0,
        }),
      ),
    ).toBe('TRANSPORT_BYTE_LIMIT');

    expect(
      cloneForWorkerTransport({ value: 1 }, {
        maxBytes: 100,
        maxNodes: 2,
        maxDepth: 1,
      }),
    ).toEqual({ value: 1 });
    expect(
      transportErrorCode(() =>
        cloneForWorkerTransport(
          { value: 1 },
          { maxBytes: 100, maxNodes: 1, maxDepth: 1 },
        ),
      ),
    ).toBe('TRANSPORT_NODE_LIMIT');

    expect(
      cloneForWorkerTransport(
        { nested: { value: 1 } },
        { maxBytes: 100, maxNodes: 3, maxDepth: 2 },
      ),
    ).toEqual({ nested: { value: 1 } });
    expect(
      transportErrorCode(() =>
        cloneForWorkerTransport(
          { nested: { value: 1 } },
          { maxBytes: 100, maxNodes: 3, maxDepth: 1 },
        ),
      ),
    ).toBe('TRANSPORT_DEPTH_LIMIT');
  });
});

describe('plugin interop wire results', () => {
  it('bounds error data and restores rejection semantics', () => {
    const source = new WorkerTransportError(
      'C'.repeat(512),
      'message'.repeat(1024),
    );
    source.name = 'N'.repeat(512);
    const wire = pluginInteropFailure(source);
    expect(wire.ok).toBe(false);
    if (wire.ok) throw new Error('expected failure wire result');
    expect(wire.error.name.length).toBe(128);
    expect(wire.error.message.length).toBe(2048);
    expect(wire.error.code?.length).toBe(128);
    expect(() => structuredClone(wire)).not.toThrow();

    try {
      unwrapPluginInteropResult(wire);
      throw new Error('expected remote error');
    } catch (error) {
      expect((error as Error).name).toBe('N'.repeat(128));
      expect((error as Error & { code?: string }).code).toBe('C'.repeat(128));
    }
  });

  it('returns an error envelope for rejection and remains usable afterward', async () => {
    const rejected = await runPluginInteropForWorker(() => {
      throw new Error('bridge offline');
    });
    expect(() => unwrapPluginInteropResult(rejected)).toThrow('bridge offline');

    const recovered = await runPluginInteropForWorker(() => ({ ok: true }));
    expect(unwrapPluginInteropResult(recovered)).toEqual({ ok: true });
  });

  it('returns an error envelope for unsupported output and survives a later call', async () => {
    const unsupported = await runPluginInteropForWorker(() => Symbol('bad'));
    expect(() => unwrapPluginInteropResult(unsupported)).toThrow(
      'cannot contain symbols',
    );

    const recovered = await runPluginInteropForWorker(() => undefined);
    expect(unwrapPluginInteropResult(recovered)).toBeUndefined();
  });

  it('accepts legacy raw success values during an in-place upgrade', () => {
    expect(unwrapPluginInteropResult({ legacy: true })).toEqual({
      legacy: true,
    });
  });
});
