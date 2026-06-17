import {
  ChildProcess,
  spawn,
  SpawnOptionsWithoutStdio,
} from 'node:child_process';
import path from 'node:path';
import { IS_WINDOWS } from './platform';

export type ProcessInvocation = {
  command: string;
  args: string[];
  options?: SpawnOptionsWithoutStdio;
};

export function getProcessInvocation(target: string): ProcessInvocation {
  const extension = path.extname(target).toLowerCase();

  if (extension === '.js') {
    return {
      command: process.execPath,
      args: [target],
      options: { windowsHide: IS_WINDOWS },
    };
  }

  if (IS_WINDOWS && extension === '.ps1') {
    return {
      command: 'powershell.exe',
      args: [
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        target,
      ],
      options: { windowsHide: true },
    };
  }

  if (IS_WINDOWS && ['.cmd', '.bat'].includes(extension)) {
    return {
      command: process.env.ComSpec ?? process.env.COMSPEC ?? 'cmd.exe',
      args: ['/d', '/s', '/c', target],
      options: { windowsHide: true },
    };
  }

  return {
    command: target,
    args: [],
    options: { windowsHide: IS_WINDOWS },
  };
}

export function forceKillProcessTree(pid: number) {
  if (!pid) return;

  const killer = IS_WINDOWS
    ? spawn('taskkill', ['/PID', String(pid), '/T', '/F'], {
        stdio: 'ignore',
        windowsHide: true,
      })
    : spawn('kill', ['-9', String(pid)], { stdio: 'ignore' });

  killer.unref();
}

export async function terminateChildProcess(
  child: ChildProcess,
  {
    gracefulLine,
    forceAfterMs = 5000,
    immediateSignal = true,
  }: {
    gracefulLine?: string;
    forceAfterMs?: number;
    immediateSignal?: boolean;
  } = {},
) {
  if (!child || child.exitCode !== null) return;

  if (gracefulLine && child.stdin && !child.stdin.destroyed) {
    try {
      child.stdin.write(
        gracefulLine.endsWith('\n') ? gracefulLine : gracefulLine + '\n',
      );
    } catch {
      // ignore failed shutdown writes
    }
  }

  if (immediateSignal) {
    try {
      child.kill();
    } catch {
      // ignore failed signal delivery
    }
  }

  let timer: NodeJS.Timeout;
  if (typeof child.pid === 'number') {
    timer = setTimeout(() => forceKillProcessTree(child.pid), forceAfterMs);
    timer.unref?.();
  }

  try {
    await new Promise(resolve => {
      if (child.exitCode !== null) return resolve(child.exitCode);
      child.once('exit', resolve);
    });
  } catch {
    // ignore exit listener races while cleaning up
  } finally {
    if (timer) clearTimeout(timer);
  }
}
