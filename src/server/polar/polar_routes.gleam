import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import server/auth/auth
import server/subscription/subscription_service
import server/user/user_service
import server/web.{type Context}
import wisp

pub fn handle_request(
  req: wisp.Request,
  ctx: Context,
  path: List(String),
) -> wisp.Response {
  case path {
    ["webhook"] -> handle_webhook(req, ctx)
    ["checkout"] -> handle_checkout(req, ctx)
    _ -> wisp.not_found()
  }
}

// --- Webhook ---

fn handle_webhook(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use body <- wisp.require_string_body(req)

  case ctx.polar_webhook_secret {
    "" ->
      json.object([#("error", json.string("Webhooks not configured"))])
      |> json.to_string
      |> wisp.json_response(500)
    secret -> {
      case verify_webhook_signature(req, body, secret) {
        False ->
          json.object([#("error", json.string("Invalid signature"))])
          |> json.to_string
          |> wisp.json_response(401)
        True -> process_webhook(body, ctx)
      }
    }
  }
}

fn process_webhook(body: String, ctx: Context) -> wisp.Response {
  // First decode the event type
  let type_decoder = {
    use event_type <- decode.field("type", decode.string)
    decode.success(event_type)
  }

  case json.parse(from: body, using: type_decoder) {
    Error(_) ->
      json.object([#("error", json.string("Invalid payload"))])
      |> json.to_string
      |> wisp.json_response(400)
    Ok(event_type) -> {
      case
        string.starts_with(event_type, "subscription."),
        string.starts_with(event_type, "order.")
      {
        True, _ -> handle_subscription_event(body, event_type, ctx)
        _, True -> handle_order_event(body, event_type, ctx)
        _, _ -> {
          // Acknowledge other events
          json.object([#("ok", json.bool(True))])
          |> json.to_string
          |> wisp.json_response(200)
        }
      }
    }
  }
}

fn handle_subscription_event(
  body: String,
  event_type: String,
  ctx: Context,
) -> wisp.Response {
  let sub_decoder = {
    use data <- decode.field("data", {
      use sub_id <- decode.field("id", decode.string)
      use status <- decode.field("status", decode.string)
      use customer <- decode.field("customer", {
        use customer_id <- decode.field("id", decode.string)
        use external_id <- decode.field(
          "external_id",
          decode.optional(decode.string),
        )
        use email <- decode.field("email", decode.string)
        decode.success(#(customer_id, external_id, email))
      })
      decode.success(#(sub_id, status, customer))
    })
    decode.success(data)
  }

  case json.parse(from: body, using: sub_decoder) {
    Error(_) -> {
      json.object([#("ok", json.bool(True)), #("skipped", json.bool(True))])
      |> json.to_string
      |> wisp.json_response(200)
    }
    Ok(#(sub_id, status, #(customer_id, external_id, email))) -> {
      case resolve_user_id(ctx, external_id, email) {
        Error(_) -> {
          json.object([
            #("ok", json.bool(True)),
            #("skipped", json.bool(True)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        }
        Ok(user_id) -> {
          let plan = case event_type {
            "subscription.active" -> "pro"
            "subscription.revoked" -> "free"
            _ -> {
              case status {
                "active" -> "pro"
                "trialing" -> "pro"
                _ -> "free"
              }
            }
          }

          let _ =
            subscription_service.upsert_subscription(
              ctx.db,
              user_id,
              customer_id,
              sub_id,
              plan,
              status,
              "",
            )

          json.object([#("ok", json.bool(True))])
          |> json.to_string
          |> wisp.json_response(200)
        }
      }
    }
  }
}

fn handle_order_event(
  body: String,
  event_type: String,
  ctx: Context,
) -> wisp.Response {
  let order_decoder = {
    use data <- decode.field("data", {
      use customer <- decode.field("customer", {
        use customer_id <- decode.field("id", decode.string)
        use external_id <- decode.field(
          "external_id",
          decode.optional(decode.string),
        )
        use email <- decode.field("email", decode.string)
        decode.success(#(customer_id, external_id, email))
      })
      decode.success(customer)
    })
    decode.success(data)
  }

  case json.parse(from: body, using: order_decoder) {
    Error(_) -> {
      json.object([#("ok", json.bool(True)), #("skipped", json.bool(True))])
      |> json.to_string
      |> wisp.json_response(200)
    }
    Ok(#(customer_id, external_id, email)) -> {
      case resolve_user_id(ctx, external_id, email) {
        Error(_) -> {
          json.object([
            #("ok", json.bool(True)),
            #("skipped", json.bool(True)),
          ])
          |> json.to_string
          |> wisp.json_response(200)
        }
        Ok(user_id) -> {
          let plan = case event_type {
            "order.paid" -> "pro"
            "order.refunded" -> "free"
            _ -> "pro"
          }
          let status = case event_type {
            "order.paid" -> "active"
            "order.refunded" -> "refunded"
            _ -> "active"
          }

          let _ =
            subscription_service.upsert_subscription(
              ctx.db,
              user_id,
              customer_id,
              "",
              plan,
              status,
              "",
            )

          json.object([#("ok", json.bool(True))])
          |> json.to_string
          |> wisp.json_response(200)
        }
      }
    }
  }
}

/// Resolve user_id from external_id (preferred) or email fallback
fn resolve_user_id(
  ctx: Context,
  external_id: option.Option(String),
  email: String,
) -> Result(String, Nil) {
  case external_id {
    option.Some(id) -> Ok(id)
    option.None -> {
      case user_service.get_user_by_email(ctx.db, email) {
        Ok(user) -> Ok(user.id)
        Error(_) -> Error(Nil)
      }
    }
  }
}

// --- Checkout ---

fn handle_checkout(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  use user_id <- auth.require_auth(req, ctx.jwt_secret)

  case ctx.polar_checkout_link {
    "" ->
      json.object([#("error", json.string("Checkout not configured"))])
      |> json.to_string
      |> wisp.json_response(500)
    link -> {
      // Get user email to prefill checkout
      let email = case user_service.get_user_by_id(ctx.db, user_id) {
        Ok(user) -> user.email
        Error(_) -> ""
      }

      let separator = case string.contains(link, "?") {
        True -> "&"
        False -> "?"
      }

      let url =
        link
        <> separator
        <> "customer_external_id="
        <> user_id
        <> "&customer_email="
        <> email

      json.object([#("url", json.string(url))])
      |> json.to_string
      |> wisp.json_response(200)
    }
  }
}

// --- Webhook Signature Verification (Standard Webhooks) ---

fn verify_webhook_signature(
  req: wisp.Request,
  body: String,
  secret: String,
) -> Bool {
  case
    request.get_header(req, "webhook-id"),
    request.get_header(req, "webhook-timestamp"),
    request.get_header(req, "webhook-signature")
  {
    Ok(webhook_id), Ok(timestamp), Ok(signature_header) -> {
      // Polar base64-encodes the raw secret before passing to StandardWebhook,
      // which then base64-decodes it. So the HMAC key is the UTF-8 bytes of
      // the full secret string (including prefix).
      let key = bit_array.from_string(secret)

      // Sign: "{webhook_id}.{timestamp}.{body}"
      let message = webhook_id <> "." <> timestamp <> "." <> body
      let sig =
        crypto.hmac(
          bit_array.from_string(message),
          crypto.Sha256,
          key,
        )
      let expected = "v1," <> bit_array.base64_encode(sig, True)

      // Check against all provided signatures (space-separated)
      let signatures = string.split(signature_header, " ")
      list.any(signatures, fn(s) {
        crypto.secure_compare(
          bit_array.from_string(s),
          bit_array.from_string(expected),
        )
      })
    }
    _, _, _ -> False
  }
}
