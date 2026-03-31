import gleam/dynamic/decode
import gleam/json

pub type User {
  User(id: String, email: String, password_hash: String, created_at: String)
}

pub type RegisterRequest {
  RegisterRequest(email: String, password: String)
}

pub type LoginRequest {
  LoginRequest(email: String, password: String)
}

pub fn user_to_json(user: User) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("email", json.string(user.email)),
    #("created_at", json.string(user.created_at)),
  ])
}

pub fn db_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.string)
  use email <- decode.field(1, decode.string)
  use password_hash <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.string)
  decode.success(User(id:, email:, password_hash:, created_at:))
}

pub fn register_decoder() -> decode.Decoder(RegisterRequest) {
  use email <- decode.field("email", decode.string)
  use password <- decode.field("password", decode.string)
  decode.success(RegisterRequest(email:, password:))
}

pub fn login_decoder() -> decode.Decoder(LoginRequest) {
  use email <- decode.field("email", decode.string)
  use password <- decode.field("password", decode.string)
  decode.success(LoginRequest(email:, password:))
}
