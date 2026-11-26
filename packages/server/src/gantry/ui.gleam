//// Serve the dashboard's built files from this application's `priv/ui`.
//// Only the names in `assets` are served, so a request path never reaches
//// the file system. The files hold no queue data; the page reads the queue
//// through the authenticated API.

import gleam/bytes_tree
import gleam/erlang/application
import gleam/http/response.{type Response}
import gleam/list
import gleam/result
import mist.{type ResponseData}
import simplifile

/// The served files and their media types. `make dashboard` writes them.
const assets = [
  #("index.html", "text/html; charset=utf-8"),
  #("dashboard.mjs", "text/javascript; charset=utf-8"),
  #("dashboard.css", "text/css; charset=utf-8"),
]

/// The page may load only its own files and talk only to its own origin.
/// Style attributes are allowed because the board sizes lease bars and graph
/// columns per element; stylesheets still come only from this origin.
const policy =
  "default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

/// Answer one dashboard file, or 404 for any name outside the list.
///
/// ## Examples
///
/// ```gleam
/// // ui.asset("index.html")
/// ```
pub fn asset(name: String) -> Response(ResponseData) {
  let found = {
    use media <- result.try(list.key_find(assets, name))
    use root <- result.try(application.priv_directory("gantry"))
    simplifile.read_bits(root <> "/ui/" <> name)
    |> result.replace_error(Nil)
    |> result.map(fn(body) { #(media, body) })
  }

  // A missing build answers like an unknown name, so nothing leaks about paths.
  case found {
    Ok(#(media, body)) ->
      response.new(200)
      |> response.set_header("content-type", media)
      |> response.set_header("content-security-policy", policy)
      |> response.set_header("x-content-type-options", "nosniff")
      |> response.set_header("cache-control", "no-cache")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
    Error(Nil) ->
      response.new(404)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("{\"error\":\"route not found\"}")),
      )
  }
}
