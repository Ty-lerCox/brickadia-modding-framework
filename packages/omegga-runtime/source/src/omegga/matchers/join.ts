import Player from '@omegga/player';
import { MatchGenerator } from './types';

export type StrictPlayerBindingRecord = {
  uuid: string;
  controller: string;
  state: string;
};

const parseFields = (value: string) => {
  const fields: Record<string, string> = {};
  for (const part of value.split('|')) {
    const separator = part.indexOf('=');
    if (separator >= 0) fields[part.slice(0, separator)] = part.slice(separator + 1);
  }
  return fields;
};

const outputText = (response: unknown) => {
  if (!response || typeof response !== 'object') return String(response ?? '');
  if ('response' in response)
    return String((response as { response?: unknown }).response ?? '');
  const chunks = (response as { chunks?: unknown }).chunks;
  if (!Array.isArray(chunks)) return String(response);
  return chunks
    .map(chunk =>
      chunk && typeof chunk === 'object' && 'line' in chunk
        ? String((chunk as { line?: unknown }).line ?? '')
        : '',
    )
    .filter(Boolean)
    .join('\n');
};

export const parseStrictPlayerBindingRecords = (
  response: unknown,
): StrictPlayerBindingRecord[] => {
  const stableUuid =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const candidates: StrictPlayerBindingRecord[] = [];
  for (const line of outputText(response).split(/\r?\n/)) {
    const match = line.match(/^player_binding_\d+=(.*)$/);
    if (!match) continue;
    const fields = parseFields(match[1]);
    const uuid = String(fields.uuid ?? '').trim().toLowerCase();
    const controller = fields.controller?.match(/BP_PlayerController_C_\d+/)?.[0];
    const state = fields.state?.match(/BP_PlayerState_C_\d+/)?.[0];
    if (stableUuid.test(uuid) && controller && state)
      candidates.push({ uuid, controller, state });
  }
  const counts = <T>(values: T[]) => {
    const result = new Map<T, number>();
    for (const value of values) result.set(value, (result.get(value) ?? 0) + 1);
    return result;
  };
  const uuidCounts = counts(candidates.map(record => record.uuid));
  const controllerCounts = counts(candidates.map(record => record.controller));
  const stateCounts = counts(candidates.map(record => record.state));
  return candidates.filter(
    record =>
      uuidCounts.get(record.uuid) === 1 &&
      controllerCounts.get(record.controller) === 1 &&
      stateCounts.get(record.state) === 1,
  );
};

