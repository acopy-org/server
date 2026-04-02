import birl
import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/json
import gleam/string
import server/auth/auth
import server/clipboard/clipboard_service
import server/web.{type Context}
import server/ws/registry
import wisp

pub fn handle_request(
  req: wisp.Request,
  ctx: Context,
  path: List(String),
) -> wisp.Response {
  case path {
    ["push"] -> push(req, ctx)
    _ -> wisp.not_found()
  }
}

fn push(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use user_id <- auth.require_auth(req, ctx.jwt_secret)

  let device = case request.get_header(req, "x-acopy-device") {
    Ok(d) -> d
    Error(_) -> "unknown"
  }
  let content_type = case request.get_header(req, "x-acopy-content-type") {
    Ok(ct) -> ct
    Error(_) -> "application/octet-stream"
  }

  // Read raw body
  use body <- wisp.require_bit_array_body(req)

  case bit_array.byte_size(body) > 10_485_760 {
    True ->
      json.object([#("error", json.string("Content too large (max 10 MB)"))])
      |> json.to_string
      |> wisp.json_response(413)
    False -> {
      case clipboard_service.save_entry(ctx.db, user_id, body, device, content_type) {
        Ok(id) -> {
          let ts = birl.now() |> birl.to_unix
          // Broadcast to all WebSocket connections (exclude_conn_id="" means broadcast to all)
          registry.broadcast(
            ctx.registry,
            user_id,
            "",
            id,
            body,
            device,
            content_type,
            ts,
          )
          json.object([#("id", json.string(id))])
          |> json.to_string
          |> wisp.json_response(201)
        }
        Error(e) -> {
          let _ = string.inspect(e)
          wisp.internal_server_error()
        }
      }
    }
  }
}
