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
  use _ <- exec(
    "ALTER TABLE clipboard_entries ADD COLUMN IF NOT EXISTS content_type TEXT NOT NULL DEFAULT 'text/plain'",
    db,
  )
  use _ <- exec(
    "CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      device_name TEXT NOT NULL,
      image_compression INT NOT NULL DEFAULT 100,
      created_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL,
      UNIQUE(user_id, device_name)
    )",
    db,
  )
  use _ <- exec(
    "CREATE TABLE IF NOT EXISTS subscriptions (
      user_id TEXT PRIMARY KEY REFERENCES users(id),
      polar_customer_id TEXT,
      polar_subscription_id TEXT,
      plan TEXT NOT NULL DEFAULT 'free',
      status TEXT NOT NULL DEFAULT 'active',
      current_period_end TEXT,
      updated_at TEXT NOT NULL
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
