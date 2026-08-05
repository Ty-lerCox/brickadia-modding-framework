export type Ue4ssServiceClass = 'interactive' | 'bulk';

export type Ue4ssAdmissionContext = {
  issuedAtMs: number;
  deadlineMs: number;
  serviceClass: Ue4ssServiceClass;
  admissionExempt: boolean;
};

export type BoundedAdmissionQueueOptions = {
  enabled?: boolean;
  maxDepth: number;
  maxBytes: number;
  exemptMaxDepth: number;
  exemptMaxBytes: number;
};

export type AdmissionJobOptions = {
  bytes: number;
  serviceClass?: Ue4ssServiceClass;
  issuedAtMs?: number;
  deadlineMs: number;
  exempt?: boolean;
};

type AdmissionJob<T = unknown> = Required<
  Pick<AdmissionJobOptions, 'bytes' | 'deadlineMs'>
> & {
  serviceClass: Ue4ssServiceClass;
  issuedAtMs: number;
  exempt: boolean;
  run: () => Promise<T> | T;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (error: Error) => void;
};

const positiveInteger = (value: number, fallback: number) =>
  Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;

export class Ue4ssAdmissionError extends Error {
  readonly code: 'capacity_depth' | 'capacity_bytes' | 'expired' | 'cancelled';

  constructor(code: Ue4ssAdmissionError['code'], message: string) {
    super(message);
    this.name = 'Ue4ssAdmissionError';
    this.code = code;
  }
}

/**
 * A small, serialized, bounded queue for Omegga's writes toward UE4SS.
 * Reserved jobs are still bounded, but do not consume the normal command cap.
 */
export class BoundedAdmissionQueue {
  readonly limits: BoundedAdmissionQueueOptions;
  readonly enabled: boolean;

  #queue: AdmissionJob[] = [];
  #active: AdmissionJob | null = null;
  #scheduled = false;
  #admittedInteractive = 0;
  #admittedBulk = 0;
  #admittedExempt = 0;
  #rejectedDepth = 0;
  #rejectedBytes = 0;
  #expired = 0;
  #completed = 0;
  #failed = 0;
  #cancelled = 0;
  #highWaterDepth = 0;
  #highWaterBytes = 0;

  constructor(options: BoundedAdmissionQueueOptions) {
    this.enabled = options.enabled !== false;
    this.limits = {
      enabled: this.enabled,
      maxDepth: positiveInteger(options.maxDepth, 64),
      maxBytes: positiveInteger(options.maxBytes, 32 * 1024),
      exemptMaxDepth: positiveInteger(options.exemptMaxDepth, 4),
      exemptMaxBytes: positiveInteger(options.exemptMaxBytes, 4 * 1024),
    };
  }

