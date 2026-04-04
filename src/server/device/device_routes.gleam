import gleam/dynamic/decode
import gleam/http
import gleam/json
import server/auth/auth
import server/device/device_service
import server/web.{type Context}
import wisp

pub fn handle_request(
  req: wisp.Request,
  ctx: Context,
  path: List(String),
) -> wisp.Response {
  case path {
    [] -> list_devices(req, ctx)
    [device_id] ->
      case req.method {
        http.Patch -> update_device(req, ctx, device_id)
        http.Delete -> delete_device(req, ctx, device_id)
        _ -> wisp.method_not_allowed(allowed: [http.Patch, http.Delete])
      }
    _ -> wisp.not_found()
  }
}

fn list_devices(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  use user_id <- auth.require_auth(req, ctx.jwt_secret)

  case device_service.get_devices(ctx.db, user_id) {
    Ok(devices) ->
      json.object([
        #("devices", json.array(devices, device_to_json)),
      ])
      |> json.to_string
      |> wisp.json_response(200)
    Error(_) -> wisp.internal_server_error()
  }
}

fn update_device(
  req: wisp.Request,
  ctx: Context,
  device_id: String,
) -> wisp.Response {
  use user_id <- auth.require_auth(req, ctx.jwt_secret)
  use json_body <- wisp.require_json(req)

  let decoder = {
    use image_compression <- decode.field("image_compression", decode.int)
    decode.success(image_compression)
  }

  case decode.run(json_body, decoder) {
    Ok(image_compression) -> {
      let polar_enabled = ctx.polar_webhook_secret != ""
      case
        device_service.update_device_config(
          ctx.db,
          user_id,
          device_id,
          image_compression,
          polar_enabled,
        )
      {
        Ok(device) ->
          device_to_json(device)
          |> json.to_string
          |> wisp.json_response(200)
        Error(device_service.PlanRequired) ->
          json.object([
            #("error", json.string("Pro plan required for device configuration")),
          ])
          |> json.to_string
          |> wisp.json_response(403)
        Error(device_service.DeviceNotFound) ->
          json.object([#("error", json.string("Device not found"))])
          |> json.to_string
          |> wisp.json_response(404)
        Error(_) -> wisp.internal_server_error()
      }
    }
    Error(_) -> wisp.unprocessable_content()
  }
}

fn delete_device(
  req: wisp.Request,
  ctx: Context,
  device_id: String,
) -> wisp.Response {
  use user_id <- auth.require_auth(req, ctx.jwt_secret)

  case device_service.delete_device(ctx.db, user_id, device_id) {
    Ok(_) ->
      json.object([#("ok", json.bool(True))])
      |> json.to_string
      |> wisp.json_response(200)
    Error(_) -> wisp.internal_server_error()
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
