import gleam/erlang/process.{type Subject}
import pog
import server/ws/registry.{type RegistryMessage}
import wisp

pub type Context {
  Context(
    db: pog.Connection,
    jwt_secret: String,
    registry: Subject(RegistryMessage),
  )
}

pub fn middleware(
  req: wisp.Request,
  _ctx: Context,
  handler: fn() -> wisp.Response,
) -> wisp.Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  handler()
}
