import { describe, expect, it, vi } from 'vitest';
import MotionLatestValueLane from './motionLatestValueLane';

describe('MotionLatestValueLane', () => {
  it('keeps only the newest unsent frame while backpressured', () => {
    const lane = new MotionLatestValueLane();
    const write = vi
      .fn<(payload: string) => boolean>()
      .mockReturnValueOnce(false)
      .mockReturnValue(true);

    expect(lane.offer('frame-1', false, write)).toEqual({
      sent: true,
      queued: false,
      coalesced: false,
    });
    expect(lane.offer('frame-2', false, write)).toEqual({
      sent: false,
      queued: true,
      coalesced: false,
    });
    expect(lane.offer('frame-3', false, write)).toEqual({
      sent: false,
      queued: true,
      coalesced: true,
    });

    expect(lane.drain(write)).toEqual({
      sent: true,
      queued: false,
      coalesced: false,
    });
    expect(write.mock.calls).toEqual([['frame-1'], ['frame-3']]);
    expect(lane.hasPendingPayload).toBe(false);
  });

  it('clears at most one pending frame when a lease or schema is revoked', () => {
    const lane = new MotionLatestValueLane();
    lane.offer('pending', true, vi.fn());

    expect(lane.clear()).toBe(true);
    expect(lane.clear()).toBe(false);
    expect(lane.hasPendingPayload).toBe(false);
  });
});
