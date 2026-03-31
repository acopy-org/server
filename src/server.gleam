import envoy
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/io
import mist
import pog
import server/db/db
import server/router
import server/web
import server/ws/handler as ws_handler
import server/ws/registry
import wisp
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()

  let jwt_secret = case envoy.get("JWT_SECRET") {
    Ok(secret) -> secret
    Error(_) -> "dev-secret-change-in-production"
  }

  let port = case envoy.get("PORT") {
    Ok(port_str) ->
      case int.parse(port_str) {
        Ok(p) -> p
        Error(_) -> 8000
      }
    Error(_) -> 8000
  }

  let database_url = case envoy.get("DATABASE_URL") {
    Ok(url) -> url
    Error(_) -> "postgres://postgres:postgres@localhost:5432/acopy"
  }

  let pool_name = process.new_name(prefix: "acopy_db")
  let assert Ok(config) = pog.url_config(pool_name, database_url)
  let assert Ok(started) = pog.start(config)
  let db = started.data

  let assert Ok(_) = db.migrate(db)
  let assert Ok(reg) = registry.start()

  let ctx = web.Context(db: db, jwt_secret: jwt_secret, registry: reg)

  let http_handler =
    fn(req) { router.handle_request(req, ctx) }
    |> wisp_mist.handler(jwt_secret)

  let handler = fn(req: request.Request(mist.Connection)) {
    case request.path_segments(req) {
      ["ws"] -> ws_handler.upgrade(req, ctx)
      _ -> http_handler(req)
    }
  }

  let assert Ok(_) =
    handler
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  io.println("Server started on port " <> int.to_string(port))
  process.sleep_forever()
}
