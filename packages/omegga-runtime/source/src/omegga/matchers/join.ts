import Player from '@omegga/player';
import { MatchGenerator } from './types';

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

  // patterns to match PlayerState and PlayerController objects in GetAll commands
  const stateRegExp =
    /BP_PlayerState_C .+?PersistentLevel\.(?<state>BP_PlayerState_C_\d+)\.UserName = (?<name>.+)$/;
  const controllerRegExp =
    /BP_PlayerState_C .+?PersistentLevel\.(?<state>BP_PlayerState_C_\d+)\.Owner = .*?BP_PlayerController_C'.+?:PersistentLevel.(?<controller>BP_PlayerController_C_\d+)'/;
  const checkpointRegExp =
    /^Ruleset .+? (?:loading|no) saved checkpoint for player (?<name>.+) \((?<id>.+)\)$/;
  let playerStateLookupScheduled = false;

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

  const requestPlayerStateLookup = () => {
    if (!joiningPlayers.length) return;
    omegga.writeln('GetAll BRPlayerState UserName');
  };

  const schedulePlayerStateLookup = () => {
    if (!joiningPlayers.length || playerStateLookupScheduled) return;
    playerStateLookupScheduled = true;
    requestPlayerStateLookup();
    setTimeout(requestPlayerStateLookup, 250).unref?.();
    setTimeout(() => {
      requestPlayerStateLookup();
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
      } else if (joiningPlayers.length) {
        const stateMatch = line.match(stateRegExp);
        const controllerMatch = line.match(controllerRegExp);

        // this line matches our PlayerName -> PlayerState pattern
        if (stateMatch) {
          const { name, state } = stateMatch.groups;

          // find the joining player that has a matching name
          const player = joiningPlayers.find(p => p.name === name);

          // check if another player is already using this state or if there's any joining player with this name
          if (!player || omegga.players.some(p => p.state === state)) return;

          // this player owns this state, find the controller now
          player.state = state;
          omegga.writeln(`GetAll BRPlayerState Owner Name=${state}`);

          // this line matches our PlayerState -> PlayerController pattern
        } else if (controllerMatch) {
          const { controller, state } = controllerMatch.groups;

          // find the joining player that has a matching state
          const player = joiningPlayers.find(p => p.state === state);

          // no player found
          if (!player) return;

          // assign the controller and state, remove the player from the joining players
          player.controller = controller;
          player.state = state;
          joiningPlayers.splice(joiningPlayers.indexOf(player), 1);

          if (player.player) {
            player.player.controller = controller;
            player.player.state = state;
            emitRawPlayers();
            return;
          }

          // return the newly joined player
          return new Player(
            omegga,
            player.name,
            player.displayName,
            player.id,
            player.controller,
            player.state,
          );
        }
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
        if (player.controller) existingPlayer.controller = player.controller;
        if (player.state) existingPlayer.state = player.state;
        ensurePendingStateLookup(existingPlayer);
        emitRawPlayers();
        return;
      }

      omegga.emit('join', player);
      omegga.players.push(player);
      ensurePendingStateLookup(player);
      emitRawPlayers();
    },
  };
};

export default join;
