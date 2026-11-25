//// The agent CLI validates a request with the controller's own rules, then
//// sends it, so an invalid request fails locally with the same answer the
//// controller would give. Every outcome is output on stdout with exit 0, or
//// one JSON error envelope on stderr with a documented exit code.
////
//// ## Flow
////
//// `main` loads the process `Host` and hands the arguments to `run`, which
//// returns the exit code. `run` reads the words with `parse_options`, then
//// `dispatch` applies the checks in a fixed order: `version`, the command
//// name through `parse_command`, `help`, the output format, the offline
//// commands in `offline` (describe and skill), the `projection` paths, then
//// `online`. That routes to `onboarding`, to `admit` for plan, run, and
//// submit, whose body `admission` builds through `gantry_core/request`, or
//// to `read` for status, watch, and blob. `watch` polls, printing changed
//// states through `observe`, until a terminal phase or its deadline.
////
//// | Exit | Variant | Meaning |
//// | --- | --- | --- |
//// | 0 | | Output written, including a dry run. |
//// | 1 | `Failed` | Local resource, transport or service failure, an HTTP status without a more specific code, watch deadline, or a failed or blocked run. |
//// | 2 | `Invalid` | Invalid command, arguments, request, or configuration, or HTTP 400, 411, 413, or 422. |
//// | 3 | `Unauthorized` | Missing or invalid credentials, or HTTP 401 or 403. |
//// | 4 | `Missing` | HTTP 404 or a missing local profile. |
//// | 6 | `Conflict` | HTTP 409 or a local profile conflict. |
////
//// ## Effects
////
//// `Host` carries every effect: environment reads, the HTTP transport, file
//// and stdin reads, stdout and stderr writes, the clock, sleeping, bundled
//// resources, and the release location. Tests substitute each one. The real
//// host in `host` sends through `http_send`, reads its files through
//// `bundled`, and reaches the stdout bytes and the exit status through
//// `gantry/internal/ffi_host`. Onboarding runs the CLI inside this VM
//// through `embedded`, which captures output with `drain`.

import argv
import envoy
import gantry/blobs
import gantry/cli/document.{type Document, type Fields}
import gantry/cli/failure.{
  type Failure, Conflict, Failed, Failure, Invalid, Missing, Reported,
  Unauthorized, failed, invalid, invalid_input,
}
import gantry/cli/onboarding
import gantry/cli/origin
import gantry/internal/ffi_host
import gantry_core/protocol
import gantry_core/queue
import gantry_core/request.{type Rejection}
import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/application
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile

/// Every effect the CLI performs.
pub type Host {
  Host(
    /// Read an environment variable.
    environment: fn(String) -> Result(String, Nil),
    /// Send one HTTP request with a deadline in milliseconds. An error
    /// means no HTTP status was received.
    transport: fn(http_request.Request(BitArray), Int) ->
      Result(Response(BitArray), Nil),
    /// Read a local text file, such as an ad hoc action.
    read_file: fn(String) -> Result(String, Nil),
    /// Read standard input to end of file.
    read_stdin: fn() -> Result(BitArray, Nil),
    /// Write bytes to standard output.
    write: fn(BitArray) -> Nil,
    /// Write one line to standard error.
    report: fn(String) -> Nil,
    /// Read a monotonic clock in milliseconds.
    clock: fn() -> Int,
    /// Wait for a number of milliseconds.
    sleep: fn(Int) -> Nil,
    /// Read a bundled resource.
    resource: fn(Resource) -> Result(String, Nil),
    /// Locate the release's `bin` directory, which holds the controller
    /// and worker launchers onboarding starts.
    release: fn() -> Result(String, Nil),
  )
}

/// A file bundled with the CLI.
pub type Resource {
  /// The command and request schema served by `describe`.
  Schema

  /// The agent skill served by `skill`.
  Skill

  /// The release label served by `--version`.
  Version
}

/// Whether a flag appeared on the command line.
pub type Flag {
  Set
  Unset
}

/// A CLI command.
type Command {
  Plan
  RunBuild
  Submit
  Status
  Watch
  Blob
  SkillCommand
  Init
  Local
  Worker
  Describe
}

/// Which help format was requested.
type Help {
  NoHelp
  TextHelp
  JsonHelp
}

type Options {
  Options(
    command: Option(String),
    output: Option(String),
    fields: Option(String),
    payload: Option(String),
    dry_run: Flag,
    help: Help,
    version: Flag,
    local: Flag,
    token_stdin: Flag,
    arguments: List(String),
  )
}

/// Whether a watch has received any HTTP status yet.
type Contact {
  Unanswered
  Answered
}

/// What a watch does after one observed state.
type Next {
  /// Keep polling, comparing against the state just printed.
  Continue(printed: String)

  /// The run reached a successful terminal phase.
  Finished
}

/// The fixed inputs of one watch.
type Poll {
  Poll(
    url: String,
    token: String,
    id: String,
    fields: Option(Fields),
    deadline: Int,
  )
}

/// The default controller origin.
const default_url = "http://127.0.0.1:4737"

/// The per-request deadline, and the longest single poll of a watch.
const request_seconds = 180

/// The pause between watch polls.
const poll_milliseconds = 1000

/// Every command, in help order.
const commands = [
  Plan,
  RunBuild,
  Submit,
  Status,
  Watch,
  Blob,
  SkillCommand,
  Init,
  Local,
  Worker,
  Describe,
]

