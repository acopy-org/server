import server/user/user_routes
import server/web.{type Context}
import wisp

pub fn handle_request(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- web.middleware(req, ctx)

  case wisp.path_segments(req) {
    ["api", "users", ..rest] -> user_routes.handle_request(req, ctx, rest)
    _ -> wisp.not_found()
  }
}