const join: MatchGenerator<Player> = omegga => {
  type UserJoinInfo = {
    counter: string;
    UserName?: string;
    UserId?: string;
    DisplayName?: string;
  };

  // username + id and a log counter to keep track of actual join messages
  const userJoinInfo: UserJoinInfo[] = [];

  // username + id to get player state and controller
  const joiningPlayers: {
    displayName: string;
    name: string;
    id: string;
    state?: string;
    controller?: string;
    player?: Player;
  }[] = [];

  const checkpointRegExp =
    /^Ruleset .+? (?:loading|no) saved checkpoint for player (?<name>.+) \((?<id>.+)\)$/;
  let playerStateLookupScheduled = false;
  let controllerLookupTimer: NodeJS.Timeout | null = null;
  let controllerLookupInFlight = false;
  let lastControllerLookupKey = '';
  let nextLookupIdentity = 0;
  const lookupIdentities = new WeakMap<Player, number>();

  const bindControllerIdentity = (
    player: Player,
    controller: string,
    state: string,
  ): boolean => {
    const extended = omegga as typeof omegga & {
      bindPlayerControllerIdentity?: (
        player: Player,
        controller: string,
        state: string,
      ) => boolean;
      verifyPrivateControllerIdentity?: (player: Player) => boolean;
    };
    if (typeof extended.bindPlayerControllerIdentity === 'function') {
      return extended.bindPlayerControllerIdentity(player, controller, state);
    }
    player.controller = controller;
    player.state = state;
    return extended.verifyPrivateControllerIdentity?.(player) === true;
  };

  const getJoinInfo = (counter: string) => {
    let joinData = userJoinInfo.find(l => l.counter === counter);

    if (!joinData) {
      joinData = { counter };
      userJoinInfo.push(joinData);
    }

    return joinData;
  };

  const findJoinInfoForName = (counter: string, name: string) => {
    const joinData = userJoinInfo.find(l => l.counter === counter);

    if (
      joinData &&
      (joinData.DisplayName === name || joinData.UserName === name)
    )
      return joinData;

    return userJoinInfo.find(
      l => l.DisplayName === name || l.UserName === name,
    );
  };

  const emitRawPlayers = () =>
    omegga.emit(
      'plugin:players:raw',
      omegga.players.map(p => p.raw()),
    );

  const schedulePlayerStateLookup = () => {
    if (!joiningPlayers.length || playerStateLookupScheduled) return;
    playerStateLookupScheduled = true;
    setTimeout(() => {
      playerStateLookupScheduled = false;
    }, 1000).unref?.();
  };

  const ensurePendingStateLookup = (player: Player) => {
    if (player.controller && player.state) return;
    const pending = joiningPlayers.find(
      p => p.id === player.id || p.name === player.name,
    );
    if (pending) {
      pending.player = pending.player ?? player;
    } else {
      joiningPlayers.push({
        displayName: player.displayName,
        name: player.name,
        id: player.id,
        player,
      });
    }
    schedulePlayerStateLookup();
  };

  const unresolvedControllerSet = () => {
    const players = omegga.players.filter(player => !player.controller);
    const key = players
      .map(player => {
        let identity = lookupIdentities.get(player);
        if (identity === undefined) {
          identity = ++nextLookupIdentity;
          lookupIdentities.set(player, identity);
        }
        return identity;
      })
      .sort((a, b) => a - b)
      .join(',');
    return { key, players };
  };

  const reconcileExactControllerBindings = async () => {
    const execute = (
      omegga as typeof omegga & {
        execControlCommandWithOutput?: (
          command: string,
          timeoutMs?: number,
        ) => Promise<unknown>;
      }
    ).execControlCommandWithOutput;
    if (typeof execute !== 'function') return false;
    const unresolved = omegga.players.filter(player => !player.controller);
    if (!unresolved.length) return true;
    const response = await execute.call(
      omegga,
      'Omegga.Bridge.ListPlayerBindings',
      5000,
    );
    const records = parseStrictPlayerBindingRecords(response);
    const assignments = new Map<Player, StrictPlayerBindingRecord>();
    for (const player of unresolved) {
      const uuid = String(player.id || '').trim().toLowerCase();
      const matches = records.filter(record => record.uuid === uuid);
      if (matches.length === 1) assignments.set(player, matches[0]);
    }
    for (const [player, record] of assignments) {
      if (!bindControllerIdentity(player, record.controller, record.state)) continue;
      const pending = joiningPlayers.find(
        candidate => candidate.player === player || candidate.id === player.id,
      );
      if (pending) joiningPlayers.splice(joiningPlayers.indexOf(pending), 1);
    }
    if (assignments.size) emitRawPlayers();
    return assignments.size === unresolved.length;
  };

  const scheduleControllerLookup = () => {
    if (process.env.OMEGGA_BMF_JOIN_RECONCILIATION_ENABLED === '0') return;
    const unresolved = unresolvedControllerSet();
    if (!unresolved.key) {
      lastControllerLookupKey = '';
      return;
    }
    if (
      unresolved.key === lastControllerLookupKey ||
      controllerLookupTimer ||
      controllerLookupInFlight
    )
      return;
    controllerLookupTimer = setTimeout(() => {
      controllerLookupTimer = null;
      const current = unresolvedControllerSet();
      if (!current.key || current.key === lastControllerLookupKey) return;
      lastControllerLookupKey = current.key;
      controllerLookupInFlight = true;
      void reconcileExactControllerBindings()
        .catch(() => false)
        .finally(() => {
          controllerLookupInFlight = false;
          scheduleControllerLookup();
        });
    }, 1000);
    controllerLookupTimer.unref?.();
  };

  return {
    // listen for join events and wait for PlayerController info
    pattern(line, logMatch) {
      if (logMatch) {
        const { generator, counter, data } = logMatch.groups;
        let joinData = userJoinInfo.find(l => l.counter === counter);

        // LogServerList includes the new user information
        if (generator === 'LogServerList') {
          // create joindata if it doesn't exist
          joinData = getJoinInfo(counter);

          // match on username or user id
          const match = data.match(
            /^(?<field>UserName|UserId|DisplayName): (?<value>.+)$/,
          );

          // put that value in the join data
          if (match) {
            joinData[
              match.groups.field as 'UserName' | 'UserId' | 'DisplayName'
            ] = match.groups.value;
          }

          // newer Brickadia logs put the player id in the checkpoint line
        } else if (generator === 'LogBrickadia') {
          const match = data.match(checkpointRegExp);

          if (match) {
            const { name, id } = match.groups;
            joinData = getJoinInfo(counter);

            if (!joinData.UserName) joinData.UserName = name;
            if (!joinData.DisplayName) joinData.DisplayName = name;
            joinData.UserId = id;
          }

          // LogNet lets us know the player successfully joined
        } else if (generator == 'LogNet') {
          // find which player joined
          const match = data.match(/^Join succeeded: (.+)$/);

          // make sure this joindata corresponds to this player
          // TODO: [BRICKADIA] display name used here instead of username...
          if (match && (joinData = findJoinInfoForName(counter, match[1]))) {
            // remove that player from our buffer
            userJoinInfo.splice(userJoinInfo.indexOf(joinData), 1);

            const displayName = joinData.DisplayName || match[1];
            const name = joinData.UserName || match[1];

            // without a player id, role and plugin lookups cannot resolve the player
            if (!joinData.UserId) return;

            const existingPlayer = omegga.players.find(
              p => p.id === joinData.UserId || p.name === name,
            );
            if (existingPlayer) {
              ensurePendingStateLookup(existingPlayer);
              return;
            }

            const player = new Player(
              omegga,
              name,
              displayName,
              joinData.UserId,
              '',
              '',
            );

            // found joined player, now we need to find the BRPlayerState
            joiningPlayers.push({
              displayName,
              name,
              id: joinData.UserId,
              player,
            });

            // get the state of all players so we can determine which is this player
            // TODO: maybe also use the ReplicatedJoinTime, which matches the time for these logs
            schedulePlayerStateLookup();

            // return the player now so plugins can resolve them by id immediately
            return player;
          }
        }

        // only match state and controllers if we have joining players
      }
    },
    // when there's a match, emit a join event and add the player to the player list
    callback(player) {
      const existingPlayer = omegga.players.find(
        p =>
          (player.id && p.id === player.id) ||
          p.name === player.name ||
          p.displayName === player.displayName,
      );

      if (existingPlayer) {
        existingPlayer.name = player.name;
        existingPlayer.displayName = player.displayName;
        existingPlayer.id = player.id;
        if (player.controller && player.state) {
          bindControllerIdentity(existingPlayer, player.controller, player.state);
        }
        ensurePendingStateLookup(existingPlayer);
        scheduleControllerLookup();
        emitRawPlayers();
        return;
      }

      omegga.emit('join', player);
      omegga.players.push(player);
      if (player.controller && player.state) {
        bindControllerIdentity(player, player.controller, player.state);
      }
      ensurePendingStateLookup(player);
      scheduleControllerLookup();
      emitRawPlayers();
    },
  };
};

export default join;