/// Run the CLI with the process arguments and exit with its status.
///
/// ## Examples
///
/// ```sh
/// gantry status build-1 --fields id,phase
/// ```
pub fn main() -> Nil {
  // A signalled CLI stops at once with the shell's 128 + signal status.
  // Supervised children follow through their death signal.
  ffi_host.default_terminate()
  let code = run(host(), argv.load().arguments)
  ffi_host.exit(code)
}

/// Run one invocation and return its exit status. Output is written through
/// the host as it is produced, and a failure envelope goes to stderr.
///
/// ## Examples
///
/// ```gleam
/// // cli.run(host, ["describe", "run"])
/// // -> 0
/// ```
pub fn run(host: Host, arguments: List(String)) -> Int {
  let empty =
    Options(None, None, None, None, Unset, NoHelp, Unset, Unset, Unset, [])
  let outcome = {
    use options <- result.try(parse_options(arguments, empty))
    dispatch(host, options)
  }

  // Exactly one envelope reports a failure, after any output already
  // written, so an agent can read stdout and stderr independently. A child
  // that reported its own failure keeps its status and its envelope.
  case outcome {
    Ok(Nil) -> 0
    Error(Failure(exit: Reported(status), ..)) -> status
    Error(failure) -> {
      host.report(json.to_string(failure.envelope(failure)))
      failure.exit_code(failure.exit)
    }
  }
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

/// Parse options in any position. A literal `--` ends option processing,
/// and the first other word is the command.
fn parse_options(
  arguments: List(String),
  options: Options,
) -> Result(Options, Failure) {
  case arguments {
    [] -> Ok(Options(..options, arguments: list.reverse(options.arguments)))

    // A trailing `--json` after `--help` asks for machine-readable help.
    ["--json"] if options.help != NoHelp ->
      parse_options([], Options(..options, help: JsonHelp))

    [option, ..rest]
      if option == "--output" || option == "--fields" || option == "--json"
    -> {
      use #(value, rest) <- result.try(option_value(option, rest))
      use options <- result.try(set_value(options, option, value))
      parse_options(rest, options)
    }

    ["--dry-run", ..rest] ->
      parse_options(rest, Options(..options, dry_run: Set))

    // A repeated switch is a mistake the caller should hear about.
    ["--local", ..rest] ->
      case options.local {
        Unset -> parse_options(rest, Options(..options, local: Set))
        Set -> Error(invalid("Duplicate option.", "--local"))
      }
    ["--token-stdin", ..rest] ->
      case options.token_stdin {
        Unset -> parse_options(rest, Options(..options, token_stdin: Set))
        Set -> Error(invalid("Duplicate option.", "--token-stdin"))
      }

    ["-h", ..rest] | ["--help", ..rest] ->
      parse_options(
        rest,
        Options(..options, help: case options.help {
          JsonHelp -> JsonHelp
          NoHelp | TextHelp -> TextHelp
        }),
      )
    ["--version", ..rest] ->
      parse_options(rest, Options(..options, version: Set))
    ["--", ..rest] ->
      parse_options(
        [],
        Options(
          ..options,
          arguments: list.append(list.reverse(rest), options.arguments),
        ),
      )
    ["-" <> _, ..] ->
      Error(invalid("Unknown option. Run gantry --help for usage.", "option"))
    [word, ..rest] ->
      case options.command {
        None -> parse_options(rest, Options(..options, command: Some(word)))
        Some(_) ->
          parse_options(
            rest,
            Options(..options, arguments: [word, ..options.arguments]),
          )
      }
  }
}

/// Take the value of a valued option. A value may not be empty or look like
/// another long option, so `--fields --json` cannot swallow `--json`.
fn option_value(
  option: String,
  rest: List(String),
) -> Result(#(String, List(String)), Failure) {
  case rest {
    [value, ..rest] if value != "" ->
      case string.starts_with(value, "--") {
        True -> Error(invalid("Missing value for " <> option <> ".", option))
        False -> Ok(#(value, rest))
      }
    [_, ..] | [] ->
      Error(invalid("Missing value for " <> option <> ".", option))
  }
}

/// Record a valued option, rejecting a second occurrence of the same one.
fn set_value(
  options: Options,
  option: String,
  value: String,
) -> Result(Options, Failure) {
  case option, options {
    "--output", Options(output: None, ..) ->
      Ok(Options(..options, output: Some(value)))
    "--fields", Options(fields: None, ..) ->
      Ok(Options(..options, fields: Some(value)))
    "--json", Options(payload: None, ..) ->
      Ok(Options(..options, payload: Some(value)))
    _, _ -> Error(invalid("Duplicate option.", option))
  }
}

/// Read a command name.
fn parse_command(name: String) -> Result(Command, Failure) {
  list.find(commands, fn(command) { command_name(command) == name })
  |> result.map_error(fn(_) {
    invalid(
      "Unknown command. Run gantry describe to see available commands.",
      "command",
    )
  })
}

/// The word a user types for a command.
fn command_name(command: Command) -> String {
  case command {
    Plan -> "plan"
    RunBuild -> "run"
    Submit -> "submit"
    Status -> "status"
    Watch -> "watch"
    Blob -> "blob"
    SkillCommand -> "skill"
    Init -> "init"
    Local -> "local"
    Worker -> "worker"
    Describe -> "describe"
  }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// Apply the command checks in order and run the command.
fn dispatch(host: Host, options: Options) -> Result(Nil, Failure) {
  use <- version(host, options)

  // An unknown name fails before help, so `gantry nope --help` is an error.
  use command <- result.try(case options.command {
    None -> Ok(None)
    Some(name) -> parse_command(name) |> result.map(Some)
  })

  use <- help(host, options, command)
  use command <- result.try(
    option.to_result(command, Nil)
    |> result.map_error(fn(_) {
      invalid("A command is required. Run gantry --help.", "command")
    }),
  )
  use Nil <- result.try(output_format(command, options.output))
  use <- bool.lazy_guard(options.local == Set && command != Init, fn() {
    Error(invalid("Use --local with init.", "--local"))
  })
  use <- bool.lazy_guard(options.token_stdin == Set && command != Worker, fn() {
    Error(invalid("Use --token-stdin with worker setup.", "--token-stdin"))
  })
  offline(host, command, options)
}

/// Serve `--version`, which accepts only `--output json`.
fn version(
  host: Host,
  options: Options,
  next: fn() -> Result(Nil, Failure),
) -> Result(Nil, Failure) {
  use <- bool.lazy_guard(options.version == Unset, next)
  let alone =
    options.command == None
    && options.arguments == []
    && options.help == NoHelp
    && options.payload == None
    && options.dry_run == Unset
    && options.local == Unset
    && options.token_stdin == Unset
    && options.fields == None
  let format = options.output == None || options.output == Some("json")
  use <- bool.lazy_guard(!alone || !format, fn() {
    Error(invalid_input("Use gantry --version [--output json]."))
  })
  let label =
    host.resource(Version) |> result.lazy_unwrap(fn() { "Gantry source CLI" })

  // JSON output wraps the same label the text form prints.
  case options.output {
    Some(_) ->
      Ok(write_line(
        host,
        json.to_string(json.object([#("version", json.string(label))])),
      ))
    None -> Ok(write_line(host, label))
  }
}

/// Serve `--help` as text or as the describe document.
fn help(
  host: Host,
  options: Options,
  command: Option(Command),
  next: fn() -> Result(Nil, Failure),
) -> Result(Nil, Failure) {
  use <- bool.lazy_guard(options.help == NoHelp, next)
  let alone =
    options.arguments == []
    && options.payload == None
    && options.dry_run == Unset
    && options.fields == None
    && options.local == Unset
    && options.token_stdin == Unset
    && { options.output == None || options.output == Some("json") }
  use <- bool.lazy_guard(!alone, fn() {
    Error(invalid_input("Use --help or --help --json."))
  })
  use schema <- result.try(schema(host))

  // Machine-readable help is the describe document for the same scope.
  case options.help, options.output {
    JsonHelp, _ | _, Some(_) -> describe(host, schema, command)
    TextHelp, None | NoHelp, None -> Ok(help_text(host, schema, command))
  }
}

/// Print usage lines from the schema: every command's usage, or one
/// command's usage and description.
fn help_text(host: Host, schema: Document, command: Option(Command)) -> Nil {
  let usage = fn(command) {
    let name = command_name(command)
    schema_text(schema, name, "usage")
    |> result.lazy_unwrap(fn() { "gantry " <> name })
  }

  // The overview lists every command. A command's help adds its purpose.
  let lines = case command {
    None ->
      list.append(list.map(commands, usage), [
        "gantry --help --json",
        "gantry --version",
      ])
    Some(command) -> [
      usage(command),
      schema_text(schema, command_name(command), "description")
        |> result.unwrap(""),
    ]
  }

  list.append(lines, [
    "Use -- before positional arguments that begin with a dash.",
    "Run gantry describe [COMMAND] for options, schemas and exit codes.",
  ])
  |> list.each(write_line(host, _))
}

/// Read one string field of a command's schema entry.
fn schema_text(
  schema: Document,
  command: String,
  key: String,
) -> Result(String, Nil) {
  document.get(schema, "commands")
  |> result.try(document.get(_, command))
  |> result.try(document.string(_, key))
}

/// Check the output format a command accepts.
fn output_format(
  command: Command,
  output: Option(String),
) -> Result(Nil, Failure) {
  case command, output {
    _, None -> Ok(Nil)
    Blob, Some("raw") | SkillCommand, Some("raw") -> Ok(Nil)
    Blob, Some(_) ->
      Error(invalid("Blob emits bytes. Use --output raw.", "--output"))
    SkillCommand, Some(_) ->
      Error(invalid("Skill emits Markdown. Use --output raw.", "--output"))
    _, Some("json") -> Ok(Nil)
    _, Some(_) -> Error(invalid("Use --output json.", "--output"))
  }
}

/// Serve the commands that need neither a controller nor credentials.
fn offline(
  host: Host,
  command: Command,
  options: Options,
) -> Result(Nil, Failure) {
  let plain =
    options.payload == None
    && options.dry_run == Unset
    && options.fields == None

  // Describe and skill answer from bundled files. Everything else goes on.
  case command {
    Describe -> {
      use <- bool.lazy_guard(
        !plain || list.drop(options.arguments, 1) != [],
        fn() { Error(invalid_input("Use gantry describe [COMMAND].")) },
      )
      use schema <- result.try(schema(host))

      // A named command must exist. No name describes everything.
      use target <- result.try(case options.arguments {
        [] -> Ok(None)
        [name, ..] -> parse_command(name) |> result.map(Some)
      })

      describe(host, schema, target)
    }
    SkillCommand -> {
      use <- bool.lazy_guard(!plain || options.arguments != [], fn() {
        Error(invalid_input("Use gantry skill [--output raw]."))
      })
      use skill <- result.try(
        host.resource(Skill)
        |> result.map_error(fn(_) {
          failed("missing_skill", "Could not read the Gantry agent skill.")
        }),
      )
      Ok(host.write(bit_array.from_string(skill)))
    }
    Plan | RunBuild | Submit | Status | Watch | Blob | Init | Local | Worker -> {
      use fields <- result.try(projection(command, options))
      online(host, command, options, fields)
    }
  }
}

/// Validate projection paths for both onboarding and HTTP JSON commands.
/// Blob bytes and dry-run previews have no live JSON result to project.
fn projection(
  command: Command,
  options: Options,
) -> Result(Option(Fields), Failure) {
  let usable = command != Blob && options.dry_run == Unset
  let paths = option.map(options.fields, document.parse_fields)

  // No list is no projection. A list must be usable and well formed.
  case paths, usable {
    None, _ -> Ok(None)
    Some(Ok(fields)), True -> Ok(Some(fields))
    Some(Ok(_)), False | Some(Error(Nil)), _ ->
      Error(invalid(
        "Use comma-separated object paths on live JSON results.",
        "--fields",
      ))
  }
}

/// Serve the describe document, whole or for one command. One command's
/// view carries the shared definitions and its options expanded from the
/// shared option table.
fn describe(
  host: Host,
  schema: Document,
  command: Option(Command),
) -> Result(Nil, Failure) {
  // The whole document answers `describe` with no command.
  case command {
    None -> Ok(write_line(host, document.to_string(schema)))
    Some(command) -> {
      let name = command_name(command)
      use entry <- result.try(
        document.get(schema, "commands")
        |> result.try(document.get(_, name))
        |> result.map_error(fn(_) {
          failed("missing_schema", "The CLI schema does not describe " <> name)
        }),
      )
      let names =
        document.get(entry, "options")
        |> result.try(fn(options) {
          json.parse(document.to_string(options), decode.list(decode.string))
          |> result.replace_error(Nil)
        })
        |> result.unwrap([])
      let options =
        document.get(schema, "options")
        |> result.map(document.fields)
        |> result.unwrap([])
        |> list.filter(fn(option) { list.contains(names, option.0) })

      // Shared definitions travel with every command so its `$ref`s resolve.
      let shared =
        list.filter_map(
          ["schema_version", "positional_separator", "exit_codes", "$defs"],
          fn(key) {
            document.get(schema, key) |> result.map(fn(value) { #(key, value) })
          },
        )
      let own =
        document.fields(entry)
        |> list.filter(fn(field) { field.0 != "options" })
      document.object(
        list.flatten([
          shared,
          own,
          [
            #("command", document.text(name)),
            #("options", document.object(options)),
          ],
        ]),
      )
      |> document.to_string
      |> write_line(host, _)
      |> Ok
    }
  }
}

/// Read and parse the bundled describe document.
fn schema(host: Host) -> Result(Document, Failure) {
  host.resource(Schema)
  |> result.try(document.parse)
  |> result.map_error(fn(_) {
    failed("missing_schema", "Could not read the Gantry CLI schema.")
  })
}

// ---------------------------------------------------------------------------
// Onboarding
// ---------------------------------------------------------------------------

/// Route the commands that need the network or the local services.
fn online(
  host: Host,
  command: Command,
  options: Options,
  fields: Option(Fields),
) -> Result(Nil, Failure) {
  // Onboarding owns its own endpoints. The rest talk to GANTRY_URL.
  case command {
    Init | Local | Worker -> onboarding(host, command, options, fields)
    Plan | RunBuild | Submit -> {
      use base <- result.try(controller_url(host))
      admit(host, command, options, base, fields)
    }
    Status | Watch | Blob | SkillCommand | Describe -> {
      use base <- result.try(controller_url(host))
      read(host, command, options, base, fields)
    }
  }
}

/// Check an onboarding command line, then run it in `gantry/cli/onboarding`
/// with effects drawn from this host.
fn onboarding(
  host: Host,
  command: Command,
  options: Options,
  fields: Option(Fields),
) -> Result(Nil, Failure) {
  let name = command_name(command)
  let usage = "Run gantry describe " <> name <> " for usage."
  use <- bool.lazy_guard(
    options.payload != None || options.dry_run == Set,
    fn() { Error(invalid_input(usage)) },
  )
  let starting =
    options.fields == None
    && options.output == None
    && options.token_stdin == Unset
  let effects = fn() {
    use bin <- result.map(
      host.release()
      |> result.map_error(fn(_) {
        failed(
          "missing_release",
          "Run this command with the installed Linux release.",
        )
      }),
    )
    onboarding.Effects(
      environment: host.environment,
      transport: host.transport,
      read_stdin: host.read_stdin,
      write: host.write,
      report: host.report,
      clock: host.clock,
      sleep: host.sleep,
      client: fn(arguments, overrides) { embedded(host, arguments, overrides) },
      bin:,
    )
  }

  // Each subcommand has a fixed shape. Anything else names its usage.
  case command, options.arguments {
    Init, [] if options.local == Set -> {
      use effects <- result.try(effects())
      onboarding.init_local(effects, fields)
    }
    Local, ["start"] if starting -> {
      use effects <- result.try(effects())
      onboarding.local_start(effects)
    }
    Worker, ["start"] if starting -> {
      use effects <- result.try(effects())
      use status <- result.try(onboarding.worker_start(effects))

      // The worker reported its own failure on this terminal.
      case status {
        0 -> Ok(Nil)
        status -> Error(Failure(Reported(status), "", "", None, None))
      }
    }
    Worker, ["setup", endpoint, pool] -> {
      use effects <- result.try(effects())

      // The flag picks stdin. Otherwise the environment supplies the token.
      let source = case options.token_stdin {
        Set -> onboarding.FromStdin
        Unset -> onboarding.FromEnvironment
      }

      onboarding.worker_setup(effects, endpoint, pool, source, fields)
    }
    Init, _ -> Error(invalid_input("Use gantry init --local."))
    Local, ["start"] | Worker, ["start"] ->
      Error(invalid_input("Use gantry " <> name <> " start."))
    Worker, ["setup", ..] ->
      Error(invalid_input(
        "Use gantry worker setup HTTPS_URL POOL [--token-stdin].",
      ))
    _, _ -> Error(invalid_input(usage))
  }
}

/// Run the CLI inside this VM with environment overrides and captured
/// output, as onboarding's smoke build does for run, watch, and blob. The
/// captured messages are collected once the run returns.
fn embedded(
  host: Host,
  arguments: List(String),
  overrides: List(#(String, String)),
) -> #(Int, BitArray, String) {
  let output = process.new_subject()
  let errors = process.new_subject()
  let outer = host.environment
  let inner =
    Host(
      ..host,
      environment: fn(name) {
        list.key_find(overrides, name) |> result.lazy_or(fn() { outer(name) })
      },
      write: process.send(output, _),
      report: process.send(errors, _),
    )
  let status = run(inner, arguments)
  #(
    status,
    bit_array.concat(drain(output, [])),
    string.join(drain(errors, []), "\n"),
  )
}

/// Collect every message already in a subject's mailbox, oldest first.
fn drain(subject: process.Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

// ---------------------------------------------------------------------------
// Admission
// ---------------------------------------------------------------------------

/// Validate a plan, run, or submit request and send it, or preview it.
fn admit(
  host: Host,
  command: Command,
  options: Options,
  base: String,
  fields: Option(Fields),
) -> Result(Nil, Failure) {
  use body <- result.try(admission(host, command, options))
  let text = json.to_string(body)

  // Submission authority has its own credential.
  let #(route, names) = case command {
    Plan -> #("/v1/plans", ["GANTRY_TOKEN"])
    Submit -> #("/v1/submits", ["GANTRY_SUBMIT_TOKEN"])
    RunBuild
    | Status
    | Watch
    | Blob
    | SkillCommand
    | Init
    | Local
    | Worker
    | Describe -> #("/v1/runs", ["GANTRY_TOKEN"])
  }

  // Count bytes to match the controller's Content-Length limit.
  use <- bool.lazy_guard(string.byte_size(text) > request.body_limit, fn() {
    Error(invalid(
      "Request body exceeds " <> int.to_string(request.body_limit) <> " bytes.",
      "--json",
    ))
  })

  // A dry run stops after local validation, before any credential is read.
  case options.dry_run {
    Set ->
      json.object([
        #("dry_run", json.bool(True)),
        #("method", json.string("POST")),
        #("url", json.string(base <> route)),
        #("body", body),
        #("validation", json.string("passed")),
      ])
      |> json.to_string
      |> write_line(host, _)
      |> Ok
    Unset -> {
      use token <- result.try(credential(host, names))
      use reply <- result.try(exchange(
        host,
        http.Post,
        base <> route,
        token,
        Some(text),
      ))
      use found <- result.try(response_document(reply))
      Ok(write_line(host, printed(found, fields)))
    }
  }
}

/// Build the request body from `--json` or positional arguments.
fn admission(
  host: Host,
  command: Command,
  options: Options,
) -> Result(json.Json, Failure) {
  // A payload replaces every positional. Otherwise the command picks a shape.
  case options.payload, command {
    Some(payload), _ -> {
      use <- bool.lazy_guard(options.arguments != [], fn() {
        Error(invalid("Use either --json or positional arguments.", "--json"))
      })
      use text <- result.try(payload_text(host, payload))

      // The payload goes through the same parser the controller runs.
      case command {
        Submit ->
          request.parse_submit(text)
          |> result.map(request.encode_submit)
          |> result.map_error(rejected)
        Plan
        | RunBuild
        | Status
        | Watch
        | Blob
        | SkillCommand
        | Init
        | Local
        | Worker
        | Describe ->
          request.parse_build(text)
          |> result.map(request.encode_build)
          |> result.map_error(rejected)
      }
    }
    None, Submit -> submit_arguments(options.arguments)
    None, _ -> build_arguments(host, command, options.arguments)
  }
}

/// Read an inline payload, or standard input for `-`.
fn payload_text(host: Host, payload: String) -> Result(String, Failure) {
  case payload {
    "-" ->
      host.read_stdin()
      |> result.try(bit_array.to_string)
      |> result.map_error(fn(_) {
        invalid("Expected one UTF-8 request object on stdin.", "--json")
      })
    _ -> Ok(payload)
  }
}

/// Build a submit body from `ID REPO PR [PR ...]`. Pull numbers are plain
/// decimal digits, and the group bounds come from `gantry_core/request`.
fn submit_arguments(arguments: List(String)) -> Result(json.Json, Failure) {
  // Three positionals is the least a group can have.
  case arguments {
    [id, repo, _, ..] -> {
      use numbers <- result.try(
        list.try_map(list.drop(arguments, 2), decimal)
        |> result.map_error(fn(_) {
          invalid("Expected decimal PR numbers.", "pulls")
        }),
      )
      request.submit(id, repo, numbers)
      |> result.map(request.encode_submit)
      |> result.map_error(rejected)
    }
    _ -> Error(invalid_input("Use gantry submit ID REPO PR [PR ...]."))
  }
}

/// Read an unsigned decimal number, as written on a command line.
fn decimal(text: String) -> Result(Int, Nil) {
  let digits = string.to_graphemes(text)
  let numeric =
    digits != [] && list.all(digits, string.contains("0123456789", _))

  // `int.parse` alone would accept a sign.
  case numeric {
    True -> int.parse(text)
    False -> Error(Nil)
  }
}

/// Build a plan or run body from `ID REPO COMMIT TARGET [ACTION.json]`. The
/// optional action file is closed under the same rules as `--json`.
fn build_arguments(
  host: Host,
  command: Command,
  arguments: List(String),
) -> Result(json.Json, Failure) {
  let usage =
    "Use gantry "
    <> command_name(command)
    <> " ID REPO COMMIT TARGET [AD_HOC_ACTION.json]."

  // Four positionals pin a build. A fifth names an ad hoc action file.
  use #(id, repo, revision, target, file) <- result.try(case arguments {
    [id, repo, revision, target] -> Ok(#(id, repo, revision, target, None))
    [id, repo, revision, target, file] ->
      Ok(#(id, repo, revision, target, Some(file)))
    _ -> Error(invalid_input(usage))
  })

  // An unreadable file and an invalid action fail on different fields.
  use action <- result.try(case file {
    None -> Ok(None)
    Some(path) -> {
      use text <- result.try(
        host.read_file(path)
        |> result.map_error(fn(_) {
          invalid("Expected a readable ad hoc action file.", "action")
        }),
      )
      request.parse_action(text)
      |> result.map(Some)
      |> result.map_error(rejected)
    }
  })

  request.build(id, repo, revision, target, action)
  |> result.map(request.encode_build)
  |> result.map_error(rejected)
}

fn rejected(rejection: Rejection) -> Failure {
  invalid(request.message(rejection), request.field(rejection))
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

/// Serve status, watch, and blob for one run ID or blob digest.
fn read(
  host: Host,
  command: Command,
  options: Options,
  base: String,
  fields: Option(Fields),
) -> Result(Nil, Failure) {
  let name = command_name(command)

  // A read takes exactly one positional and no request options.
  use id <- result.try(
    case options.payload, options.dry_run, options.arguments {
      None, Unset, [id] -> Ok(id)
      _, _, _ ->
        Error(invalid_input("Run gantry describe " <> name <> " for usage."))
    },
  )

  // Blobs are addressed by digest and readable by workers. Runs are
  // addressed by ID and readable by build and submit agents.
  let #(kind, valid, route, names) = case command {
    Blob -> #("sha256", blobs.valid(id), "/v1/blobs/", [
      "GANTRY_TOKEN",
      "GANTRY_WORKER_TOKEN",
    ])
    Plan
    | RunBuild
    | Submit
    | Status
    | Watch
    | SkillCommand
    | Init
    | Local
    | Worker
    | Describe -> #("id", request.valid_id(id), "/v1/runs/", [
      "GANTRY_TOKEN",
      "GANTRY_SUBMIT_TOKEN",
    ])
  }

  use <- bool.lazy_guard(!valid, fn() {
    Error(invalid(
      "Invalid "
        <> kind
        <> ". Run gantry describe "
        <> name
        <> " for its format.",
      kind,
    ))
  })
  let url = base <> route <> id

  // Watch checks its deadline before credentials, like every local check.
  case command {
    Watch -> {
      use seconds <- result.try(watch_seconds(host))
      use token <- result.try(credential(host, names))
      let deadline = host.clock() + seconds * 1000
      watch(host, Poll(url, token, id, fields, deadline), None, Unanswered)
    }
    Blob -> {
      use token <- result.try(credential(host, names))
      use reply <- result.try(exchange(host, http.Get, url, token, None))
      Ok(host.write(reply.body))
    }
    Plan
    | RunBuild
    | Submit
    | Status
    | SkillCommand
    | Init
    | Local
    | Worker
    | Describe -> {
      use token <- result.try(credential(host, names))
      use reply <- result.try(exchange(host, http.Get, url, token, None))
      use found <- result.try(response_document(reply))
      Ok(write_line(host, printed(found, fields)))
    }
  }
}

/// Read `GANTRY_WATCH_SECONDS`: one to nine digits without a leading zero.
fn watch_seconds(host: Host) -> Result(Int, Failure) {
  let text =
    host.environment("GANTRY_WATCH_SECONDS")
    |> result.lazy_unwrap(fn() { "1800" })
  let shaped =
    string.drop_start(text, 9) == "" && !string.starts_with(text, "0")

  // A malformed deadline is a configuration error, not a default.
  case shaped, decimal(text) {
    True, Ok(seconds) if seconds > 0 -> Ok(seconds)
    _, _ ->
      Error(invalid(
        "Expected a positive watch deadline in seconds.",
        "GANTRY_WATCH_SECONDS",
      ))
  }
}

/// Poll a run until a terminal phase or the deadline. Repeated states are
/// suppressed on the printed projection, so a watch with `--fields` prints
/// a line only when a selected field changes. Terminal state is read from
/// the full response.
///
/// A first request that gets no HTTP status fails at once: the URL is
/// wrong or nothing is listening, and retrying for the whole deadline
/// would only hide that. Once the controller has answered, transport
/// failures and HTTP 5xx are retried until the deadline, because a
/// controller restart or a lost quorum is expected to heal.
fn watch(
  host: Host,
  poll: Poll,
  previous: Option(String),
  contact: Contact,
) -> Result(Nil, Failure) {
  let remaining = poll.deadline - host.clock()
  use <- bool.lazy_guard(remaining <= 0, fn() {
    Error(failed("watch_timeout", "Timed out watching " <> poll.id <> "."))
  })
  let seconds = int.min(request_seconds, { remaining + 999 } / 1000)
  let retry = fn(previous) {
    host.sleep(poll_milliseconds)
    watch(host, poll, previous, Answered)
  }

  // Only a 2xx answer carries a state. 5xx and lost answers retry after
  // the controller has answered once.
  case send(host, http.Get, poll.url, poll.token, None, seconds), contact {
    Ok(reply), _ if reply.status >= 200 && reply.status < 300 -> {
      use next <- result.try(observe(host, poll, reply, previous))

      // A successful terminal phase ends the loop without an envelope.
      case next {
        Continue(line) -> retry(Some(line))
        Finished -> Ok(Nil)
      }
    }
    Ok(reply), _ if reply.status >= 500 && reply.status < 600 -> retry(previous)
    Ok(reply), _ -> Error(status_failure(reply))
    Error(Nil), Answered -> retry(previous)
    Error(Nil), Unanswered ->
      Error(failed(
        "transport_error",
        "Could not reach the controller for " <> poll.url <> ".",
      ))
  }
}

/// Print a changed state, then decide from the full run whether the
/// watch is done. A passed build and a landed submission succeed. A failed
/// or blocked run is a terminal failure whose state was already printed.
fn observe(
  host: Host,
  poll: Poll,
  reply: Response(BitArray),
  previous: Option(String),
) -> Result(Next, Failure) {
  use found <- result.try(response_document(reply))
  let line = printed(found, poll.fields)
  use run <- result.try(
    bit_array.to_string(reply.body)
    |> result.try(fn(text) {
      json.parse(text, protocol.run_decoder()) |> result.replace_error(Nil)
    })
    |> result.map_error(fn(_) { invalid_response() }),
  )

  // Repeats compare the printed text, so an unchanged projection is quiet.
  case Some(line) == previous {
    True -> Nil
    False -> write_line(host, line)
  }

  // Terminal phases end the watch with their documented outcome.
  case queue.phase(run), run.submission {
    "landed", _ | "passed", queue.Build -> Ok(Finished)
    "failed" as phase, _ | "blocked" as phase, _ ->
      Error(failed(
        "run_" <> phase,
        "Run " <> poll.id <> " finished with phase " <> phase <> ".",
      ))
    _, _ -> Ok(Continue(line))
  }
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

/// Read the controller base URL. It stays on HTTP(S), with no user info,
/// query, or fragment, so a credential can only travel in the header.
fn controller_url(host: Host) -> Result(String, Failure) {
  let url =
    host.environment("GANTRY_URL") |> result.lazy_unwrap(fn() { default_url })

  // One trailing slash is tolerated, as a shell user would type it.
  let url = case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1)
    False -> url
  }

  let bad = fn(_) {
    invalid("Expected an HTTP(S) controller base URL.", "GANTRY_URL")
  }

  // Split the scheme, the authority, and an optional base path.
  use rest <- result.try(case url {
    "http://" <> rest | "https://" <> rest -> Ok(rest)
    _ -> Error(bad(Nil))
  })

  // Everything after the first slash is the base path.
  let #(authority, path) = case string.split_once(rest, "/") {
    Ok(#(authority, path)) -> #(authority, "/" <> path)
    Error(Nil) -> #(rest, "")
  }

  // The path may hold only unreserved characters and slashes.
  use port <- result.try(
    origin.parse_authority(authority) |> result.map_error(bad),
  )
  let clean =
    list.all(string.to_graphemes(path), fn(c) {
      origin.alphanumeric(c) || string.contains("._~/-", c)
    })
  use <- bool.lazy_guard(!clean, fn() { Error(bad(Nil)) })

  // A five-digit port can still be out of range.
  case port {
    Some(port) if port > 65_535 ->
      Error(invalid("Controller port must be at most 65535.", "GANTRY_URL"))
    _ -> Ok(url)
  }
}

/// Read the first non-empty credential among the accepted variables. A
/// control character could split the Authorization header.
fn credential(host: Host, names: List(String)) -> Result(String, Failure) {
  let found =
    list.find_map(names, fn(name) {
      case host.environment(name) {
        Ok("") | Error(Nil) -> Error(Nil)
        Ok(token) -> Ok(token)
      }
    })
  let control = fn(token) {
    list.any(string.to_utf_codepoints(token), fn(point) {
      let n = string.utf_codepoint_to_int(point)
      n < 32 || n == 127
    })
  }

  // Missing and malformed credentials both exit 3.
  case found {
    Error(Nil) ->
      Error(Failure(
        Unauthorized,
        "missing_credentials",
        "Set " <> string.join(names, " or ") <> " for this operation.",
        None,
        None,
      ))
    Ok(token) ->
      case control(token) {
        True ->
          Error(Failure(
            Unauthorized,
            "invalid_credentials",
            "Credential contains a control character.",
            None,
            None,
          ))
        False -> Ok(token)
      }
  }
}

/// Send one request with the standard deadline and require a 2xx answer.
fn exchange(
  host: Host,
  method: http.Method,
  url: String,
  token: String,
  body: Option(String),
) -> Result(Response(BitArray), Failure) {
  case send(host, method, url, token, body, request_seconds) {
    Ok(reply) if reply.status >= 200 && reply.status < 300 -> Ok(reply)
    Ok(reply) -> Error(status_failure(reply))
    Error(Nil) ->
      Error(failed("transport_error", "Could not complete the HTTP request."))
  }
}

/// Send one request. An error means no HTTP status arrived.
fn send(
  host: Host,
  method: http.Method,
  url: String,
  token: String,
  body: Option(String),
  seconds: Int,
) -> Result(Response(BitArray), Nil) {
  use base <- result.try(http_request.to(url))
  let base =
    base
    |> http_request.set_method(method)
    |> http_request.set_header("authorization", "Bearer " <> token)
    |> http_request.set_body(<<>>)

  // Only an admission carries a JSON body.
  let outgoing = case body {
    None -> base
    Some(text) ->
      base
      |> http_request.set_header("content-type", "application/json")
      |> http_request.set_body(bit_array.from_string(text))
  }

  host.transport(outgoing, seconds * 1000)
}

/// Classify a non-2xx answer by its HTTP status, keeping at most 500
/// characters of the controller's own error message.
fn status_failure(reply: Response(BitArray)) -> Failure {
  let status = reply.status
  let message =
    bit_array.to_string(reply.body)
    |> result.try(document.parse)
    |> result.try(document.string(_, "error"))
    |> result.map(string.slice(_, 0, 500))
    |> result.lazy_unwrap(fn() {
      "Controller returned HTTP " <> int.to_string(status) <> "."
    })

  // Statuses the controller sends get specific codes. Others are failures.
  let #(exit, code) = case status {
    400 | 411 | 413 | 422 -> #(Invalid, "invalid_request")
    401 | 403 -> #(Unauthorized, "auth_failed")
    404 -> #(Missing, "not_found")
    409 -> #(Conflict, "conflict")
    _ -> #(Failed, "http_error")
  }

  Failure(exit, code, message, None, Some(status))
}

/// Require a response body that is exactly one JSON object.
fn response_document(reply: Response(BitArray)) -> Result(Document, Failure) {
  bit_array.to_string(reply.body)
  |> result.try(document.parse)
  |> result.map_error(fn(_) { invalid_response() })
}

fn invalid_response() -> Failure {
  failed("invalid_response", "Expected a JSON object from the controller.")
}

// ---------------------------------------------------------------------------
// Output and failures
// ---------------------------------------------------------------------------

fn printed(found: Document, fields: Option(Fields)) -> String {
  case fields {
    None -> document.to_string(found)
    Some(fields) -> document.to_string(document.project(found, fields))
  }
}

fn write_line(host: Host, line: String) -> Nil {
  host.write(bit_array.from_string(line <> "\n"))
}

// ---------------------------------------------------------------------------
// The process host
// ---------------------------------------------------------------------------

/// The effects of a real CLI process.
fn host() -> Host {
  Host(
    environment: envoy.get,
    transport: http_send,
    read_file: fn(path) {
      case simplifile.is_file(path) {
        Ok(True) -> simplifile.read(path) |> result.replace_error(Nil)
        Ok(False) | Error(_) -> Error(Nil)
      }
    },
    read_stdin: ffi_host.read_stdin,
    write: fn(bytes) {
      // A reader that closed stdout wants no more output. Stop the way a
      // shell tool stops on SIGPIPE.
      case ffi_host.write_stdout(bytes) {
        Ok(Nil) -> Nil
        Error(Nil) -> ffi_host.exit(141)
      }
    },
    report: io.println_error,
    clock: fn() {
      let #(seconds, nanoseconds) =
        timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
      seconds * 1000 + nanoseconds / 1_000_000
    },
    sleep: process.sleep,
    resource: bundled,
    release: fn() { release_root() |> result.map(fn(root) { root <> "/bin" }) },
  )
}

/// Send through httpc in a monitored process. httpc's error normaliser
/// raises on error shapes it does not know, such as a socket closed by the
/// peer, and a raise must count as "no HTTP status", not end the CLI.
fn http_send(
  outgoing: http_request.Request(BitArray),
  milliseconds: Int,
) -> Result(Response(BitArray), Nil) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let answer =
        httpc.configure()
        |> httpc.timeout(milliseconds)
        |> httpc.dispatch_bits(outgoing)
      process.send(reply, answer |> result.replace_error(Nil))
    })
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })

  // httpc enforces the deadline. The extra second only covers a stuck
  // helper process, which is then killed so it cannot answer later.
  case process.selector_receive(selector, milliseconds + 1000) {
    Ok(answer) -> {
      process.demonitor_process(monitor)
      answer
    }
    Error(Nil) -> {
      process.demonitor_process(monitor)
      process.kill(pid)
      Error(Nil)
    }
  }
}

/// The release root holds `bin`, `releases`, and `share`. The application's
/// private directory is `lib/gantry-VSN/priv` beneath it.
fn release_root() -> Result(String, Nil) {
  application.priv_directory("gantry")
  |> result.map(fn(priv) { priv <> "/../../.." })
}

/// Read a bundled file. The schema and skill live in the application's
/// private directory, in a release and a source build alike. The version
/// label exists only in a release.
fn bundled(resource: Resource) -> Result(String, Nil) {
  let read = fn(path) { simplifile.read(path) |> result.replace_error(Nil) }

  // A source checkout has no release label, so `--version` falls back.
  case resource {
    Schema ->
      application.priv_directory("gantry")
      |> result.try(fn(priv) { read(priv <> "/gantry-schema.json") })
    Skill ->
      application.priv_directory("gantry")
      |> result.try(fn(priv) { read(priv <> "/skill/SKILL.md") })
    Version ->
      release_root()
      |> result.try(fn(root) { read(root <> "/releases/gantry-version") })
      |> result.map(string.trim)
  }
}
