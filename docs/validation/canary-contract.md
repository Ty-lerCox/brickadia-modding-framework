# Canary Contract

Each BMF canary writes a JSON artifact with enough evidence to decide whether a
feature is complete, blocked, or unsafe to promote.

## Who Should Read This?

BMF maintainers should use this page when adding or reviewing validation
scripts. Architects should use it to understand what proof is expected before a
feature is promoted.

Required fields:

- `feature`
- `status`
- `validationLevel`
- `startedAt`
- `finishedAt`
- `evidence`

Recommended artifact path:

```text
artifacts/overnight/<timestamp>/<feature>.json
```

Validation levels are defined in [Framework Status](../status.md) and
`TODO.md`.

For `L6 Frame Time` artifacts, include evidence for:

- the baseline window before the feature path is triggered;
- the active window while the feature path is under test;
- the recovery window after disabling or stopping the feature path;
- average and max `brickadia_frame_delta_milliseconds`;
- slow-frame and spike counters;
- command/worker attribution such as `bmf_command_processed_total`,
  `bmf_command_duration_milliseconds`, and `bmf_worker_items_total`;
- the decision: passed, failed, blocked, or skipped with reason.
