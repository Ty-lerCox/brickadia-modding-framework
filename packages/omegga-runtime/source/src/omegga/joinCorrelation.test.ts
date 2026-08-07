import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, test } from 'vitest';

import {
  JoinCorrelationTracker,
  normalizeJoinCorrelationContext,
  normalizeJoinCorrelationPhaseRecord,
} from './joinCorrelation';

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('join correlation attribution', () => {
  test('accepts only bounded plain correlation contexts and fixed phases', () => {
    expect(
      normalizeJoinCorrelationContext({
        correlationId: 'join-11111111-2222-4333-8444-555555555555',
        logObservedAtUnixMs: 100,
        matcherCompletedAtUnixMs: 104,
        connectionGeneration: 3,
        playerName: 'must-not-survive',
      }),
    ).toEqual({
      schemaVersion: 1,
      correlationId: 'join-11111111-2222-4333-8444-555555555555',
      logObservedAtUnixMs: 100,
      matcherCompletedAtUnixMs: 104,
      connectionGeneration: 3,
    });
    expect(
      normalizeJoinCorrelationPhaseRecord({
        correlationId: 'join-11111111-2222-4333-8444-555555555555',
        phase: 'unknown_dynamic_phase',
        outcome: 'ok',
      }),
    ).toBeUndefined();
  });

  test('writes sanitized phase records and bounded asymmetric frame context', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-join-attribution-'));
    tempDirs.push(dir);
    const tracker = new JoinCorrelationTracker({
      enabled: true,
      outputDir: dir,
      runtimeDir: dir,
    });
    const context = tracker.create(Date.now() - 2);
    expect(context).toBeDefined();
    tracker.record({
      correlationId: context?.correlationId,
      phase: 'connection_generation',
      outcome: 'ok',
      startedAtUnixMs: Date.now() - 1,
      endedAtUnixMs: Date.now(),
      component: 'omegga_lifecycle_registry',
      detail: { connectionGeneration: 1, playerUuid: 'must_not_be_written' },
    });
    tracker.handleLine(
      `[BMF_SLOW_FRAME] ${JSON.stringify({
        sequence: 1,
        observed_at_unix_ms: Date.now() - 1100,
        sample: 42,
        delta_ms: 34.5,
        idle: false,
      })}`,
    );
    await new Promise(resolve => setTimeout(resolve, 20));
    await tracker.flush();

    const phaseLog = fs.readFileSync(
      path.join(dir, 'join-correlation.ndjson'),
      'utf8',
    );
    const frameLog = fs.readFileSync(
      path.join(dir, 'frame-spike-context.ndjson'),
      'utf8',
    );
    expect(phaseLog).toContain('connection_generation');
    expect(phaseLog).not.toContain('must_not_be_written');
    expect(frameLog).toContain('"beforeMs":500');
    expect(frameLog).toContain('"afterMs":1000');
    expect(tracker.metricsSnapshot()).toMatchObject({
      enabled: true,
      droppedWrites: 0,
    });
  });
});
