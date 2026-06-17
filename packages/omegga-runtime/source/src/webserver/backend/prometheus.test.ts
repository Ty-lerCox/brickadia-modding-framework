import { afterEach, describe, expect, it } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildPrometheusMetrics } from './prometheus';
import type Webserver from './index';

const oldStatusPath = process.env.OMEGGA_BMF_STATUS_PATH;
const oldTelemetryPath = process.env.OMEGGA_BMF_TELEMETRY_PATH;
const oldFrameTelemetryPath = process.env.OMEGGA_BMF_FRAME_TELEMETRY_PATH;

afterEach(() => {
  if (oldStatusPath === undefined) {
    delete process.env.OMEGGA_BMF_STATUS_PATH;
  } else {
    process.env.OMEGGA_BMF_STATUS_PATH = oldStatusPath;
  }
  if (oldTelemetryPath === undefined) {
    delete process.env.OMEGGA_BMF_TELEMETRY_PATH;
  } else {
    process.env.OMEGGA_BMF_TELEMETRY_PATH = oldTelemetryPath;
  }
  if (oldFrameTelemetryPath === undefined) {
    delete process.env.OMEGGA_BMF_FRAME_TELEMETRY_PATH;
  } else {
    process.env.OMEGGA_BMF_FRAME_TELEMETRY_PATH = oldFrameTelemetryPath;
  }
});

