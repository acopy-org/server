import gleam/bytes_tree
import gleam/http
import gleam/http/response
import gleam/list
import gleam/string
import server/clipboard/clipboard_routes
import server/clipboard/clipboard_service
import server/user/user_routes
import server/web.{type Context}
import wisp

pub fn handle_request(req: wisp.Request, ctx: Context) -> wisp.Response {
  use <- web.middleware(req, ctx)

  case wisp.path_segments(req) {
    ["api", "clipboard", ..rest] -> clipboard_routes.handle_request(req, ctx, rest)
    ["api", "users", ..rest] -> user_routes.handle_request(req, ctx, rest)
    ["static", ..path] -> static_file(req, path)
    ["install.sh"] -> install_script(req)
    ["install.ps1"] -> install_script_ps1(req)
    ["login"] -> login_page(req)
    ["dashboard"] -> dashboard_page(req)
    ["index.html"] -> wisp.redirect("/")
    ["login.html"] -> wisp.redirect("/login")
    ["dashboard.html"] -> wisp.redirect("/dashboard")
    ["c", filename] -> {
      let id = case string.split(filename, ".") {
        [base, _ext] -> base
        _ -> filename
      }
      serve_clipboard(req, ctx, id)
    }
    [] -> index_page(req)
    _ -> wisp.not_found()
  }
}

fn serve_clipboard(req: wisp.Request, ctx: Context, id: String) -> wisp.Response {
  case req.method {
    http.Get -> {
      case clipboard_service.get_entry_by_id(ctx.db, id) {
        Ok(entry) ->
          wisp.response(200)
          |> response.set_header("content-type", entry.content_type)
          |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(entry.content)))
        Error(_) -> wisp.not_found()
      }
    }
    _ -> wisp.method_not_allowed(allowed: [http.Get])
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
          False -> case string.ends_with(filename, ".png") {
            True -> "image/png"
            False -> "application/octet-stream"
          }
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

fn login_page(req: wisp.Request) -> wisp.Response {
  case req.method {
    http.Get -> read_file("priv/login.html", "text/html")
    _ -> wisp.method_not_allowed(allowed: [http.Get])
  }
}

fn dashboard_page(req: wisp.Request) -> wisp.Response {
  case req.method {
    http.Get -> read_file("priv/dashboard.html", "text/html")
    _ -> wisp.method_not_allowed(allowed: [http.Get])
  }
}

fn install_script(req: wisp.Request) -> wisp.Response {
  case req.method {
    http.Get -> read_file("priv/static/install.sh", "text/plain")
    _ -> wisp.method_not_allowed(allowed: [http.Get])
  }
}

fn install_script_ps1(req: wisp.Request) -> wisp.Response {
  case req.method {
    http.Get -> read_file("priv/static/install.ps1", "text/plain")
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
