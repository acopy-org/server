import gleam/erlang/process.{type Subject}
import pog
import server/ws/registry.{type RegistryMessage}
import wisp

pub type Context {
  Context(
    db: pog.Connection,
    jwt_secret: String,
    registry: Subject(RegistryMessage),
    polar_webhook_secret: String,
    polar_checkout_link: String,
  )
}

pub fn middleware(
  req: wisp.Request,
  _ctx: Context,
  handler: fn() -> wisp.Response,
) -> wisp.Response {
  let req = wisp.set_max_body_size(req, 10_485_760)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  handler()
}
