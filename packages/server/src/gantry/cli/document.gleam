//// A JSON document the CLI can project and print as one line.
////
//// ## Flow
////
//// `parse` reads one JSON object into a `Document` through `from_dynamic`
//// and `leaf`. Objects keep their keys in sorted order, so two equal
//// documents always `encode` to the same text, and the CLI's watch relies on
//// that to suppress repeated states. `parse_fields` checks a `--fields` list
//// of dotted object paths with `valid_key`, whose characters `letter` and
//// `digit` classify. `project` follows each path with `lookup` and keeps
//// what it finds with `insert`. A path that crosses an array or a missing
//// key is omitted, and a path selected whole dominates any longer path
//// beneath it.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// A parsed JSON value. Anything other than an object is kept encoded,
/// because projection never looks inside it.
pub opaque type Document {
  Object(fields: List(#(String, Document)))
  Leaf(value: json.Json)
}

/// A validated `--fields` list: comma-separated paths of object keys.
pub opaque type Fields {
  Fields(paths: List(List(String)))
}

/// Parse text that must hold exactly one JSON object.
///
/// ## Examples
///
/// ```gleam
/// assert document.parse("[]") == Error(Nil)
/// ```
pub fn parse(text: String) -> Result(Document, Nil) {
  use value <- result.try(
    json.parse(text, decode.dynamic) |> result.replace_error(Nil),
  )

  // Valid JSON that is not an object is still not a document.
  case from_dynamic(value) {
    Object(_) as object -> Ok(object)
    Leaf(_) -> Error(Nil)
  }
}

/// Convert a decoded value, sorting object keys for a canonical encoding.
fn from_dynamic(value: Dynamic) -> Document {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      dict.to_list(fields)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.map(fn(field) { #(field.0, from_dynamic(field.1)) })
      |> Object
    Error(_) -> Leaf(leaf(value))
  }
}

/// Encode a non-object value. JSON only produces strings, numbers,
/// booleans, null, arrays, and objects, so the final arm is null.
fn leaf(value: Dynamic) -> json.Json {
  let decoder =
    decode.one_of(decode.string |> decode.map(json.string), [
      decode.bool |> decode.map(json.bool),
      decode.int |> decode.map(json.int),
      decode.float |> decode.map(json.float),
      decode.list(decode.dynamic)
        |> decode.map(fn(items) {
          json.preprocessed_array(
            list.map(items, fn(item) { encode(from_dynamic(item)) }),
          )
        }),
    ])
  decode.run(value, decoder) |> result.lazy_unwrap(json.null)
}

/// Encode a document as compact JSON.
///
/// ## Examples
///
/// ```gleam
/// // document.encode(doc) |> json.to_string
/// ```
pub fn encode(document: Document) -> json.Json {
  case document {
    Object(fields) ->
      json.object(list.map(fields, fn(field) { #(field.0, encode(field.1)) }))
    Leaf(value) -> value
  }
}

/// Encode a document as one line of JSON text.
///
/// ## Examples
///
/// ```gleam
/// // document.to_string(doc)
/// ```
pub fn to_string(document: Document) -> String {
  json.to_string(encode(document))
}

/// Read the string at a top-level key.
///
/// ## Examples
///
/// ```gleam
/// // document.string(doc, "error")
/// ```
pub fn string(document: Document, key: String) -> Result(String, Nil) {
  // Only an object has keys, and only a leaf can hold a string.
  case document {
    Object(fields) -> {
      use value <- result.try(list.key_find(fields, key))

      // A nested object at the key is not a string.
      case value {
        Leaf(value) ->
          json.parse(json.to_string(value), decode.string)
          |> result.replace_error(Nil)
        Object(_) -> Error(Nil)
      }
    }
    Leaf(_) -> Error(Nil)
  }
}

/// Build an object document from encoded fields, sorting its keys.
///
/// ## Examples
///
/// ```gleam
/// // document.object([#("status", document.text("ready"))])
/// ```
pub fn object(fields: List(#(String, Document))) -> Document {
  fields
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> Object
}

/// Wrap a JSON string as a document leaf.
pub fn text(value: String) -> Document {
  Leaf(json.string(value))
}

/// Wrap any encoded JSON value as a document leaf.
pub fn value(value: json.Json) -> Document {
  Leaf(value)
}

/// Read the top-level field of an object document.
///
/// ## Examples
///
/// ```gleam
/// // document.get(schema, "commands")
/// ```
pub fn get(document: Document, key: String) -> Result(Document, Nil) {
  case document {
    Object(fields) -> list.key_find(fields, key)
    Leaf(_) -> Error(Nil)
  }
}

/// The fields of an object document, or none for any other value.
pub fn fields(document: Document) -> List(#(String, Document)) {
  case document {
    Object(fields) -> fields
    Leaf(_) -> []
  }
}

// ---------------------------------------------------------------------------
// Projection
// ---------------------------------------------------------------------------

/// Check a `--fields` list. Each path is one or more keys joined by dots,
/// and each key starts with a letter or underscore followed by letters,
/// digits, underscores, or dashes.
///
/// ## Examples
///
/// ```gleam
/// assert document.parse_fields("id,submission.kind") |> result.is_ok
/// ```
///
/// ```gleam
/// assert document.parse_fields("id,,phase") == Error(Nil)
/// ```
pub fn parse_fields(text: String) -> Result(Fields, Nil) {
  string.split(text, ",")
  |> list.try_map(fn(path) {
    let keys = string.split(path, ".")

    // Every key of a dotted path must be well formed.
    case list.all(keys, valid_key) {
      True -> Ok(keys)
      False -> Error(Nil)
    }
  })
  |> result.map(Fields)
}

/// Check one key of a projection path.
fn valid_key(key: String) -> Bool {
  case string.to_graphemes(key) {
    [first, ..rest] ->
      { letter(first) || first == "_" }
      && list.all(rest, fn(c) { letter(c) || digit(c) || c == "_" || c == "-" })
    [] -> False
  }
}

fn letter(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
}

fn digit(c: String) -> Bool {
  string.contains("0123456789", c)
}

/// Keep only the selected paths of a document.
///
/// ## Examples
///
/// ```gleam
/// // document.project(run, fields) |> document.to_string
/// ```
pub fn project(document: Document, fields: Fields) -> Document {
  list.fold(fields.paths, Object([]), fn(output, path) {
    case lookup(document, path) {
      Ok(found) -> insert(output, path, found)
      Error(Nil) -> output
    }
  })
  |> canonical
}

/// Follow a path of object keys. Arrays and scalars end the walk.
fn lookup(document: Document, path: List(String)) -> Result(Document, Nil) {
  case path {
    [] -> Ok(document)
    [key, ..rest] -> get(document, key) |> result.try(lookup(_, rest))
  }
}

/// Place a found value in the output. A value already selected whole stays
/// whole, and a whole value replaces any partial selection beneath it.
fn insert(output: Document, path: List(String), found: Document) -> Document {
  case path, output {
    [], _ -> found
    [_, ..], Leaf(_) -> output
    [key, ..rest], Object(fields) ->
      case list.key_find(fields, key) {
        Ok(existing) ->
          case rest, existing {
            [], _ -> Object(list.key_set(fields, key, found))
            [_, ..], Leaf(_) -> output
            [_, ..], Object(_) ->
              Object(list.key_set(fields, key, insert(existing, rest, found)))
          }
        Error(Nil) ->
          Object(list.key_set(fields, key, insert(Object([]), rest, found)))
      }
  }
}

/// Sort the keys of every object in a projection.
fn canonical(document: Document) -> Document {
  case document {
    Object(fields) ->
      list.map(fields, fn(field) { #(field.0, canonical(field.1)) })
      |> object
    Leaf(_) -> document
  }
}
