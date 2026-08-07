import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, test } from 'vitest';

const sourcePath = path.join(
  __dirname,
  'fixtures',
  'cityrpg-callerless-probe-v1.ws',
);

describe('isolated callerless CityRPG probe contract', () => {
  test('is a bounded no-op with an exactly-once deterministic acknowledgement', () => {
    const source = fs.readFileSync(sourcePath, 'utf8');
    expect(source.match(/on ChatCommand\("cityrpgRemote"/g)).toHaveLength(1);
    expect(source).toContain('action == "callerlessprobev1"');
    expect(source).toContain('callerless_probe_ack:${requestId}');
    expect(source).toContain('acknowledgedRequestIds.find(requestId)');
    expect(source).toContain('!existing.Found');
    expect(source).toContain('MAX_PROBE_REQUESTS = 64');
    expect(source).not.toMatch(
      /FindPlayer|GetController|controller\.|Broadcast|Whisper|StatusMessage|AddInventory|SpawnPrefab|SetTeam|SaveWorld/,
    );
  });
});
