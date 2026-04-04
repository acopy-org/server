import birl
import gleam/bit_array
import gleam/erlang/process.{type Subject, type Timer}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import mist
import server/auth/auth
import server/clipboard/clipboard_service
import server/device/device_service
import server/web.{type Context}
import server/ws/protocol
import server/ws/registry.{type WsOutbound}
import youid/uuid

@external(erlang, "io", "format")
fn erlang_format(msg: String) -> Nil

/// Timeout for copy intent in milliseconds (30 seconds)
const intent_timeout_ms = 30_000

/// Per-connection WebSocket state
pub type WsState {
  WsState(
    user_id: Option(String),
    conn_id: String,
    subject: Subject(WsOutbound),
    ctx: Context,
    /// Pending copy intent: (timestamp_ms, device_name)
    pending_intent: Option(#(Int, String)),
    /// Timer handle for intent timeout, so we can cancel it on push
    intent_timer: Option(Timer),
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
      pending_intent: None,
      intent_timer: None,
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
  let _ = erlang_format("handle_binary: data_size=" <> string.inspect(bit_array.byte_size(data)) <> "\n")
  case protocol.decode(data) {
    Error(reason) -> {
      let _ = erlang_format("decode_error: " <> reason <> "\n")
      send_error(conn, 400, reason)
      mist.continue(state)
    }
    Ok(protocol.AuthMsg(token:)) -> handle_auth(state, token, conn)
    Ok(protocol.ClipboardPushMsg(content:, device:, content_type:)) ->
      handle_clipboard_push(state, content, device, content_type, conn)
    Ok(protocol.CopyIntentMsg(device:)) ->
      handle_copy_intent(state, device, conn)
    Ok(protocol.CopyCancelMsg) ->
      handle_copy_cancel(state, conn)
    Ok(protocol.PingMsg) -> {
      let _ = mist.send_binary_frame(conn, protocol.encode(protocol.PongMsg))
      mist.continue(state)
    }
    Ok(other) -> {
      let _ = erlang_format("unexpected_msg: " <> string.inspect(other) <> "\n")
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

fn handle_copy_intent(
  state: WsState,
  device: String,
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsOutbound) {
  case state.user_id {
    None -> {
      send_error(conn, 401, "Not authenticated")
      mist.continue(state)
    }
    Some(user_id) -> {
      // Cancel any existing intent timer
      case state.intent_timer {
        Some(timer) -> { let _ = process.cancel_timer(timer) Nil }
        None -> Nil
      }
      let now_ms = birl.now() |> birl.to_unix_milli
      let timer = process.send_after(state.subject, intent_timeout_ms, registry.IntentTimeout)
      let _ = erlang_format("copy_intent: " <> user_id <> " " <> device <> " at " <> int.to_string(now_ms) <> "\n")
      registry.broadcast_intent(state.ctx.registry, user_id, state.conn_id, device)
      let new_state = WsState(..state, pending_intent: Some(#(now_ms, device)), intent_timer: Some(timer))
      send_ack(conn)
      mist.continue(new_state)
    }
  }
}

fn handle_copy_cancel(
  state: WsState,
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, WsOutbound) {
  case state.pending_intent, state.user_id {
    Some(#(_, device)), Some(user_id) -> {
      case state.intent_timer {
        Some(timer) -> { let _ = process.cancel_timer(timer) Nil }
        None -> Nil
      }
      let _ = erlang_format("copy_cancel: " <> state.conn_id <> "\n")
      registry.broadcast_cancel(state.ctx.registry, user_id, state.conn_id, device)
      let new_state = WsState(..state, pending_intent: None, intent_timer: None)
      send_ack(conn)
      mist.continue(new_state)
    }
    _, _ -> {
      send_error(conn, 400, "No pending copy intent")
      mist.continue(state)
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
          // Enforce device limits
          let polar_enabled = state.ctx.polar_webhook_secret != ""
          case device_service.ensure_device(state.ctx.db, user_id, device, polar_enabled) {
            Error(device_service.DeviceLimitReached) -> {
              send_error(conn, 403, "Device limit reached. Upgrade to Pro for unlimited devices.")
              mist.continue(state)
            }
            _ -> {
          // Calculate processing time if there was a pending copy intent
          let now_ms = birl.now() |> birl.to_unix_milli
          let processing_ms = case state.pending_intent {
            Some(#(intent_ts, _)) -> {
              let delta = now_ms - intent_ts
              let _ = erlang_format("copy_processing_ms: " <> int.to_string(delta) <> " " <> user_id <> " " <> device <> "\n")
              Some(delta)
            }
            None -> None
          }
          // Cancel intent timer if active
          case state.intent_timer {
            Some(timer) -> { let _ = process.cancel_timer(timer) Nil }
            None -> Nil
          }
          let content_size = bit_array.byte_size(content)
          let _ = erlang_format("clipboard_push: " <> user_id <> " " <> device <> " " <> content_type <> " " <> string.inspect(content_size) <> "b\n")
          let id = case
            clipboard_service.save_entry(state.ctx.db, user_id, content, device, content_type)
          {
            Ok(saved_id) -> {
              let _ = erlang_format("saved: " <> saved_id <> "\n")
              saved_id
            }
            Error(e) -> {
              let _ = erlang_format("save_error: " <> string.inspect(e) <> "\n")
              ""
            }
          }
          let ts = birl.now() |> birl.to_unix
          registry.broadcast(
            state.ctx.registry,
            user_id,
            state.conn_id,
            id,
            content,
            device,
            content_type,
            ts,
          )
          // Include processing_ms in ack if intent was pending
          case processing_ms {
            Some(ms) -> send_ack_with_processing(conn, ms)
            None -> send_ack(conn)
          }
          let new_state = WsState(..state, pending_intent: None, intent_timer: None)
          mist.continue(new_state)
            }
          }
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
    registry.OutboundBroadcast(id:, content:, device:, content_type:, ts:) -> {
      let frame =
        protocol.encode_no_compress(protocol.ClipboardBroadcastMsg(id:, content:, device:, content_type:, ts:))
      let _ = mist.send_binary_frame(conn, frame)
      mist.continue(state)
    }
    registry.OutboundCopyIntent(device:) -> {
      let frame = protocol.encode_no_compress(protocol.CopyIntentMsg(device:))
      let _ = mist.send_binary_frame(conn, frame)
      mist.continue(state)
    }
    registry.OutboundCopyCancel(device: _) -> {
      let frame = protocol.encode_no_compress(protocol.CopyCancelMsg)
      let _ = mist.send_binary_frame(conn, frame)
      mist.continue(state)
    }
    registry.IntentTimeout -> {
      case state.pending_intent {
        Some(_) -> {
          let _ = erlang_format("copy_intent_timeout: " <> state.conn_id <> "\n")
          send_error(conn, 408, "Copy intent timed out")
          let new_state = WsState(..state, pending_intent: None, intent_timer: None)
          mist.continue(new_state)
        }
        // Intent was already fulfilled, ignore stale timeout
        None -> mist.continue(state)
      }
    }
  }
}

fn send_ack(conn: mist.WebsocketConnection) -> Nil {
  let _ = mist.send_binary_frame(conn, protocol.encode(protocol.AckMsg))
  Nil
}

fn send_ack_with_processing(conn: mist.WebsocketConnection, processing_ms: Int) -> Nil {
  let _ = mist.send_binary_frame(conn, protocol.encode(protocol.AckWithProcessingMsg(processing_ms:)))
  Nil
}

fn send_error(conn: mist.WebsocketConnection, code: Int, msg: String) -> Nil {
  let _ =
    mist.send_binary_frame(conn, protocol.encode(protocol.ErrorMsg(code:, msg:)))
  Nil
}