  enqueue<T>(
    run: () => Promise<T> | T,
    options: AdmissionJobOptions,
  ): Promise<T> {
    const job = {
      bytes: Math.max(0, Math.floor(Number(options.bytes) || 0)),
      serviceClass: options.serviceClass === 'bulk' ? 'bulk' : 'interactive',
      issuedAtMs: Number(options.issuedAtMs) || Date.now(),
      deadlineMs: Number(options.deadlineMs) || 0,
      exempt: options.exempt === true,
      run,
    };
    const pending = this.#pendingJobs();
    const sameClass = pending.filter(item => item.exempt === job.exempt);
    const pendingDepth = sameClass.length;
    const pendingBytes = sameClass.reduce((sum, item) => sum + item.bytes, 0);
    const depthLimit = job.exempt
      ? this.limits.exemptMaxDepth
      : this.limits.maxDepth;
    const byteLimit = job.exempt
      ? this.limits.exemptMaxBytes
      : this.limits.maxBytes;

    if (this.enabled && pendingDepth >= depthLimit) {
      this.#rejectedDepth += 1;
      return Promise.reject(
        new Ue4ssAdmissionError(
          'capacity_depth',
          `UE4SS write admission rejected: ${job.exempt ? 'reserved' : 'regular'} queue depth limit ${depthLimit} reached.`,
        ),
      );
    }
    if (
      this.enabled &&
      (job.bytes > byteLimit || pendingBytes + job.bytes > byteLimit)
    ) {
      this.#rejectedBytes += 1;
      return Promise.reject(
        new Ue4ssAdmissionError(
          'capacity_bytes',
          `UE4SS write admission rejected: ${job.exempt ? 'reserved' : 'regular'} queue byte limit ${byteLimit} reached.`,
        ),
      );
    }

    if (job.exempt) this.#admittedExempt += 1;
    else if (job.serviceClass === 'bulk') this.#admittedBulk += 1;
    else this.#admittedInteractive += 1;

    return new Promise<T>((resolve, reject) => {
      this.#queue.push({ ...job, resolve, reject } as AdmissionJob<T>);
      const status = this.getStatus();
      this.#highWaterDepth = Math.max(
        this.#highWaterDepth,
        status.pending.totalDepth,
      );
      this.#highWaterBytes = Math.max(
        this.#highWaterBytes,
        status.pending.totalBytes,
      );
      this.#scheduleNext();
    });
  }

  clear(reason = 'UE4SS write queue cleared.') {
    const queued = this.#queue.splice(0);
    this.#cancelled += queued.length;
    for (const job of queued) {
      job.reject(new Ue4ssAdmissionError('cancelled', reason));
    }
  }

  getStatus() {
    const pending = this.#pendingJobs();
    const regular = pending.filter(job => !job.exempt);
    const exempt = pending.filter(job => job.exempt);
    const interactive = regular.filter(
      job => job.serviceClass === 'interactive',
    );
    const bulk = regular.filter(job => job.serviceClass === 'bulk');
    const sumBytes = (jobs: AdmissionJob[]) =>
      jobs.reduce((sum, job) => sum + job.bytes, 0);
    const oldestIssuedAtMs = pending.reduce(
      (oldest, job) => Math.min(oldest, job.issuedAtMs),
      Number.POSITIVE_INFINITY,
    );

    return {
      limits: { ...this.limits },
      pending: {
        totalDepth: pending.length,
        totalBytes: sumBytes(pending),
        interactiveDepth: interactive.length,
        interactiveBytes: sumBytes(interactive),
        bulkDepth: bulk.length,
        bulkBytes: sumBytes(bulk),
        exemptDepth: exempt.length,
        exemptBytes: sumBytes(exempt),
        oldestAgeMs: Number.isFinite(oldestIssuedAtMs)
          ? Math.max(0, Date.now() - oldestIssuedAtMs)
          : 0,
      },
      admitted: {
        interactive: this.#admittedInteractive,
        bulk: this.#admittedBulk,
        exempt: this.#admittedExempt,
      },
      rejected: {
        depth: this.#rejectedDepth,
        bytes: this.#rejectedBytes,
      },
      expired: this.#expired,
      completed: this.#completed,
      failed: this.#failed,
      cancelled: this.#cancelled,
      highWater: {
        depth: this.#highWaterDepth,
        bytes: this.#highWaterBytes,
      },
    };
  }

  #pendingJobs() {
    return this.#active ? [this.#active, ...this.#queue] : [...this.#queue];
  }

  #scheduleNext() {
    if (this.#active || this.#scheduled || this.#queue.length === 0) return;
    this.#scheduled = true;
    queueMicrotask(() => {
      this.#scheduled = false;
      const exemptIndex = this.#queue.findIndex(job => job.exempt);
      const job =
        exemptIndex >= 0
          ? this.#queue.splice(exemptIndex, 1)[0]
          : this.#queue.shift();
      if (!job) return;
      this.#active = job;
      void this.#run(job);
    });
  }

  async #run(job: AdmissionJob) {
    try {
      if (this.enabled && job.deadlineMs > 0 && Date.now() >= job.deadlineMs) {
        this.#expired += 1;
        job.reject(
          new Ue4ssAdmissionError(
            'expired',
            `UE4SS write expired after ${Math.max(0, Date.now() - job.issuedAtMs)}ms in admission.`,
          ),
        );
        return;
      }

      const value = await job.run();
      this.#completed += 1;
      job.resolve(value);
    } catch (error) {
      this.#failed += 1;
      job.reject(error instanceof Error ? error : new Error(String(error)));
    } finally {
      this.#active = null;
      this.#scheduleNext();
    }
  }
}

export const extractBmfDispatchCommand = (line: string) => {
  const match = String(line ?? '').match(
    /^Omegga\.Bridge\.BmfDispatch\s+(.+)$/i,
  );
  const command = match?.[1]?.trim() ?? '';
  return /^bmf\.[A-Za-z0-9_.-]+(?:\s|$)/i.test(command) ? command : '';
};

export const inferUe4ssServiceClass = (line: string): Ue4ssServiceClass => {
  const normalized = String(line ?? '').trim();
  const effectiveCommand = normalized.replace(
    /^Omegga\.Bridge\.ForceConsoleExecutor\s+\S+\s+/i,
    '',
  );
  return /^(?:GetAll\b|(?:BR\.World|Bricks|br\.Prefab|Server\.Environment)\.|Omegga\.Bridge\.(?:Dump|Describe|Probe|Replay|Spawn))/i.test(
    effectiveCommand,
  )
    ? 'bulk'
    : 'interactive';
};

export const isSafeUe4ssAdmissionExempt = (line: string) =>
  line === 'Omegga.Bridge.Echo' || line === 'Server.Status';
