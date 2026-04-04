import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/option.{None, Some}
import server/auth/auth
import server/device/device_service
import server/web.{type Context}
import server/ws/registry
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
    use device_name <- decode.optional_field(
      "device_name",
      None,
      decode.string |> decode.map(Some),
    )
    use image_compression <- decode.optional_field(
      "image_compression",
      None,
      decode.int |> decode.map(Some),
    )
    decode.success(#(device_name, image_compression))
  }

  case decode.run(json_body, decoder) {
    Ok(#(Some(new_name), maybe_compression)) ->
      case device_service.rename_device(ctx.db, user_id, device_id, new_name) {
        Ok(#(old_name, device)) -> {
          registry.broadcast_device_renamed(
            ctx.registry,
            user_id,
            device_id,
            old_name,
            new_name,
          )
          // Also update compression if provided
          case maybe_compression {
            Some(ic) -> update_compression(ctx, user_id, device_id, ic)
            None ->
              device_to_json(device)
              |> json.to_string
              |> wisp.json_response(200)
          }
        }
        Error(device_service.DeviceNotFound) ->
          json.object([#("error", json.string("Device not found"))])
          |> json.to_string
          |> wisp.json_response(404)
        Error(_) -> wisp.internal_server_error()
      }
    Ok(#(None, Some(image_compression))) ->
      update_compression(ctx, user_id, device_id, image_compression)
    Ok(#(None, None)) -> wisp.unprocessable_content()
    Error(_) -> wisp.unprocessable_content()
  }
}

fn update_compression(
  ctx: Context,
  user_id: String,
  device_id: String,
  image_compression: Int,
) -> wisp.Response {
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
