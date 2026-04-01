import gleam/http
import gleam/http/response
import gleam/list
import gleam/string
import server/user/user_routes
import server/web.{type Context}
import wisp

pub fn handle_request(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- web.middleware(req, ctx)

  case wisp.path_segments(req) {
    ["api", "users", ..rest] -> user_routes.handle_request(req, ctx, rest)
    ["static", ..path] -> static_file(req, path)
    ["index.html"] -> index_page(req)
    ["dashboard.html"] -> dashboard_page(req)
    [] -> wisp.redirect("/index.html")
    _ -> wisp.not_found()
  }
}

fn static_file(req: wisp.Request, path: List(String)) -> wisp.Response {
  case req.method {
    http.Get -> {
      let safe_path = list.filter(path, fn(s) { s != ".." && s != "." })
      let file = "priv/static/" <> string.join(safe_path, "/")
      read_file(file, mime_type(safe_path))
    }
    _ -> wisp.method_not_allowed(allowed: [http.Get])
  }
}

fn mime_type(path: List(String)) -> String {
  case list.last(path) {
    Ok(filename) -> {
      case string.ends_with(filename, ".css") {
        True -> "text/css"
        False -> case string.ends_with(filename, ".js") {
          True -> "application/javascript"
          False -> "application/octet-stream"
        }
      }
    }
    _ -> "application/octet-stream"
  }
}

fn index_page(req: wisp.Request) -> wisp.Response {
  case req.method {
    http.Get -> read_file("priv/index.html", "text/html")
    _ -> wisp.method_not_allowed(allowed: [http.Get])
  }
}

fn dashboard_page(req: wisp.Request) -> wisp.Response {
  case req.method {
    http.Get -> read_file("priv/dashboard.html", "text/html")
    _ -> wisp.method_not_allowed(allowed: [http.Get])
  }
}

@external(erlang, "file_ffi", "read")
fn erlang_read_file(path: String) -> Result(String, String)

fn read_file(path: String, mime: String) -> wisp.Response {
  case erlang_read_file(path) {
    Ok(content) ->
      wisp.response(200)
      |> response.set_header("content-type", mime)
      |> wisp.string_body(content)
    Error(_) -> wisp.not_found()
  }
}
