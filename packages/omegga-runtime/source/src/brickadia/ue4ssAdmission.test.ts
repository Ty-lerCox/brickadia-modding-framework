import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  BoundedAdmissionQueue,
  extractBmfDispatchCommand,
  inferUe4ssServiceClass,
  isSafeUe4ssAdmissionExempt,
} from './ue4ssAdmission';

const deferred = () => {
  let resolve: () => void;
  const promise = new Promise<void>(done => {
    resolve = done;
  });
  return { promise, resolve: resolve! };
};

describe('bounded UE4SS write admission', () => {
  it('bounds regular depth while retaining a separately bounded health lane', async () => {
    const queue = new BoundedAdmissionQueue({
      maxDepth: 1,
      maxBytes: 100,
      exemptMaxDepth: 1,
      exemptMaxBytes: 100,
    });
    const gate = deferred();
    const first = queue.enqueue(() => gate.promise, {
      bytes: 10,
      deadlineMs: Date.now() + 1_000,
    });

    await expect(
      queue.enqueue(() => undefined, {
        bytes: 10,
        deadlineMs: Date.now() + 1_000,
      }),
    ).rejects.toMatchObject({ code: 'capacity_depth' });

    const health = queue.enqueue(() => 'pong', {
      bytes: 10,
      deadlineMs: Date.now() + 1_000,
      exempt: true,
    });
    expect(queue.getStatus().pending).toMatchObject({
      totalDepth: 2,
      exemptDepth: 1,
    });

    gate.resolve();
    await expect(first).resolves.toBeUndefined();
    await expect(health).resolves.toBe('pong');
  });

  it('rejects by serialized bytes and expires queued work before running it', async () => {
    const queue = new BoundedAdmissionQueue({
      maxDepth: 2,
      maxBytes: 10,
      exemptMaxDepth: 1,
      exemptMaxBytes: 10,
    });
    await expect(
      queue.enqueue(() => undefined, {
        bytes: 11,
        deadlineMs: Date.now() + 1_000,
      }),
    ).rejects.toMatchObject({ code: 'capacity_bytes' });

    const gate = deferred();
    const first = queue.enqueue(() => gate.promise, {
      bytes: 5,
      deadlineMs: Date.now() + 1_000,
    });
    let staleRan = false;
    const stale = queue.enqueue(
      () => {
        staleRan = true;
      },
      { bytes: 5, deadlineMs: Date.now() + 10 },
    );
    await new Promise(resolve => setTimeout(resolve, 20));
    gate.resolve();
    await first;
    await expect(stale).rejects.toMatchObject({ code: 'expired' });
    expect(staleRan).toBe(false);
    expect(queue.getStatus().expired).toBe(1);
  });

  it('runs reserved health work ahead of a regular backlog', async () => {
    const queue = new BoundedAdmissionQueue({
      maxDepth: 3,
      maxBytes: 100,
      exemptMaxDepth: 1,
      exemptMaxBytes: 100,
    });
    const gate = deferred();
    const order: string[] = [];
    const active = queue.enqueue(
      async () => {
        order.push('active');
        await gate.promise;
      },
      { bytes: 10, deadlineMs: Date.now() + 1_000 },
    );
    await Promise.resolve();
    const regular = queue.enqueue(
      () => {
        order.push('regular');
      },
      { bytes: 10, deadlineMs: Date.now() + 1_000 },
    );
    const health = queue.enqueue(
      () => {
        order.push('health');
      },
      {
        bytes: 10,
        deadlineMs: Date.now() + 1_000,
        exempt: true,
      },
    );

    gate.resolve();
    await Promise.all([active, regular, health]);
    expect(order).toEqual(['active', 'health', 'regular']);
  });

  it('supports an explicit rollback that preserves serialization without caps or expiry', async () => {
    const queue = new BoundedAdmissionQueue({
      enabled: false,
      maxDepth: 1,
      maxBytes: 1,
      exemptMaxDepth: 1,
      exemptMaxBytes: 1,
    });
    const ran = await Promise.all([
      queue.enqueue(() => 'first', { bytes: 100, deadlineMs: 1 }),
      queue.enqueue(() => 'second', { bytes: 100, deadlineMs: 1 }),
    ]);

    expect(ran).toEqual(['first', 'second']);
    expect(queue.getStatus()).toMatchObject({
      limits: { enabled: false },
      rejected: { depth: 0, bytes: 0 },
      expired: 0,
    });
  });
});

describe('UE4SS command classification', () => {
  it('routes only valid BMF dispatch commands to the socket plane', () => {
    expect(
      extractBmfDispatchCommand(
        'Omegga.Bridge.BmfDispatch bmf.chat.broadcast message=hello',
      ),
    ).toBe('bmf.chat.broadcast message=hello');
    expect(extractBmfDispatchCommand('Omegga.Bridge.BmfDispatch quit')).toBe(
      '',
    );
  });

  it('reserves only memory-only health commands and classifies bulk work', () => {
    expect(isSafeUe4ssAdmissionExempt('Omegga.Bridge.Echo')).toBe(true);
    expect(isSafeUe4ssAdmissionExempt('Server.Status')).toBe(true);
    expect(isSafeUe4ssAdmissionExempt('br.Server.Status')).toBe(false);
    expect(isSafeUe4ssAdmissionExempt('server.status')).toBe(false);
    expect(isSafeUe4ssAdmissionExempt(' Server.Status ')).toBe(false);
    expect(isSafeUe4ssAdmissionExempt('GetAll BRPlayerState UserName')).toBe(
      false,
    );
    expect(inferUe4ssServiceClass('Bricks.Load Example')).toBe('bulk');
    expect(
      inferUe4ssServiceClass(
        'Omegga.Bridge.ForceConsoleExecutor consolemanager Bricks.Load Example',
      ),
    ).toBe('bulk');
    expect(inferUe4ssServiceClass('Chat.Broadcast hello')).toBe('interactive');
  });

  it('keeps the Lua bridge fail-closed and deadline-aware', () => {
    const lua = fs.readFileSync(
      path.resolve(
        'templates/windows-ue4ss/ue4ss/Mods/OmeggaBridge/Scripts/main.lua',
      ),
      'utf8',
    );
    expect(lua).toContain('code=BMF_SOCKET_ADMISSION_REQUIRED');
    expect(lua).not.toContain('pcall(BMF.commands.dispatch');
    expect(lua).toContain('OMEGGA_UE4SS_BOUNDED_ADMISSION_ENABLED');
    expect(lua).toContain('UE4SS inbox request expired before execution');
    expect(lua).toContain('UE4SS inbox request missing required deadline');
    expect(lua).toContain('inbox_pending_bytes_high_water');
    expect(lua).toContain('OMEGGA_BRIDGE_MAX_INBOX_RECORD_BYTES');
    expect(lua).toContain('OMEGGA_BRIDGE_INBOX_DISCARDING_OVERSIZE_RECORD');
    expect(lua).toContain('exact_console_command == "Omegga.Bridge.Echo"');
    expect(lua).not.toContain('file:read("*l")');
    expect(
      lua.match(
        /OmeggaBridgeRejectDeferredCommandIfExpired\(id, command, deadline_ms, quiet\)/g,
      ),
    ).toHaveLength(3);
  });
});
