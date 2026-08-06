import { describe, expect, test, vi } from 'vitest';
import command from './command';

describe('command matcher private-routing containment', () => {
  test('does not correlate unknown-command errors with shared last-player state', () => {
    const emit = vi.fn();
    const matcher = command({
      players: [{ name: 'A' }, { name: 'B' }, { name: 'C' }],
      emit,
    } as any);
    const line = (data: string) =>
      matcher.pattern('', {
        groups: { generator: 'LogChatCommands', data },
      } as any);

    line(
      'Player "A" is trying to call command "/missing-a" with arg string "".',
    );
    line(
      'Player "B" is trying to call command "/missing-b" with arg string "".',
    );
    line('Error: Command missing-a does not exist.');
    line('Error: Command missing-b does not exist.');

    expect(emit).not.toHaveBeenCalledWith(
      'unknownCommand',
      expect.anything(),
      expect.anything(),
    );
  });
});
