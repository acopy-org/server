import birl
import pog
import server/auth/password
import server/user/user.{type User}
import youid/uuid

pub type ServiceError {
  EmailAlreadyExists
  InvalidCredentials
  UserNotFound
  DatabaseError(pog.QueryError)
}

pub fn register(
  db: pog.Connection,
  email: String,
  raw_password: String,
) -> Result(User, ServiceError) {
  let id = uuid.v4_string()
  let password_hash = password.hash(raw_password)
  let created_at = birl.now() |> birl.to_iso8601

  case
    pog.query(
      "INSERT INTO users (id, email, password_hash, created_at) VALUES ($1, $2, $3, $4) RETURNING id, email, password_hash, created_at",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(email))
    |> pog.parameter(pog.text(password_hash))
    |> pog.parameter(pog.text(created_at))
    |> pog.returning(user.db_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [new_user, ..])) -> Ok(new_user)
    Error(pog.ConstraintViolated(_, "users_email_key", _)) ->
      Error(EmailAlreadyExists)
    Error(pog.ConstraintViolated(_, constraint, _)) -> {
      // Handle other unique constraint names PostgreSQL may generate
      case constraint {
        _ ->
          case is_email_unique_constraint(constraint) {
            True -> Error(EmailAlreadyExists)
            False -> Error(DatabaseError(pog.ConstraintViolated("", constraint, "")))
          }
      }
    }
    Error(e) -> Error(DatabaseError(e))
    Ok(_) -> Error(DatabaseError(pog.PostgresqlError("", "", "No rows returned")))
  }
}

fn is_email_unique_constraint(constraint: String) -> Bool {
  case constraint {
    "users_email_key" -> True
    _ -> False
  }
}

pub fn login(
  db: pog.Connection,
  email: String,
  raw_password: String,
) -> Result(User, ServiceError) {
  case
    pog.query(
      "SELECT id, email, password_hash, created_at FROM users WHERE email = $1",
    )
    |> pog.parameter(pog.text(email))
    |> pog.returning(user.db_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [found_user, ..])) ->
      case password.verify(raw_password, found_user.password_hash) {
        True -> Ok(found_user)
        False -> Error(InvalidCredentials)
      }
    Ok(_) -> Error(InvalidCredentials)
    Error(e) -> Error(DatabaseError(e))
  }
}

pub fn get_user_by_id(
  db: pog.Connection,
  id: String,
) -> Result(User, ServiceError) {
  case
    pog.query(
      "SELECT id, email, password_hash, created_at FROM users WHERE id = $1",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning(user.db_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [found_user, ..])) -> Ok(found_user)
    Ok(_) -> Error(UserNotFound)
    Error(e) -> Error(DatabaseError(e))
  }
}

pub fn get_user_by_email(
  db: pog.Connection,
  email: String,
) -> Result(User, ServiceError) {
  case
    pog.query(
      "SELECT id, email, password_hash, created_at FROM users WHERE email = $1",
    )
    |> pog.parameter(pog.text(email))
    |> pog.returning(user.db_decoder())
    |> pog.execute(on: db)
  {
    Ok(pog.Returned(_, [found_user, ..])) -> Ok(found_user)
    Ok(_) -> Error(UserNotFound)
    Error(e) -> Error(DatabaseError(e))
  }
}
