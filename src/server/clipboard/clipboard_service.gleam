import birl
import pog
import youid/uuid

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
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}
