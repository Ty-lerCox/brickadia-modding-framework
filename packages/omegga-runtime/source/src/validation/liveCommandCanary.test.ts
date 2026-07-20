import { describe, expect, it } from 'vitest';
import {
  buildDefaultLiveCommandCanaries,
  isDangerousLiveCommandCanaryLine,
} from './liveCommandCanary';

describe('live command canary', () => {
  it('includes legacy and namespaced chat commands in the default matrix', () => {
    const canaries = buildDefaultLiveCommandCanaries('Ty');
    const commands = canaries.map(canary => canary.command).filter(Boolean);

    expect(commands.some(command => /^Chat\.Broadcast\b/.test(command))).toBe(
      true,
    );
    expect(
      commands.some(command => /^br\.Chat\.Broadcast\b/.test(command)),
    ).toBe(true);
    expect(commands.some(command => /^Chat\.Whisper "Ty"/.test(command))).toBe(
      true,
    );
    expect(
      commands.some(command => /^br\.Chat\.Whisper "Ty"/.test(command)),
    ).toBe(true);
    expect(
      commands.some(command => /^br\.Chat\.StatusMessage "Ty"/.test(command)),
    ).toBe(true);
    expect(commands).toContain('GetAll BRPlayerState UserName');
    expect(commands).toContain('Omegga.Bridge.BMF bmf.status');
  });

  it('refuses shutdown, travel, world-load, and destructive brick commands', () => {
    expect(isDangerousLiveCommandCanaryLine('exit')).toBe(true);
    expect(isDangerousLiveCommandCanaryLine('quit')).toBe(true);
    expect(isDangerousLiveCommandCanaryLine('ServerTravel AnotherMap')).toBe(
      true,
    );
    expect(isDangerousLiveCommandCanaryLine('BR.World.LoadAdditive Test')).toBe(
      true,
    );
    expect(isDangerousLiveCommandCanaryLine('br.BR.World.SaveAs Test')).toBe(
      true,
    );
    expect(isDangerousLiveCommandCanaryLine('Bricks.Clear')).toBe(true);
    expect(isDangerousLiveCommandCanaryLine('br.Bricks.ClearRegion a b')).toBe(
      true,
    );
  });

  it('allows safe chat and read-only probe commands', () => {
    expect(isDangerousLiveCommandCanaryLine('br.Chat.Whisper "Ty" hello')).toBe(
      false,
    );
    expect(isDangerousLiveCommandCanaryLine('Chat.Broadcast hello')).toBe(
      false,
    );
    expect(
      isDangerousLiveCommandCanaryLine('GetAll BRPlayerState UserName'),
    ).toBe(false);
    expect(
      isDangerousLiveCommandCanaryLine('Omegga.Bridge.BMF bmf.status'),
    ).toBe(false);
  });
});
