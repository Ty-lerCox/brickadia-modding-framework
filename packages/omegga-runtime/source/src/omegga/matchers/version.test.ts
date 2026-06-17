import { describe, expect, it } from 'vitest';
import { extractBrickadiaVersion } from './version';

describe('extractBrickadiaVersion', () => {
  it('parses the Brickadia version from the log header', () => {
    expect(
      extractBrickadiaVersion(
        [
          'Hello!',
          'Brickadia EA2 (PC-Shipping-CL12960), Engine 6bfecdfbc39f',
          'Public release build: 1',
        ].join('\n'),
      ),
    ).toBe(12960);
  });

  it('returns undefined when the version header is missing', () => {
    expect(extractBrickadiaVersion('LogPakFile: Initializing PakPlatformFile'))
      .toBeUndefined();
  });
});
