import birl
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request
import gleam/json
import gleam/result
import gleam/string
import wisp

/// Create a JWT token for the given user ID.
/// Uses HS256 (HMAC-SHA256) signing.
pub fn generate_token(user_id: String, secret: String) -> String {
  let header =
    json.object([#("alg", json.string("HS256")), #("typ", json.string("JWT"))])
    |> json.to_string
    |> bit_array.from_string
    |> base64_url_encode

  let now = birl.now() |> birl.to_unix

  let payload =
    json.object([
      #("sub", json.string(user_id)),
      #("iat", json.int(now)),
    ])
    |> json.to_string
    |> bit_array.from_string
    |> base64_url_encode

  let message = header <> "." <> payload
  let signature =
    crypto.hmac(
      bit_array.from_string(message),
      crypto.Sha256,
      bit_array.from_string(secret),
    )
    |> base64_url_encode

  message <> "." <> signature
}

/// Verify a JWT token and extract the user ID (subject claim).
pub fn verify_token(token: String, secret: String) -> Result(String, Nil) {
  case string.split(token, ".") {
    [header, payload, signature] -> {
      let message = header <> "." <> payload
      let expected_sig =
        crypto.hmac(
          bit_array.from_string(message),
          crypto.Sha256,
          bit_array.from_string(secret),
        )
        |> base64_url_encode

      case crypto.secure_compare(
        bit_array.from_string(signature),
        bit_array.from_string(expected_sig),
      ) {
        True -> {
          use payload_bytes <- result.try(base64_url_decode(payload))
          use payload_str <- result.try(
            bit_array.to_string(payload_bytes) |> result.replace_error(Nil),
          )
          use claims <- result.try(parse_claims(payload_str))
          Ok(claims.sub)
        }
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Middleware that requires a valid JWT in the Authorization header.
/// Passes the authenticated user ID to the handler.
pub fn require_auth(
  req: wisp.Request,
  secret: String,
  handler: fn(String) -> wisp.Response,
) -> wisp.Response {
  case request.get_header(req, "authorization") {
    Ok(auth_header) ->
      case string.starts_with(auth_header, "Bearer ") {
        True -> {
          let token = string.drop_start(auth_header, 7)
          case verify_token(token, secret) {
            Ok(user_id) -> handler(user_id)
            Error(_) ->
              wisp.response(401)
              |> wisp.string_body(
                json.object([#("error", json.string("Invalid or expired token"))])
                |> json.to_string,
              )
          }
        }
        False ->
          wisp.response(401)
          |> wisp.string_body(
            json.object([#("error", json.string("Invalid authorization format"))])
            |> json.to_string,
          )
      }
    Error(_) ->
      wisp.response(401)
      |> wisp.string_body(
        json.object([#("error", json.string("Missing authorization header"))])
        |> json.to_string,
      )
  }
}

// --- Internal helpers ---

type Claims {
  Claims(sub: String)
}

fn claims_decoder() -> decode.Decoder(Claims) {
  use sub <- decode.field("sub", decode.string)
  decode.success(Claims(sub:))
}

fn parse_claims(payload_str: String) -> Result(Claims, Nil) {
  json.parse(from: payload_str, using: claims_decoder())
  |> result.replace_error(Nil)
}

fn base64_url_encode(data: BitArray) -> String {
  bit_array.base64_encode(data, False)
  |> string.replace("+", "-")
  |> string.replace("/", "_")
  |> string.replace("=", "")
}

fn base64_url_decode(data: String) -> Result(BitArray, Nil) {
  let padded = case string.length(data) % 4 {
    2 -> data <> "=="
    3 -> data <> "="
    _ -> data
  }
  padded
  |> string.replace("-", "+")
  |> string.replace("_", "/")
  |> bit_array.base64_decode
}
