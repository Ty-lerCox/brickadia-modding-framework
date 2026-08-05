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
        schema_version: 2,
        source: 'BMFFrameTelemetry',
        hook_registered: true,
        pacing: {
          enabled: true,
          config_valid: true,
          target_fps: 120,
          target_override_attempted: true,
          target_override_applied: true,
          target_override_result: 'applied',
          target_exception_code: 0,
          layout_calibrated: true,
          layout_adjustment_bytes: -40,
          entry_signatures_valid: true,
          previous_max_fps: 60,
          previous_max_tick_rate: 60,
          observed_max_fps: 120,
          observed_max_tick_rate: 120,
          timer_policy_attempted: true,
          timer_policy_applied: true,
          timer_policy_error: 0,
          timer_resolution_ms: 1,
          timer_resolution_request_succeeded: true,
          timer_resolution_result: 0,
        },
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
        schema_version: 2,
        player_registry: {
          cache_first_enabled: true,
          repair_enabled: true,
          legacy_discovery_enabled: false,
          cache_loaded: true,
          generation: 9,
          entries: 14,
          cache_hits: 11,
          cache_misses: 3,
          disk_loads: 2,
          disk_load_failures: 1,
          memory_syncs: 7,
          persisted_syncs: 5,
          controller_handle_hits: 13,
          controller_handle_misses: 4,
          targeted_resolutions: 6,
          targeted_failures: 2,
          broad_repairs: 8,
          broad_repair_skipped: 9,
          broad_repair_failures: 1,
          broad_repair_matches: 12,
          global_scans: 10,
          repair_running: false,
          repair_cooldown_ms: 15000,
        },
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
        socket_scheduler: {
          unified_enabled: true,
          budget_ms: 3,
          budget_enforced: true,
          native_drains: {
            budget_enabled: true,
            batch_size: 1,
            max_events_per_pump: 4,
            by_source: {
              tree: {
                attempted: 9,
                drained: 6,
                skipped: 2,
                overruns: 1,
                depth: 3,
                depth_available: true,
              },
              zone: {
                attempted: 5,
                drained: 4,
                skipped: 1,
                overruns: 0,
                depth: -1,
                depth_available: false,
              },
            },
          },
          configured_ingress_per_pump: 16,
          effective_ingress_per_pump: 2,
          direct_ingress_cap_enabled: true,
          direct_ingress_cap_per_pump: 2,
          ingress_last: 2,
          direct_admitted_last: 1,
          budget_exhausted_total: 4,
          budget_admission_stopped_total: 3,
          budget_tunnel_dispatch_skipped_total: 2,
          budget_dispatch_skipped_total: 5,
          slice: {
            count: 10,
            ok: 9,
            error: 1,
            duration_ms_sum: 50,
            duration_ms_max: 21,
            last_ms: 4,
          },
          by_path: {
            direct_socket: {
              path: 'direct_socket',
              admitted: 7,
              count: 7,
              ok: 6,
              error: 1,
              duration_ms_sum: 35,
              duration_ms_max: 18,
              last_ms: 4,
              monolithic_overruns: 2,
              rejected: 2,
              dropped: 1,
              expired: 1,
              terminal_completed: 4,
              terminal_failed: 1,
              terminal_rejected: 1,
              terminal_expired: 1,
              terminal_outcome_unknown: 0,
              fairness: { interactive: 5, bulk: 2 },
            },
            tunnel: {
              path: 'tunnel',
              admitted: 3,
              count: 3,
              ok: 3,
              error: 0,
              duration_ms_sum: 9,
              duration_ms_max: 5,
              last_ms: 2,
              monolithic_overruns: 1,
              rejected: 1,
              dropped: 1,
              expired: 0,
              terminal_completed: 2,
              terminal_failed: 0,
              terminal_rejected: 1,
              terminal_expired: 0,
              terminal_outcome_unknown: 0,
              fairness: { interactive: 2, bulk: 1 },
            },
          },
          ingress_by_type: {
            command: { message_type: 'command', count: 7 },
            tunnel_request: {
              message_type: 'tunnel.request',
              count: 3,
            },
            ping: { message_type: 'ping', count: 2 },
            other: { message_type: 'other', count: 1 },
          },
          queues: {
            direct_depth: 0,
            direct_oldest_age_ms: 0,
            direct_interactive_depth: 0,
            direct_bulk_depth: 0,
            direct_interactive_oldest_age_ms: 0,
            direct_bulk_oldest_age_ms: 0,
            direct_peak_depth: 4,
            direct_interactive_peak_depth: 3,
            direct_bulk_peak_depth: 1,
            tunnel_depth: 2,
            tunnel_interactive_depth: 1,
            tunnel_bulk_depth: 1,
            tunnel_oldest_age_ms: 120,
            tunnel_interactive_oldest_age_ms: 120,
            tunnel_bulk_oldest_age_ms: 80,
            tunnel_peak_depth: 3,
            tunnel_interactive_peak_depth: 2,
            tunnel_bulk_peak_depth: 1,
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
        getWindowsControlAdmissionStatus: () => ({
          writeQueue: {
            limits: { enabled: true },
            pending: {
              totalDepth: 2,
              totalBytes: 30,
              interactiveDepth: 1,
              interactiveBytes: 10,
              bulkDepth: 1,
              bulkBytes: 20,
              exemptDepth: 0,
              exemptBytes: 0,
              oldestAgeMs: 40,
            },
            admitted: { interactive: 4, bulk: 3, exempt: 2 },
            rejected: { depth: 1, bytes: 2 },
            expired: 3,
            highWater: { depth: 5, bytes: 90 },
          },
          ue4ssInbox: {
            limits: { enabled: true },
            pending: {
              totalRequests: 1,
              totalBytes: 20,
              interactiveRequests: 1,
              interactiveBytes: 20,
              bulkRequests: 0,
              bulkBytes: 0,
              exemptRequests: 0,
              exemptBytes: 0,
              oldestAgeMs: 50,
            },
            admitted: { interactive: 6, bulk: 2, exempt: 1 },
            rejected: { depth: 2, bytes: 1 },
            clientTimeouts: 4,
            expired: 5,
            highWater: { requests: 7, bytes: 120 },
          },
          ue4ssRuntime: {
            enabled: true,
            admittedInteractive: 5,
            admittedBulk: 2,
            expired: 3,
            deadlineMissing: 1,
            oversize: 2,
            bmfDispatchBlocked: 1,
            pendingBytes: 10,
            pendingBytesHighWater: 100,
            lastQueueAgeMs: 60,
            maxQueueAgeMs: 90,
          },
        }),
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
    expect(output).toContain('omegga_server_status_poll_total{status="ok"} 2');
    expect(output).toContain(
      'omegga_server_status_poll_duration_stat_seconds{statistic="avg"} 0.125',
    );
    expect(output).toContain(
      'omegga_console_command_sent_total{command="Server.Status"} 2',
    );
    expect(output).toContain(
      'omegga_console_command_sent_total{command="Chat.Command /TP"} 1',
    );
    for (const sample of [
      'omegga_ue4ss_admission_enabled{stage="write_queue"} 1',
      'omegga_ue4ss_queue_depth{stage="node_inbox",service_class="total"} 1',
      'omegga_ue4ss_queue_bytes{stage="ue4ss_runtime",service_class="total"} 10',
      'omegga_ue4ss_queue_oldest_age_milliseconds{stage="node_inbox"} 50',
      'omegga_ue4ss_queue_high_water{stage="node_inbox",unit="depth"} 7',
      'omegga_ue4ss_admitted_total{stage="ue4ss_runtime",service_class="interactive"} 5',
      'omegga_ue4ss_rejected_total{stage="ue4ss_runtime",reason="oversize"} 2',
      'omegga_ue4ss_expired_total{stage="node_inbox"} 5',
      'omegga_ue4ss_expired_total{stage="ue4ss_runtime"} 3',
      'omegga_ue4ss_deadline_missing_total{stage="ue4ss_runtime"} 1',
      'omegga_ue4ss_client_timeouts_total{stage="node_inbox"} 4',
      'omegga_ue4ss_queue_age_high_water_milliseconds{stage="ue4ss_runtime"} 90',
    ]) {
      expect(output).toContain(sample);
    }
    expect(output).not.toContain(
      'omegga_ue4ss_rejected_total{stage="ue4ss_runtime",reason="deadline_missing"}',
    );
    expect(output).toContain('bmf_runtime_status_up 1');
    expect(output).toContain('bmf_telemetry_up 1');
    expect(output).toContain('bmf_telemetry_schema_version 2');
    expect(output).toContain(
      '# TYPE bmf_player_registry_cache_first_enabled gauge',
    );
    expect(output).toContain(
      '# TYPE bmf_player_registry_cache_hits_total counter',
    );
    for (const sample of [
      'bmf_player_registry_cache_first_enabled 1',
      'bmf_player_registry_repair_enabled 1',
      'bmf_player_registry_legacy_discovery_enabled 0',
      'bmf_player_registry_cache_loaded 1',
      'bmf_player_registry_generation 9',
      'bmf_player_registry_entries 14',
      'bmf_player_registry_repair_running 0',
      'bmf_player_registry_repair_cooldown_milliseconds 15000',
      'bmf_player_registry_cache_hits_total 11',
      'bmf_player_registry_cache_misses_total 3',
      'bmf_player_registry_disk_loads_total 2',
      'bmf_player_registry_disk_load_failures_total 1',
      'bmf_player_registry_memory_syncs_total 7',
      'bmf_player_registry_persisted_syncs_total 5',
      'bmf_player_registry_controller_handle_hits_total 13',
      'bmf_player_registry_controller_handle_misses_total 4',
      'bmf_player_registry_targeted_resolutions_total 6',
      'bmf_player_registry_targeted_failures_total 2',
      'bmf_player_registry_broad_repairs_total 8',
      'bmf_player_registry_broad_repair_skipped_total 9',
      'bmf_player_registry_broad_repair_failures_total 1',
      'bmf_player_registry_broad_repair_matches_total 12',
      'bmf_player_registry_global_scans_total 10',
    ]) {
      expect(output).toContain(sample);
    }
    expect(output).toContain('brickadia_frame_telemetry_up 1');
    expect(output).toContain('brickadia_frame_telemetry_hook_registered 1');
    expect(output).toContain('brickadia_frame_telemetry_schema_version 2');
    expect(output).toContain('brickadia_frame_pacing_enabled 1');
    expect(output).toContain('brickadia_frame_pacing_config_valid 1');
    expect(output).toContain('brickadia_frame_pacing_target_fps 120');
    expect(output).toContain(
      'brickadia_frame_pacing_target_override_attempted 1',
    );
    expect(output).toContain(
      'brickadia_frame_pacing_target_override_applied 1',
    );
    expect(output).toContain('brickadia_frame_pacing_layout_calibrated 1');
    expect(output).toContain(
      'brickadia_frame_pacing_layout_adjustment_bytes -40',
    );
    expect(output).toContain('brickadia_frame_pacing_entry_signatures_valid 1');
    expect(output).toContain('brickadia_frame_pacing_observed_max_fps 120');
    expect(output).toContain(
      'brickadia_frame_pacing_observed_max_tick_rate 120',
    );
    expect(output).toContain('brickadia_frame_pacing_timer_policy_applied 1');
    expect(output).toContain(
      'brickadia_frame_pacing_timer_resolution_request_succeeded 1',
    );
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
    expect(output).toContain(
      'brickadia_frame_spikes_total{threshold_ms="100"} 1',
    );
    expect(output).toContain(
      'brickadia_frame_spike_last_delta_milliseconds 125.5',
    );
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
    expect(output).toContain(
      'bmf_socket_ingress_messages_total{type="command"} 7',
    );
    expect(output).toContain('bmf_native_event_drain_budget_enabled 1');
    expect(output).toContain(
      'bmf_native_event_drain_total{source="tree",outcome="attempted"} 9',
    );
    expect(output).toContain(
      'bmf_native_event_drain_total{source="tree",outcome="drained"} 6',
    );
    expect(output).toContain(
      'bmf_native_event_drain_total{source="zone",outcome="skipped"} 1',
    );
    expect(output).toContain(
      'bmf_native_event_drain_total{source="tree",outcome="overrun"} 1',
    );
    expect(output).toContain('bmf_native_event_queue_depth{source="tree"} 3');
    expect(output).not.toContain('bmf_native_event_queue_depth{source="zone"}');
    expect(output).toContain('bmf_native_event_drain_max_events_per_pump 4');
    expect(output).toContain(
      'bmf_socket_admitted_total{path="direct_socket"} 7',
    );
    expect(output).toContain('bmf_socket_unified_admission_enabled 1');
    expect(output).toContain(
      'bmf_socket_admission_outcome_total{path="direct_socket",outcome="dropped"} 1',
    );
    expect(output).toContain(
      'bmf_socket_terminal_total{path="direct_socket",state="failed"} 1',
    );
    expect(output).toContain(
      'bmf_socket_fairness_selection_total{path="tunnel",service_class="bulk"} 1',
    );
    expect(output).toContain(
      'bmf_socket_work_duration_milliseconds{path="tunnel",statistic="max"} 5',
    );
    expect(output).toContain(
      'bmf_game_thread_slice_duration_milliseconds{worker="socket_pump",statistic="avg"} 5',
    );
    expect(output).toContain(
      'bmf_game_thread_budget_exhausted_total{worker="socket_pump"} 4',
    );
    expect(output).toContain(
      'bmf_game_thread_budget_enforced{worker="socket_pump"} 1',
    );
    expect(output).toContain(
      'bmf_game_thread_admission_stopped_total{worker="socket_pump",reason="budget"} 3',
    );
    expect(output).toContain(
      'bmf_game_thread_dispatch_skipped_total{worker="socket_pump",path="tunnel",reason="budget"} 2',
    );
    expect(output).toContain(
      'bmf_game_thread_dispatch_skipped_total{worker="socket_pump",path="unified",reason="budget"} 5',
    );
    expect(output).toContain(
      'bmf_game_thread_monolithic_overrun_total{path="direct_socket"} 2',
    );
    expect(output).toContain(
      'bmf_socket_queue_depth{path="tunnel",service_class="interactive"} 1',
    );
    expect(output).toContain(
      'bmf_socket_queue_oldest_age_milliseconds{path="tunnel",service_class="total"} 120',
    );
    expect(output).toContain(
      'bmf_socket_queue_high_watermark{path="direct_socket",service_class="interactive"} 3',
    );
    expect(output).toContain('bmf_socket_configured_ingress_per_pump 16');
    expect(output).toContain('bmf_socket_effective_ingress_per_pump 2');
    expect(output).toContain('bmf_socket_ingress_last 2');
    expect(output).toContain('bmf_socket_direct_admitted_last 1');
    expect(output).toContain('bmf_socket_direct_ingress_cap_enabled 1');
    expect(output).toContain('bmf_socket_direct_ingress_cap_per_pump 2');
    expect(output).not.toContain('Ty');
    expect(output).not.toContain('player-id');
    expect(output).not.toContain('127.0.0.1"');

    rmSync(dir, { recursive: true, force: true });
  });
});
