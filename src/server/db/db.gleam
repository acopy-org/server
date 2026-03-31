import pog

pub fn migrate(db: pog.Connection) -> Result(Nil, pog.QueryError) {
  use _ <- exec(
    "CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at TEXT NOT NULL
    )",
    db,
  )
  use _ <- exec(
    "CREATE TABLE IF NOT EXISTS clipboard_entries (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      content BYTEA NOT NULL,
      device_name TEXT NOT NULL,
      created_at TEXT NOT NULL
    )",
    db,
  )
  Ok(Nil)
}

fn exec(
  sql: String,
  db: pog.Connection,
  next: fn(Nil) -> Result(Nil, pog.QueryError),
) -> Result(Nil, pog.QueryError) {
  case pog.query(sql) |> pog.execute(on: db) {
    Ok(_) -> next(Nil)
    Error(e) -> Error(e)
  }
}
