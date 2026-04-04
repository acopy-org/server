import birl
import gleam/dynamic/decode
import pog
import server/subscription/subscription_service
import youid/uuid

pub type Device {
  Device(
    id: String,
    user_id: String,
    device_name: String,
    image_compression: Int,
    created_at: String,
    last_seen_at: String,
  )
}

pub type DeviceError {
  DeviceLimitReached
  DeviceNotFound
  PlanRequired
  DeviceDbError(pog.QueryError)
}

pub fn get_devices(
  db: pog.Connection,
  user_id: String,
) -> Result(List(Device), pog.QueryError) {
  case
    pog.query(
      "SELECT id, user_id, device_name, image_compression, created_at, last_seen_at FROM devices WHERE user_id = $1 ORDER BY last_seen_at DESC",
    )
    |> pog.parameter(pog.text(user_id))
    |> pog.returning(device_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, devices)) -> Ok(devices)
    Error(e) -> Error(e)
  }
}

/// Ensure a device exists for the user. Creates it if new, enforcing plan limits.
/// polar_enabled=False means self-hosted mode (no limits).
pub fn ensure_device(
  db: pog.Connection,
  user_id: String,
  device_name: String,
  polar_enabled: Bool,
) -> Result(Device, DeviceError) {
  case get_device_by_name(db, user_id, device_name) {
    Ok(device) -> {
      let _ = touch_device(db, device.id)
      Ok(device)
    }
    Error(_) -> {
      let plan =
        subscription_service.get_effective_plan(db, user_id, polar_enabled)
      let max = subscription_service.max_devices(plan)
      case count_devices(db, user_id) {
        Ok(count) ->
          case count >= max {
            True -> Error(DeviceLimitReached)
            False -> register_device(db, user_id, device_name)
          }
        Error(e) -> Error(DeviceDbError(e))
      }
    }
  }
}

pub fn get_device_by_name(
  db: pog.Connection,
  user_id: String,
  device_name: String,
) -> Result(Device, Nil) {
  case
    pog.query(
      "SELECT id, user_id, device_name, image_compression, created_at, last_seen_at FROM devices WHERE user_id = $1 AND device_name = $2",
    )
    |> pog.parameter(pog.text(user_id))
    |> pog.parameter(pog.text(device_name))
    |> pog.returning(device_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [device, ..])) -> Ok(device)
    _ -> Error(Nil)
  }
}

pub fn count_devices(
  db: pog.Connection,
  user_id: String,
) -> Result(Int, pog.QueryError) {
  case
    pog.query("SELECT COUNT(*)::int FROM devices WHERE user_id = $1")
    |> pog.parameter(pog.text(user_id))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [count, ..])) -> Ok(count)
    Ok(_) -> Ok(0)
    Error(e) -> Error(e)
  }
}

pub fn update_device_config(
  db: pog.Connection,
  user_id: String,
  device_id: String,
  image_compression: Int,
  polar_enabled: Bool,
) -> Result(Device, DeviceError) {
  let plan =
    subscription_service.get_effective_plan(db, user_id, polar_enabled)
  case plan {
    subscription_service.Free -> Error(PlanRequired)
    subscription_service.Pro -> {
      case
        pog.query(
          "UPDATE devices SET image_compression = $1 WHERE id = $2 AND user_id = $3 RETURNING id, user_id, device_name, image_compression, created_at, last_seen_at",
        )
        |> pog.parameter(pog.int(image_compression))
        |> pog.parameter(pog.text(device_id))
        |> pog.parameter(pog.text(user_id))
        |> pog.returning(device_decoder())
        |> pog.execute(on: db)
      {
        Ok(pog.Returned(_, [device, ..])) -> Ok(device)
        Ok(_) -> Error(DeviceNotFound)
        Error(e) -> Error(DeviceDbError(e))
      }
    }
  }
}

pub fn rename_device(
  db: pog.Connection,
  user_id: String,
  device_id: String,
  new_name: String,
) -> Result(#(String, Device), DeviceError) {
  // Get old device to capture old name
  case
    pog.query(
      "SELECT id, user_id, device_name, image_compression, created_at, last_seen_at FROM devices WHERE id = $1 AND user_id = $2",
    )
    |> pog.parameter(pog.text(device_id))
    |> pog.parameter(pog.text(user_id))
    |> pog.returning(device_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [old_device, ..])) -> {
      let old_name = old_device.device_name
      case
        pog.query(
          "UPDATE devices SET device_name = $1 WHERE id = $2 AND user_id = $3 RETURNING id, user_id, device_name, image_compression, created_at, last_seen_at",
        )
        |> pog.parameter(pog.text(new_name))
        |> pog.parameter(pog.text(device_id))
        |> pog.parameter(pog.text(user_id))
        |> pog.returning(device_decoder())
        |> pog.execute(on: db)
      {
        Ok(pog.Returned(_, [device, ..])) -> Ok(#(old_name, device))
        Ok(_) -> Error(DeviceNotFound)
        Error(e) -> Error(DeviceDbError(e))
      }
    }
    Ok(_) -> Error(DeviceNotFound)
    Error(e) -> Error(DeviceDbError(e))
  }
}

pub fn delete_device(
  db: pog.Connection,
  user_id: String,
  device_id: String,
) -> Result(Nil, pog.QueryError) {
  case
    pog.query("DELETE FROM devices WHERE id = $1 AND user_id = $2")
    |> pog.parameter(pog.text(device_id))
    |> pog.parameter(pog.text(user_id))
    |> pog.execute(on: db)
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

fn register_device(
  db: pog.Connection,
  user_id: String,
  device_name: String,
) -> Result(Device, DeviceError) {
  let id = uuid.v4_string()
  let now = birl.now() |> birl.to_iso8601
  case
    pog.query(
      "INSERT INTO devices (id, user_id, device_name, image_compression, created_at, last_seen_at) VALUES ($1, $2, $3, 100, $4, $4) RETURNING id, user_id, device_name, image_compression, created_at, last_seen_at",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(user_id))
    |> pog.parameter(pog.text(device_name))
    |> pog.parameter(pog.text(now))
    |> pog.returning(device_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [device, ..])) -> Ok(device)
    Error(e) -> Error(DeviceDbError(e))
    _ -> Error(DeviceDbError(pog.PostgresqlError("", "", "No rows returned")))
  }
}

fn touch_device(
  db: pog.Connection,
  device_id: String,
) -> Result(Nil, pog.QueryError) {
  let now = birl.now() |> birl.to_iso8601
  case
    pog.query("UPDATE devices SET last_seen_at = $1 WHERE id = $2")
    |> pog.parameter(pog.text(now))
    |> pog.parameter(pog.text(device_id))
    |> pog.execute(on: db)
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

fn device_decoder() -> decode.Decoder(Device) {
  use id <- decode.field(0, decode.string)
  use user_id <- decode.field(1, decode.string)
  use device_name <- decode.field(2, decode.string)
  use image_compression <- decode.field(3, decode.int)
  use created_at <- decode.field(4, decode.string)
  use last_seen_at <- decode.field(5, decode.string)
  decode.success(Device(
    id:,
    user_id:,
    device_name:,
    image_compression:,
    created_at:,
    last_seen_at:,
  ))
}
