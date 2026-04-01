import birl
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/option.{type Option, None, Some}
import mist
import server/auth/auth
import server/clipboard/clipboard_service
import server/web.{type Context}
import server/ws/protocol
import server/ws/registry.{type WsOutbound}
import youid/uuid

/// Per-connection WebSocket state
pub type WsState {
  WsState(
    user_id: Option(String),
    conn_id: String,
    subject: Subject(WsOutbound),
    ctx: Context,
  )
}

/// Upgrade an HTTP request to a WebSocket connection.
pub fn upgrade(
  req: request.Request(mist.Connection),
  ctx: Context,
) -> response.Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    handler: handle_message,
    on_init: fn(_conn) { init(ctx) },
    on_close: fn(state) { on_close(state) },
  )
}

fn init(
  ctx: Context,
) -> #(WsState, Option(process.Selector(WsOutbound))) {
  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(subject)

  let state =
    WsState(
      user_id: None,
      conn_id: uuid.v4_string(),
      subject: subject,
      ctx: ctx,
    )

  #(state, Some(selector))
}

fn on_close(state: WsState) -> Nil {
  registry.unregister(state.ctx.registry, state.conn_id)
}

fn handle_message(
  state: WsState,
  msg: mist.WebsocketMessage(WsOutbound),
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsOutbound) {
  case msg {
    mist.Binary(data) -> handle_binary(state, data, conn)
    mist.Custom(outbound) -> handle_outbound(state, outbound, conn)
    mist.Closed | mist.Shutdown -> {
      registry.unregister(state.ctx.registry, state.conn_id)
      mist.stop()
    }
    mist.Text(_) -> {
      send_error(conn, 400, "Text frames not supported, use binary")
      mist.continue(state)
    }
  }
}

fn handle_binary(
  state: WsState,
  data: BitArray,
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsOutbound) {
  case protocol.decode(data) {
    Error(reason) -> {
      send_error(conn, 400, reason)
      mist.continue(state)
    }
    Ok(protocol.AuthMsg(token:)) -> handle_auth(state, token, conn)
    Ok(protocol.ClipboardPushMsg(content:, device:, content_type:)) ->
      handle_clipboard_push(state, content, device, content_type, conn)
    Ok(protocol.PingMsg) -> {
      let _ = mist.send_binary_frame(conn, protocol.encode(protocol.PongMsg))
      mist.continue(state)
    }
    Ok(_) -> {
      send_error(conn, 400, "Unexpected message type")
      mist.continue(state)
    }
  }
}

fn handle_auth(
  state: WsState,
  token: String,
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsOutbound) {
  case auth.verify_token(token, state.ctx.jwt_secret) {
    Ok(user_id) -> {
      registry.register(
        state.ctx.registry,
        user_id,
        state.conn_id,
        state.subject,
      )
      let new_state = WsState(..state, user_id: Some(user_id))
      send_ack(conn)
      mist.continue(new_state)
    }
    Error(_) -> {
      send_error(conn, 401, "Invalid or expired token")
      mist.stop()
    }
  }
}

fn handle_clipboard_push(
  state: WsState,
  content: BitArray,
  device: String,
  content_type: String,
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsOutbound) {
  case state.user_id {
    None -> {
      send_error(conn, 401, "Not authenticated")
      mist.continue(state)
    }
    Some(user_id) -> {
      case bit_array.byte_size(content) > 10_485_760 {
        True -> {
          send_error(conn, 413, "Clipboard content too large (max 10 MB)")
          mist.continue(state)
        }
        False -> {
          let _ =
            clipboard_service.save_entry(state.ctx.db, user_id, content, device, content_type)
          let ts = birl.now() |> birl.to_unix
          registry.broadcast(
            state.ctx.registry,
            user_id,
            state.conn_id,
            content,
            device,
            content_type,
            ts,
          )
          send_ack(conn)
          mist.continue(state)
        }
      }
    }
  }
}

fn handle_outbound(
  state: WsState,
  outbound: WsOutbound,
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsOutbound) {
  case outbound {
    registry.OutboundBroadcast(content:, device:, content_type:, ts:) -> {
      let frame =
        protocol.encode(protocol.ClipboardBroadcastMsg(content:, device:, content_type:, ts:))
      let _ = mist.send_binary_frame(conn, frame)
      mist.continue(state)
    }
  }
}

fn send_ack(conn: mist.WebsocketConnection) -> Nil {
  let _ = mist.send_binary_frame(conn, protocol.encode(protocol.AckMsg))
  Nil
}

fn send_error(conn: mist.WebsocketConnection, code: Int, msg: String) -> Nil {
  let _ =
    mist.send_binary_frame(conn, protocol.encode(protocol.ErrorMsg(code:, msg:)))
  Nil
}
