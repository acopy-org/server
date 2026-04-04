import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

/// Message sent to a WebSocket connection for outbound delivery
pub type WsOutbound {
  OutboundBroadcast(id: String, content: BitArray, device: String, content_type: String, ts: Int)
  OutboundCopyIntent(device: String)
  OutboundCopyCancel(device: String)
  IntentTimeout
}

/// Messages handled by the registry actor
pub type RegistryMessage {
  Register(
    user_id: String,
    conn_id: String,
    subject: Subject(WsOutbound),
  )
  Unregister(conn_id: String)
  Broadcast(
    user_id: String,
    exclude_conn_id: String,
    id: String,
    content: BitArray,
    device: String,
    content_type: String,
    ts: Int,
  )
  BroadcastIntent(
    user_id: String,
    exclude_conn_id: String,
    device: String,
  )
  BroadcastCancel(
    user_id: String,
    exclude_conn_id: String,
    device: String,
  )
}

type RegistryState {
  RegistryState(
    // conn_id -> (user_id, subject)
    connections: dict.Dict(String, #(String, Subject(WsOutbound))),
    // user_id -> List(conn_id)
    user_conns: dict.Dict(String, List(String)),
  )
}

/// Start the connection registry actor.
pub fn start() -> Result(Subject(RegistryMessage), actor.StartError) {
  let initial_state =
    RegistryState(connections: dict.new(), user_conns: dict.new())

  let result =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Register a WebSocket connection for a user.
pub fn register(
  registry: Subject(RegistryMessage),
  user_id: String,
  conn_id: String,
  subject: Subject(WsOutbound),
) -> Nil {
  actor.send(registry, Register(user_id:, conn_id:, subject:))
}

/// Remove a WebSocket connection from the registry.
pub fn unregister(registry: Subject(RegistryMessage), conn_id: String) -> Nil {
  actor.send(registry, Unregister(conn_id:))
}

/// Broadcast copy intent to all connections for a user except the sender.
pub fn broadcast_intent(
  registry: Subject(RegistryMessage),
  user_id: String,
  exclude_conn_id: String,
  device: String,
) -> Nil {
  actor.send(registry, BroadcastIntent(user_id:, exclude_conn_id:, device:))
}

/// Broadcast copy cancel to all connections for a user except the sender.
pub fn broadcast_cancel(
  registry: Subject(RegistryMessage),
  user_id: String,
  exclude_conn_id: String,
  device: String,
) -> Nil {
  actor.send(registry, BroadcastCancel(user_id:, exclude_conn_id:, device:))
}

/// Broadcast clipboard content to all connections for a user except the sender.
pub fn broadcast(
  registry: Subject(RegistryMessage),
  user_id: String,
  exclude_conn_id: String,
  id: String,
  content: BitArray,
  device: String,
  content_type: String,
  ts: Int,
) -> Nil {
  actor.send(
    registry,
    Broadcast(user_id:, exclude_conn_id:, id:, content:, device:, content_type:, ts:),
  )
}

fn handle_message(
  state: RegistryState,
  msg: RegistryMessage,
) -> actor.Next(RegistryState, RegistryMessage) {
  case msg {
    Register(user_id:, conn_id:, subject:) -> {
      let connections =
        dict.insert(state.connections, conn_id, #(user_id, subject))
      let user_conns = case dict.get(state.user_conns, user_id) {
        Ok(existing) ->
          dict.insert(state.user_conns, user_id, [conn_id, ..existing])
        Error(_) -> dict.insert(state.user_conns, user_id, [conn_id])
      }
      actor.continue(RegistryState(connections:, user_conns:))
    }

    Unregister(conn_id:) -> {
      case dict.get(state.connections, conn_id) {
        Ok(#(user_id, _subject)) -> {
          let connections = dict.delete(state.connections, conn_id)
          let user_conns = case dict.get(state.user_conns, user_id) {
            Ok(conn_ids) -> {
              let filtered = list.filter(conn_ids, fn(id) { id != conn_id })
              case filtered {
                [] -> dict.delete(state.user_conns, user_id)
                _ -> dict.insert(state.user_conns, user_id, filtered)
              }
            }
            Error(_) -> state.user_conns
          }
          actor.continue(RegistryState(connections:, user_conns:))
        }
        Error(_) -> actor.continue(state)
      }
    }

    Broadcast(user_id:, exclude_conn_id:, id:, content:, device:, content_type:, ts:) -> {
      broadcast_to_others(state, user_id, exclude_conn_id, OutboundBroadcast(id:, content:, device:, content_type:, ts:))
    }

    BroadcastIntent(user_id:, exclude_conn_id:, device:) -> {
      broadcast_to_others(state, user_id, exclude_conn_id, OutboundCopyIntent(device:))
    }

    BroadcastCancel(user_id:, exclude_conn_id:, device:) -> {
      broadcast_to_others(state, user_id, exclude_conn_id, OutboundCopyCancel(device:))
    }
  }
}

fn broadcast_to_others(
  state: RegistryState,
  user_id: String,
  exclude_conn_id: String,
  msg: WsOutbound,
) -> actor.Next(RegistryState, RegistryMessage) {
  case dict.get(state.user_conns, user_id) {
    Ok(conn_ids) -> {
      list.each(conn_ids, fn(conn_id) {
        case conn_id != exclude_conn_id {
          True ->
            case dict.get(state.connections, conn_id) {
              Ok(#(_, subject)) -> process.send(subject, msg)
              Error(_) -> Nil
            }
          False -> Nil
        }
      })
      actor.continue(state)
    }
    Error(_) -> actor.continue(state)
  }
}