describe('buildPrometheusMetrics', () => {
  it('exports server, process, and BMF runtime gauges without player labels', () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'omegga-prometheus-'));
    const bmfStatusPath = path.join(dir, 'status.json');
    const bmfTelemetryPath = path.join(dir, 'telemetry.json');
    const bmfFrameTelemetryPath = path.join(dir, 'frame-telemetry.json');
    process.env.OMEGGA_BMF_STATUS_PATH = bmfStatusPath;
    process.env.OMEGGA_BMF_TELEMETRY_PATH = bmfTelemetryPath;
    process.env.OMEGGA_BMF_FRAME_TELEMETRY_PATH = bmfFrameTelemetryPath;
    writeFileSync(
      bmfStatusPath,
      JSON.stringify({
        version: '0.1.0',
        target_build: 'PC-Shipping-CL13530',
        compatibility_status: 'ok',
        plugins_loaded: 2,
        plugin_errors: 1,
        plugin_tick_active: true,
        plugin_tick_count: 42,
        audit_records: 3,
        plugin_watchdog_isolated: 0,
      }),
      'utf8',
    );
    writeFileSync(
      bmfFrameTelemetryPath,
      JSON.stringify({
        schema_version: 1,
        source: 'BMFFrameTelemetry',
        hook_registered: true,
        window: {
          samples: 60,
          idle_samples: 0,
          delta_ms_sum: 1000,
          delta_ms_avg: 16.667,
          delta_ms_max: 20,
          delta_ms_last: 15,
          fps_avg: 59.999,
          slow_16_67: 12,
          slow_33_33: 1,
          slow_50: 0,
          slow_100: 0,
        },
        lifetime: {
          samples_total: 600,
          idle_samples_total: 0,
          delta_ms_sum_total: 10000,
          delta_ms_avg: 16.667,
          delta_ms_max: 40,
          delta_ms_last: 15,
          slow_16_67_total: 120,
          slow_33_33_total: 3,
          slow_50_total: 1,
          slow_100_total: 0,
        },
        spikes: {
          threshold_ms: 100,
          total: 1,
          last: {
            sequence: 1,
            observed_at_unix_ms: Date.now(),
            sample: 590,
            delta_ms: 125.5,
            idle: false,
            slow_16_67_total: 120,
            slow_33_33_total: 3,
            slow_50_total: 1,
            slow_100_total: 1,
          },
          recent: [],
        },
      }),
      'utf8',
    );
    writeFileSync(
      bmfTelemetryPath,
      JSON.stringify({
        schema_version: 1,
        commands: {
          by_name: {
            'bmf.status': {
              command: 'bmf.status',
              count: 3,
              ok: 3,
              error: 0,
              duration_ms_sum: 9,
              duration_ms_max: 4,
              last_ms: 2,
            },
          },
          by_transport: {
            file: {
              transport: 'file',
              count: 3,
              ok: 3,
              error: 0,
              duration_ms_sum: 9,
              duration_ms_max: 4,
              last_ms: 2,
            },
          },
        },
        events: {
          by_event: {
            serverReady: {
              event: 'serverReady',
              count: 1,
              ok: 1,
              error: 0,
              duration_ms_sum: 5,
              duration_ms_max: 5,
              last_ms: 5,
              handler_calls: 2,
              handler_errors: 0,
              handler_duration_ms_sum: 7,
              handler_duration_ms_max: 4,
              handler_last_ms: 3,
            },
          },
        },
        plugins: {
          by_plugin: {
            Example: {
              plugin: 'Example',
              count: 2,
              ok: 2,
              error: 0,
              duration_ms_sum: 8,
              duration_ms_max: 6,
              last_ms: 2,
            },
          },
          by_hook: {
            'Example|onTick': {
              plugin: 'Example',
              hook: 'onTick',
              count: 2,
              ok: 2,
              error: 0,
              duration_ms_sum: 8,
              duration_ms_max: 6,
              last_ms: 2,
            },
          },
        },
        scheduler: {
          by_key: {
            'delayed_callback|command_worker': {
              kind: 'delayed_callback',
              name: 'command_worker',
              count: 4,
              ok: 4,
              error: 0,
              duration_ms_sum: 12,
              duration_ms_max: 5,
              last_ms: 3,
            },
          },
        },
        workers: {
          command_polls: {
            count: 5,
            ok: 5,
            error: 0,
            duration_ms_sum: 10,
            duration_ms_max: 4,
            last_ms: 1,
            files_processed: 3,
          },
        },
      }),
      'utf8',
    );

    const server = {
      omegga: {
        started: true,
        starting: false,
        stopping: false,
        path: dir,
        config: { server: { steambeta: 'main' } },
        consoleCommandMetrics: {
          'Server.Status': {
            command: 'Server.Status',
            count: 2,
            lastAtMs: Date.now(),
          },
          'Chat.Command /TP': {
            command: 'Chat.Command /TP',
            count: 1,
            lastAtMs: Date.now(),
          },
        },
      },
      lastReportedStatusAt: Date.now(),
      lastServerStatusPollDurationMs: 123,
      serverStatusPollEnabled: true,
      serverStatusPollMetrics: {
        count: 3,
        ok: 2,
        error: 1,
        durationMsSum: 375,
        durationMsMax: 200,
        lastMs: 123,
        lastAtMs: Date.now(),
      },
      lastReportedStatus: {
        serverName: 'Test Server',
        description: 'ignored',
        bricks: 120,
        components: 9,
        time: 90_000,
        players: [
          {
            name: 'Ty',
            ping: 50,
            time: 10_000,
            roles: ['Host'],
            address: '127.0.0.1',
            id: 'player-id',
          },
        ],
      },
    } as unknown as Webserver;

    const output = buildPrometheusMetrics(server);

    expect(output).toContain('brickadia_server_up 1');
    expect(output).toContain('brickadia_server_players 1');
    expect(output).toContain('brickadia_server_bricks 120');
    expect(output).toContain(
      'omegga_server_status_poll_duration_seconds 0.123',
    );
    expect(output).toContain('omegga_server_status_poll_enabled 1');
    expect(output).toContain(
      'omegga_server_status_poll_total{status="ok"} 2',
    );
    expect(output).toContain(
      'omegga_server_status_poll_duration_stat_seconds{statistic="avg"} 0.125',
    );
    expect(output).toContain(
      'omegga_console_command_sent_total{command="Server.Status"} 2',
    );
    expect(output).toContain(
      'omegga_console_command_sent_total{command="Chat.Command /TP"} 1',
    );
    expect(output).toContain('bmf_runtime_status_up 1');
    expect(output).toContain('bmf_telemetry_up 1');
    expect(output).toContain('bmf_telemetry_schema_version 1');
    expect(output).toContain('brickadia_frame_telemetry_up 1');
    expect(output).toContain('brickadia_frame_telemetry_hook_registered 1');
    expect(output).toContain(
      'brickadia_frame_delta_milliseconds{scope="window",statistic="avg"} 16.667',
    );
    expect(output).toContain(
      'brickadia_frame_delta_milliseconds{scope="lifetime",statistic="max"} 40',
    );
    expect(output).toContain(
      'brickadia_frame_fps{scope="window",statistic="avg"} 59.999',
    );
    expect(output).toContain('brickadia_frame_samples_total 600');
    expect(output).toContain(
      'brickadia_frame_slow_total{threshold_ms="33.33"} 3',
    );
    expect(output).toContain('brickadia_frame_spikes_total{threshold_ms="100"} 1');
    expect(output).toContain('brickadia_frame_spike_last_delta_milliseconds 125.5');
    expect(output).toContain('bmf_plugins_loaded 2');
    expect(output).toContain('bmf_plugin_errors_total 1');
    expect(output).toContain('bmf_plugin_tick_total 42');
    expect(output).toContain(
      'bmf_command_processed_total{command="bmf.status",status="ok"} 3',
    );
    expect(output).toContain(
      'bmf_command_duration_milliseconds{command="bmf.status",statistic="avg"} 3',
    );
    expect(output).toContain(
      'bmf_event_handler_total{event="serverReady",status="ok"} 2',
    );
    expect(output).toContain(
      'bmf_plugin_hook_duration_milliseconds{plugin="Example",hook="onTick",statistic="max"} 6',
    );
    expect(output).toContain(
      'bmf_scheduler_callback_duration_milliseconds{kind="delayed_callback",name="command_worker",statistic="avg"} 3',
    );
    expect(output).toContain(
      'bmf_worker_poll_duration_milliseconds{worker="command_polls",statistic="max"} 4',
    );
    expect(output).not.toContain('Ty');
    expect(output).not.toContain('player-id');
    expect(output).not.toContain('127.0.0.1"');

    rmSync(dir, { recursive: true, force: true });
  });
});
