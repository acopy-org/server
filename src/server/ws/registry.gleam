import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

/// Message sent to a WebSocket connection for outbound delivery
pub type WsOutbound {
  OutboundBroadcast(id: String, content: BitArray, device: String, content_type: String, ts: Int)
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
      case dict.get(state.user_conns, user_id) {
        Ok(conn_ids) -> {
          list.each(conn_ids, fn(conn_id) {
            case conn_id != exclude_conn_id {
              True ->
                case dict.get(state.connections, conn_id) {
                  Ok(#(_, subject)) ->
                    process.send(subject, OutboundBroadcast(id:, content:, device:, content_type:, ts:))
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
  }
}
