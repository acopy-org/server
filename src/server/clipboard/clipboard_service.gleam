import birl
import gleam/dynamic/decode
import pog
import youid/uuid

pub type ClipboardEntry {
  ClipboardEntry(id: String, content: BitArray, device_name: String, created_at: String)
}

fn clipboard_entry_decoder() -> decode.Decoder(ClipboardEntry) {
  use id <- decode.field(0, decode.string)
  use content <- decode.field(1, decode.bit_array)
  use device_name <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.string)
  decode.success(ClipboardEntry(id:, content:, device_name:, created_at:))
}

pub fn get_entries_by_user(
  db: pog.Connection,
  user_id: String,
) -> Result(List(ClipboardEntry), pog.QueryError) {
  case
    pog.query(
      "SELECT id, content, device_name, created_at FROM clipboard_entries WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50",
    )
    |> pog.parameter(pog.text(user_id))
    |> pog.returning(clipboard_entry_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, entries)) -> Ok(entries)
    Error(e) -> Error(e)
  }
}

fn delete_old_entries(
  db: pog.Connection,
  user_id: String,
) -> Result(Nil, pog.QueryError) {
  case
    pog.query(
      "DELETE FROM clipboard_entries WHERE user_id = $1 AND id NOT IN (SELECT id FROM clipboard_entries WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50)",
    )
    |> pog.parameter(pog.text(user_id))
    |> pog.execute(on: db)
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

pub fn save_entry(
  db: pog.Connection,
  user_id: String,
  content: BitArray,
  device_name: String,
) -> Result(Nil, pog.QueryError) {
  let id = uuid.v4_string()
  let created_at = birl.now() |> birl.to_iso8601
  case
    pog.query(
      "INSERT INTO clipboard_entries (id, user_id, content, device_name, created_at) VALUES ($1, $2, $3, $4, $5)",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(user_id))
    |> pog.parameter(pog.bytea(content))
    |> pog.parameter(pog.text(device_name))
    |> pog.parameter(pog.text(created_at))
    |> pog.execute(on: db)
  {
    Ok(_) -> {
      let _ = delete_old_entries(db, user_id)
      Ok(Nil)
    }
    Error(e) -> Error(e)
  }
}
