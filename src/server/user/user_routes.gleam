import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/json
import server/auth/auth
import server/clipboard/clipboard_service
import server/device/device_service
import server/subscription/subscription_service
import server/user/user
import server/user/user_service
import server/web.{type Context}
import wisp

pub fn handle_request(
  req: wisp.Request,
  ctx: Context,
  path: List(String),
) -> wisp.Response {
  case path {
    ["register"] -> register(req, ctx)
    ["login"] -> login(req, ctx)
    ["me"] -> me(req, ctx)
    _ -> wisp.not_found()
  }
}

fn register(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use json_body <- wisp.require_json(req)

  case decode.run(json_body, user.register_decoder()) {
    Ok(register_req) ->
      case user_service.register(ctx.db, register_req.email, register_req.password) {
        Ok(new_user) ->
          user.user_to_json(new_user)
          |> json.to_string
          |> wisp.json_response(201)
        Error(user_service.EmailAlreadyExists) ->
          json.object([#("error", json.string("Email already exists"))])
          |> json.to_string
          |> wisp.json_response(409)
        Error(_) -> wisp.internal_server_error()
      }
    Error(_) -> wisp.unprocessable_content()
  }
}

fn login(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use json_body <- wisp.require_json(req)

  case decode.run(json_body, user.login_decoder()) {
    Ok(login_req) ->
      case user_service.login(ctx.db, login_req.email, login_req.password) {
        Ok(authenticated_user) -> {
          let token = auth.generate_token(authenticated_user.id, ctx.jwt_secret)
          json.object([
            #("token", json.string(token)),
            #("user", user.user_to_json(authenticated_user)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        }
        Error(user_service.InvalidCredentials) ->
          json.object([#("error", json.string("Invalid email or password"))])
          |> json.to_string
          |> wisp.json_response(401)
        Error(_) -> wisp.internal_server_error()
      }
    Error(_) -> wisp.unprocessable_content()
  }
}

fn me(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  use user_id <- auth.require_auth(req, ctx.jwt_secret)

  case user_service.get_user_by_id(ctx.db, user_id) {
    Ok(found_user) -> {
      let entries = case clipboard_service.get_entries_by_user(ctx.db, user_id) {
        Ok(e) -> e
        Error(_) -> []
      }
      let polar_enabled = ctx.polar_webhook_secret != ""
      let plan =
        subscription_service.get_effective_plan(ctx.db, user_id, polar_enabled)
      let devices = case device_service.get_devices(ctx.db, user_id) {
        Ok(d) -> d
        Error(_) -> []
      }
      json.object([
        #("id", json.string(found_user.id)),
        #("email", json.string(found_user.email)),
        #("created_at", json.string(found_user.created_at)),
        #(
          "clipboard_entries",
          json.array(entries, clipboard_entry_to_json),
        ),
        #("plan", json.string(subscription_service.plan_to_string(plan))),
        #("max_devices", json.int(subscription_service.max_devices(plan))),
        #("devices", json.array(devices, device_to_json)),
        #("polar_enabled", json.bool(polar_enabled)),
      ])
      |> json.to_string
      |> wisp.json_response(200)
    }
    Error(_) ->
      json.object([#("error", json.string("User not found"))])
      |> json.to_string
      |> wisp.json_response(401)
  }
}

fn device_to_json(device: device_service.Device) -> json.Json {
  json.object([
    #("id", json.string(device.id)),
    #("device_name", json.string(device.device_name)),
    #("image_compression", json.int(device.image_compression)),
    #("created_at", json.string(device.created_at)),
    #("last_seen_at", json.string(device.last_seen_at)),
  ])
}

fn clipboard_entry_to_json(entry: clipboard_service.ClipboardEntry) -> json.Json {
  json.object([
    #("id", json.string(entry.id)),
    #("content", json.string(bit_array.base16_encode(entry.content))),
    #("content_type", json.string(entry.content_type)),
    #("device_name", json.string(entry.device_name)),
    #("created_at", json.string(entry.created_at)),
  ])
}
