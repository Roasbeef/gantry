//// The authority of an HTTP(S) origin, checked by hand so a credential can
//// only travel in a header. The CLI's controller URL and a worker's gateway
//// origin both use `parse_authority`, which splits a host from an optional
//// port and checks the host with `valid_host`. Every character class here
//// is ASCII, read through `alphanumeric`.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Split `HOST[:PORT]`, where the host is a name of letters, digits, dots,
/// dashes, and underscores, or a bracketed IPv6 literal, and the port is one
/// to five digits. The port range is the caller's to check.
///
/// ## Examples
///
/// ```gleam
/// assert origin.parse_authority("[::1]:4737") == Ok(Some(4737))
/// ```
///
/// ```gleam
/// assert origin.parse_authority("user@host") == Error(Nil)
/// ```
pub fn parse_authority(authority: String) -> Result(Option(Int), Nil) {
  // A bracketed IPv6 literal may itself contain colons.
  let #(host, port) = case authority {
    "[" <> rest ->
      case string.split_once(rest, "]") {
        Ok(#(address, "")) -> #("[" <> address <> "]", Ok(None))
        Ok(#(address, ":" <> port)) -> #("[" <> address <> "]", Ok(Some(port)))
        _ -> #("", Error(Nil))
      }
    _ ->
      case string.split_once(authority, ":") {
        Ok(#(name, port)) -> #(name, Ok(Some(port)))
        Error(Nil) -> #(authority, Ok(None))
      }
  }

  use port <- result.try(port)
  use <- bool.guard(!valid_host(host), Error(Nil))

  // A port is one to five digits, without a sign.
  case port {
    None -> Ok(None)
    Some(digits) -> {
      let numeric =
        digits != ""
        && string.drop_start(digits, 5) == ""
        && list.all(string.to_graphemes(digits), string.contains(
          "0123456789",
          _,
        ))

      // `int.parse` alone would accept a sign.
      case numeric {
        True -> int.parse(digits) |> result.map(Some)
        False -> Error(Nil)
      }
    }
  }
}

/// Check a host name, or a bracketed IPv6 literal of hex digits, colons,
/// and dots.
fn valid_host(host: String) -> Bool {
  case host {
    "" -> False
    "[" <> address ->
      case string.ends_with(address, "]") {
        True -> {
          let address = string.drop_end(address, 1)
          address != ""
          && list.all(string.to_graphemes(address), fn(c) {
            string.contains("0123456789abcdefABCDEF:.", c)
          })
        }
        False -> False
      }
    _ ->
      list.all(string.to_graphemes(host), fn(c) {
        alphanumeric(c) || string.contains("._-", c)
      })
  }
}

/// Whether a grapheme is an ASCII letter or digit.
///
/// ## Examples
///
/// ```gleam
/// assert origin.alphanumeric("é") == False
/// ```
pub fn alphanumeric(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    c,
  )
}
