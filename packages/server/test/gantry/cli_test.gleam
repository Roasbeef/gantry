//// The CLI runs against a fake host: environment, transport, files, stdin,
//// stdio, and the clock are injected, so argument handling, validation,
//// and response processing stay live while no controller runs.

import gantry/cli
import gantry_core/graph
import gantry_core/protocol
import gantry_core/queue
import gantry_core/request
import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request} as http_request
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile

const revision = "0123456789abcdef0123456789abcdef01234567"

const blob = "0000000000000000000000000000000000000000000000000000000000000000"

// ---------------------------------------------------------------------------
// Discovery and dry runs need neither credentials nor a controller.
// ---------------------------------------------------------------------------

pub fn help_json_describes_every_command_test() {
  let outcome = invoke(offline(), ["--help", "--json"])
  assert outcome.code == 0
  let text = outcome.stdout
  assert field(text, ["schema_version"], decode.int) == Ok(1)
  assert field(text, ["commands", "watch", "output"], decode.string)
    == Ok("ndjson")
  assert field(text, ["commands", "blob", "output"], decode.string) == Ok("raw")
  let assert Ok(required) =
    field(text, ["$defs", "build", "required"], decode.list(decode.string))
  assert list.contains(required, "revision")
}

pub fn describe_one_command_test() {
  let outcome = invoke(offline(), ["describe", "submit", "--output", "json"])
  assert outcome.code == 0
  let text = outcome.stdout
  assert field(text, ["command"], decode.string) == Ok("submit")
  assert field(text, ["method"], decode.string) == Ok("POST")
  assert field(text, ["route"], decode.string) == Ok("/v1/submits")
  assert field(text, ["request_body", "$ref"], decode.string)
    == Ok("#/$defs/submit")
  assert field(text, ["options", "--json", "argument"], decode.string)
    == Ok("PAYLOAD")
  assert field(text, ["options", "--local"], decode.dynamic) |> result.is_error
}

pub fn describe_unknown_command_test() {
  let outcome = invoke(offline(), ["describe", "nope"])
  assert outcome.code == 2
  assert error_code(outcome) == "invalid_input"
}

pub fn plan_dry_run_body_test() {
  let outcome =
    invoke(offline(), [
      "plan", "local", "fixture/project", revision, "check", "--dry-run",
      "--output", "json",
    ])
  assert outcome.code == 0
  assert field(outcome.stdout, ["url"], decode.string)
    == Ok("http://127.0.0.1:4737/v1/plans")
  assert field(outcome.stdout, ["method"], decode.string) == Ok("POST")
  let assert Ok(expected) =
    request.build("local", "fixture/project", revision, "check", None)
  assert json.to_string(request.encode_build(expected))
    == body_text(outcome.stdout)
}

pub fn run_dry_run_reads_action_file_test() {
  let action =
    "{\"name\":\"diagnostic\",\"argv\":[\"sh\",\"-ec\",\"echo fixture-ready\"],\"inputs\":[],\"outputs\":[\"result.txt\"]}"
  let host = Fake(..offline(), files: [#("action.json", action)])
  let outcome =
    invoke(host, [
      "run", "local", "fixture/project", revision, "check", "action.json",
      "--dry-run",
    ])
  assert outcome.code == 0
  assert field(
      outcome.stdout,
      ["body", "action", "outputs"],
      decode.list(decode.string),
    )
    == Ok(["result.txt"])
}

pub fn run_json_from_stdin_test() {
  let payload =
    "{\"id\":\"local\",\"repo\":\"fixture/project\",\"revision\":\""
    <> revision
    <> "\",\"target\":\"check\",\"action\":null}"
  let host = Fake(..offline(), stdin: Ok(bit_array.from_string(payload)))
  let outcome = invoke(host, ["run", "--json", "-", "--dry-run"])
  assert outcome.code == 0
  let assert Ok(url) = field(outcome.stdout, ["url"], decode.string)
  assert string.ends_with(url, "/v1/runs")
}

pub fn submit_json_dry_run_test() {
  let outcome =
    invoke(offline(), [
      "submit", "--json",
      "{\"id\":\"group\",\"repo\":\"fixture/project\",\"pulls\":[18,12]}",
      "--dry-run",
    ])
  assert outcome.code == 0
  assert field(outcome.stdout, ["body", "pulls"], decode.list(decode.int))
    == Ok([18, 12])
}

pub fn separator_allows_dash_positionals_test() {
  let outcome =
    invoke(offline(), [
      "plan", "--dry-run", "--", "-local", "fixture/project", revision, "-check",
    ])
  assert outcome.code == 0
  assert field(outcome.stdout, ["body", "id"], decode.string) == Ok("-local")
  assert field(outcome.stdout, ["body", "target"], decode.string)
    == Ok("-check")
}

pub fn version_json_test() {
  let outcome = invoke(offline(), ["--version", "--output", "json"])
  assert outcome.code == 0
  assert field(outcome.stdout, ["version"], decode.string) == Ok("Gantry test")
}

pub fn skill_is_raw_markdown_test() {
  let outcome = invoke(offline(), ["skill"])
  assert outcome.code == 0
  assert outcome.stdout == "# skill\n"
}

// ---------------------------------------------------------------------------
// Local validation fails before any request is sent.
// ---------------------------------------------------------------------------

pub fn invalid_inputs_test() {
  let cases = [
    #([], ["status", "local%2Fnext"], 2, "invalid_input"),
    #(
      [#("GANTRY_URL", "http://localhost:65536")],
      ["plan", "local", "fixture/project", revision, "check", "--dry-run"],
      2,
      "invalid_input",
    ),
    #(
      [#("GANTRY_URL", "http://user@localhost")],
      ["plan", "local", "fixture/project", revision, "check", "--dry-run"],
      2,
      "invalid_input",
    ),
    #([], ["status", "../local"], 2, "invalid_input"),
    #([], ["status", "local\n"], 2, "invalid_input"),
    #([], ["blob", "short"], 2, "invalid_input"),
    #(
      [],
      ["run", "--json", "{\"id\":\"one\"}", "--dry-run"],
      2,
      "invalid_input",
    ),
    #([], ["run", "local", "--json", "{}", "--dry-run"], 2, "invalid_input"),
    #(
      [],
      ["plan", "local", "fixture/project", "main", "check", "--dry-run"],
      2,
      "invalid_input",
    ),
    #(
      [],
      [
        "submit", "--json",
        "{\"id\":\"x\",\"repo\":\"fixture/project\",\"pulls\":[1],\"pull\":[1]}",
        "--dry-run",
      ],
      2,
      "invalid_input",
    ),
    #(
      [],
      ["submit", "group", "fixture/project", "12", "012", "--dry-run"],
      2,
      "invalid_input",
    ),
    #(
      [],
      ["submit", "group", "fixture/project", "-1", "--dry-run"],
      2,
      "invalid_input",
    ),
    #([], ["status", "--fields", "id,,phase", "local"], 2, "invalid_input"),
    #([], ["blob", blob, "--fields", "id"], 2, "invalid_input"),
    #([], ["blob", blob, "--output", "json"], 2, "invalid_input"),
    #([], ["status", "local", "--output", "raw"], 2, "invalid_input"),
    #([], ["status", "--fields"], 2, "invalid_input"),
    #([], ["status", "--json", "a", "--json", "b"], 2, "invalid_input"),
    #([], ["status", "-x"], 2, "invalid_input"),
    #([], ["frobnicate"], 2, "invalid_input"),
    #([], [], 2, "invalid_input"),
    #([], ["status", "local", "--local"], 2, "invalid_input"),
    #([#("GANTRY_WATCH_SECONDS", "0")], ["watch", "local"], 2, "invalid_input"),
    #([], ["status", "local"], 3, "missing_credentials"),
    #(
      [#("GANTRY_SUBMIT_TOKEN", "fixture-token")],
      ["blob", blob],
      3,
      "missing_credentials",
    ),
    #(
      [#("GANTRY_TOKEN", "bad\ttoken")],
      ["status", "local"],
      3,
      "invalid_credentials",
    ),
  ]
  list.each(cases, fn(case_) {
    let #(environment, arguments, code, error) = case_
    let host = Fake(..offline(), environment:)
    let outcome = invoke(host, arguments)
    assert outcome.code == code
    assert error_code(outcome) == error
    assert outcome.stdout == ""
    assert outcome.sent == []

    // Local failures never claim an HTTP status.
    assert field(outcome.stderr, ["error", "http_status"], decode.int)
      |> result.is_error
  })
}

pub fn missing_action_file_test() {
  let outcome =
    invoke(offline(), [
      "run", "local", "fixture/project", revision, "check", "missing.json",
      "--dry-run",
    ])
  assert outcome.code == 2
  assert field(outcome.stderr, ["error", "field"], decode.string)
    == Ok("action")
}

pub fn ad_hoc_dependencies_are_rejected_locally_test() {
  let action = "{\"name\":\"a\",\"argv\":[\"true\"],\"deps\":[\"b\"]}"
  let host = Fake(..offline(), files: [#("a.json", action)])
  let outcome =
    invoke(host, [
      "run", "local", "fixture/project", revision, "check", "a.json",
      "--dry-run",
    ])
  assert outcome.code == 2
  assert field(outcome.stderr, ["error", "message"], decode.string)
    == Ok(request.message(request.AdHocDependencies))
}

// ---------------------------------------------------------------------------
// Live requests through the injected transport.
// ---------------------------------------------------------------------------

pub fn plan_sends_authorized_json_test() {
  let outcome =
    invoke(live(), [
      "plan", "local", "fixture/project", revision, "check", "--output", "json",
    ])
  assert outcome.code == 0
  assert field(outcome.stdout, ["actions"], decode.list(decode.dynamic))
    == Ok([])
  let assert [sent] = outcome.sent
  assert sent.method == http.Post
  assert http_request.get_header(sent, "authorization")
    == Ok("Bearer fixture-token")
  assert http_request.get_header(sent, "content-type") == Ok("application/json")
  let assert Ok(body) = bit_array.to_string(sent.body)
  let assert Ok(parsed) = request.parse_build(body)
  assert request.build_id(parsed) == "local"
}

pub fn status_projects_fields_test() {
  let outcome =
    invoke(live(), [
      "status", "local", "--fields",
      "id,phase,submission.kind,work.task,missing", "--output", "json",
    ])
  assert outcome.code == 0
  assert outcome.stdout
    == "{\"id\":\"local\",\"phase\":\"passed\",\"submission\":{\"kind\":\"build\"}}\n"
}

pub fn status_after_separator_test() {
  let outcome = invoke(live(), ["status", "--fields", "id", "--", "-local"])
  assert outcome.code == 0
  assert outcome.stdout == "{\"id\":\"local\"}\n"
}

pub fn watch_passed_build_exits_zero_test() {
  let outcome = invoke(live(), ["watch", "local", "--fields", "id"])
  assert outcome.code == 0
  assert outcome.stdout == "{\"id\":\"local\"}\n"
}

pub fn watch_failed_run_prints_state_then_fails_test() {
  let outcome = invoke(live(), ["watch", "failed"])
  assert outcome.code == 1
  assert error_code(outcome) == "run_failed"
  assert field(outcome.stdout, ["phase"], decode.string) == Ok("failed")
  assert string.ends_with(outcome.stdout, "\n")
}

pub fn http_status_codes_map_to_exits_test() {
  let cases = [
    #(["watch", "denied"], 3, "auth_failed", 401),
    #(["status", "missing"], 4, "not_found", 404),
    #(["status", "conflict"], 6, "conflict", 409),
    #(["status", "invalid"], 2, "invalid_request", 400),
    #(["status", "limited"], 1, "http_error", 429),
  ]
  list.each(cases, fn(case_) {
    let #(arguments, code, error, status) = case_
    let outcome = invoke(live(), arguments)
    assert outcome.code == code
    assert error_code(outcome) == error
    assert field(outcome.stderr, ["error", "http_status"], decode.int)
      == Ok(status)
    assert outcome.stdout == ""
  })
  let outcome = invoke(live(), ["status", "missing"])
  assert field(outcome.stderr, ["error", "message"], decode.string)
    == Ok("unknown run")
}

pub fn watch_times_out_on_pending_run_test() {
  let host =
    Fake(..live(), environment: [
      #("GANTRY_WATCH_SECONDS", "3"),
      ..live().environment
    ])
  let outcome = invoke(host, ["watch", "pending"])
  assert outcome.code == 1
  assert error_code(outcome) == "watch_timeout"

  // One printed state, repeated polls suppressed.
  assert list.length(string.split(string.trim(outcome.stdout), "\n")) == 1
  assert list.length(outcome.sent) >= 3
}

pub fn watch_fails_fast_without_any_http_status_test() {
  let outcome = invoke(live(), ["watch", "unreachable"])
  assert outcome.code == 1
  assert error_code(outcome) == "transport_error"
  assert list.length(outcome.sent) == 1
  assert outcome.slept == 0
}

pub fn watch_retries_transport_and_5xx_after_an_answer_test() {
  // Pending, then a dropped connection, then 503, then passed.
  let host =
    Fake(..live(), sequence: [pending_body(), "", "503", passed_body()])
  let outcome = invoke(host, ["watch", "sequence"])
  assert outcome.code == 0
  assert list.length(outcome.sent) == 4
  assert list.length(string.split(string.trim(outcome.stdout), "\n")) == 2
}

pub fn watch_deduplicates_on_the_projection_test() {
  // The work list changes between polls while id and phase stay the same.
  let host =
    Fake(..live(), sequence: [
      pending_body(),
      pending_retry_body(),
      passed_body(),
    ])
  let outcome = invoke(host, ["watch", "sequence", "--fields", "id,phase"])
  assert outcome.code == 0
  assert outcome.stdout
    == "{\"id\":\"sequence\",\"phase\":\"pending\"}\n{\"id\":\"sequence\",\"phase\":\"passed\"}\n"

  // Without a projection every changed state is printed.
  let host =
    Fake(..live(), sequence: [
      pending_body(),
      pending_retry_body(),
      passed_body(),
    ])
  let outcome = invoke(host, ["watch", "sequence"])
  assert list.length(string.split(string.trim(outcome.stdout), "\n")) == 3
}

pub fn blob_is_binary_safe_test() {
  let host =
    Fake(..live(), environment: [#("GANTRY_WORKER_TOKEN", "fixture-token")])
  let outcome = invoke(host, ["blob", blob, "--output", "raw"])
  assert outcome.code == 0
  assert outcome.bytes == <<"blob":utf8, 0, 255, "bytes\n":utf8>>
}

// ---------------------------------------------------------------------------
// The published schema and the Gleam rules agree.
// ---------------------------------------------------------------------------

pub fn schema_examples_pass_the_request_rules_test() {
  let assert Ok(text) = simplifile.read("priv/gantry-schema.json")
  let examples = fn(definition) {
    let assert Ok(items) =
      field(
        text,
        ["$defs", definition, "examples"],
        decode.list(decode.dynamic),
      )
    list.map(items, fn(item) { json.to_string(dynamic_to_json(item)) })
  }
  let builds = examples("build")
  let submits = examples("submit")
  let actions = examples("action")
  assert builds != [] && submits != [] && actions != []
  list.each(builds, fn(body) {
    let assert Ok(_) = request.parse_build(body)
  })
  list.each(submits, fn(body) {
    let assert Ok(_) = request.parse_submit(body)
  })
  list.each(actions, fn(body) {
    let assert Ok(_) = request.parse_action(body)
  })
}

pub fn schema_exit_codes_match_the_cli_test() {
  let assert Ok(text) = simplifile.read("priv/gantry-schema.json")
  let assert Ok(codes) =
    field(text, ["exit_codes"], decode.dict(decode.string, decode.string))
  let documented =
    list.sort(
      list.map(
        [cli.Failed, cli.Invalid, cli.Unauthorized, cli.Missing, cli.Conflict],
        fn(exit) { string.inspect(cli.exit_code(exit)) },
      ),
      string.compare,
    )
  assert list.sort(
      list.filter(codes |> dict_keys, fn(key) { key != "0" }),
      string.compare,
    )
    == documented
}

// ---------------------------------------------------------------------------
// Fake host
// ---------------------------------------------------------------------------

type Fake {
  Fake(
    environment: List(#(String, String)),
    files: List(#(String, String)),
    stdin: Result(BitArray, Nil),
    online: Online,
    sequence: List(String),
  )
}

type Online {
  Offline
  Online
}

type Outcome {
  Outcome(
    code: Int,
    stdout: String,
    bytes: BitArray,
    stderr: String,
    sent: List(Request(BitArray)),
    slept: Int,
  )
}

type Event {
  Out(BitArray)
  Err(String)
  Sent(Request(BitArray))
  Slept(Int)
}

fn offline() -> Fake {
  Fake([], [], Error(Nil), Offline, [])
}

fn live() -> Fake {
  Fake([#("GANTRY_TOKEN", "fixture-token")], [], Error(Nil), Online, [])
}

fn invoke(fake: Fake, arguments: List(String)) -> Outcome {
  let events = process.new_subject()
  let clock = counter()
  let sequence = counter()
  let host =
    cli.Host(
      environment: fn(name) { list.key_find(fake.environment, name) },
      transport: fn(sent, _deadline) {
        process.send(events, Sent(sent))
        case fake.online {
          Offline -> Error(Nil)
          Online -> route(sent, fake.sequence, sequence)
        }
      },
      read_file: fn(path) { list.key_find(fake.files, path) },
      read_stdin: fn() { fake.stdin },
      write: fn(bytes) { process.send(events, Out(bytes)) },
      report: fn(line) { process.send(events, Err(line)) },
      clock: fn() { read(clock) },
      sleep: fn(milliseconds) {
        process.send(events, Slept(milliseconds))
        advance(clock, milliseconds)
      },
      resource: fn(resource) {
        case resource {
          cli.Schema ->
            simplifile.read("priv/gantry-schema.json")
            |> result.replace_error(Nil)
          cli.Skill -> Ok("# skill\n")
          cli.Version -> Ok("Gantry test")
        }
      },
      onboard: fn(_) { Error("onboarding is not part of this test") },
    )
  let code = cli.run(host, arguments)
  let events = drain(events, [])
  let bytes =
    list.filter_map(events, fn(event) {
      case event {
        Out(bytes) -> Ok(bytes)
        Err(_) | Sent(_) | Slept(_) -> Error(Nil)
      }
    })
    |> bit_array.concat
  Outcome(
    code:,
    stdout: bit_array.to_string(bytes) |> result.unwrap(""),
    bytes:,
    stderr: list.filter_map(events, fn(event) {
      case event {
        Err(line) -> Ok(line)
        Out(_) | Sent(_) | Slept(_) -> Error(Nil)
      }
    })
      |> string.join("\n"),
    sent: list.filter_map(events, fn(event) {
      case event {
        Sent(sent) -> Ok(sent)
        Out(_) | Err(_) | Slept(_) -> Error(Nil)
      }
    }),
    slept: list.count(events, fn(event) {
      case event {
        Slept(_) -> True
        Out(_) | Err(_) | Sent(_) -> False
      }
    }),
  )
}

fn drain(events: Subject(Event), acc: List(Event)) -> List(Event) {
  case process.receive(events, 0) {
    Ok(event) -> drain(events, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// Answer one request like the controller fixture in the old Bash check.
fn route(
  sent: Request(BitArray),
  sequence: List(String),
  calls: Subject(CounterMessage),
) -> Result(Response(BitArray), Nil) {
  let assert Ok("Bearer fixture-token") =
    http_request.get_header(sent, "authorization")
  case sent.path {
    "/v1/runs/local" | "/v1/runs/-local" -> ok(passed("local"))
    "/v1/runs/failed" -> ok(failed_body())
    "/v1/runs/pending" -> ok(pending_body())
    "/v1/runs/missing" -> reply(404, "{\"error\":\"unknown run\"}")
    "/v1/runs/conflict" ->
      reply(409, "{\"error\":\"run ID already has different inputs\"}")
    "/v1/runs/denied" -> reply(401, "{\"error\":\"authentication required\"}")
    "/v1/runs/invalid" -> reply(400, "{\"error\":\"invalid identifier\"}")
    "/v1/runs/limited" -> reply(429, "{\"error\":\"too many requests\"}")
    "/v1/runs/unreachable" -> Error(Nil)
    "/v1/runs/sequence" -> {
      let index = read(calls)
      advance(calls, 1)
      case list.drop(sequence, index) {
        ["", ..] | [] -> Error(Nil)
        ["503", ..] -> reply(503, "{\"error\":\"queue unavailable\"}")
        [body, ..] -> ok(body)
      }
    }
    "/v1/plans" -> ok("{\"revision\":\"" <> revision <> "\",\"actions\":[]}")
    "/v1/blobs/" <> _ ->
      Ok(
        response.new(200)
        |> response.set_body(<<"blob":utf8, 0, 255, "bytes\n":utf8>>),
      )
    _ -> Error(Nil)
  }
}

fn ok(body: String) -> Result(Response(BitArray), Nil) {
  reply(200, body)
}

fn reply(status: Int, body: String) -> Result(Response(BitArray), Nil) {
  Ok(response.new(status) |> response.set_body(bit_array.from_string(body)))
}

fn task() -> queue.Task {
  queue.Task(
    graph.Action("check", ["true"], ["."], [], [], [], 60),
    blob,
    blob,
    "default",
    "alpine",
  )
}

fn run_body(id: String, work: List(queue.Work)) -> String {
  queue.Run(id, "fixture/project", revision, "check", queue.Build, work)
  |> protocol.encode_run
  |> json.to_string
}

fn passed(id: String) -> String {
  run_body(id, [])
}

fn passed_body() -> String {
  passed("sequence")
}

fn pending_body() -> String {
  run_body("sequence", [queue.Work(task(), queue.Pending(0))])
}

fn pending_retry_body() -> String {
  run_body("sequence", [queue.Work(task(), queue.Pending(1))])
}

fn failed_body() -> String {
  run_body("failed", [queue.Work(task(), queue.Failed("exit 23", blob))])
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn field(
  text: String,
  path: List(String),
  decoder: decode.Decoder(a),
) -> Result(a, Nil) {
  json.parse(string.trim(text), decode.at(path, decoder))
  |> result.replace_error(Nil)
}

fn error_code(outcome: Outcome) -> String {
  field(outcome.stderr, ["error", "code"], decode.string) |> result.unwrap("")
}

/// The raw text of the dry run's `body` field, re-encoded canonically.
fn body_text(stdout: String) -> String {
  let assert Ok(body) = field(stdout, ["body"], decode.dynamic)
  let assert Ok(parsed) =
    request.parse_build(json.to_string(dynamic_to_json(body)))
  json.to_string(request.encode_build(parsed))
}

fn dynamic_to_json(value: Dynamic) -> json.Json {
  let decoder =
    decode.one_of(decode.string |> decode.map(json.string), [
      decode.bool |> decode.map(json.bool),
      decode.int |> decode.map(json.int),
      decode.float |> decode.map(json.float),
      decode.list(decode.dynamic)
        |> decode.map(fn(items) {
          json.preprocessed_array(list.map(items, dynamic_to_json))
        }),
      decode.dict(decode.string, decode.dynamic)
        |> decode.map(fn(fields) {
          json.object(
            list.map(dict_to_list(fields), fn(pair) {
              #(pair.0, dynamic_to_json(pair.1))
            }),
          )
        }),
    ])
  decode.run(value, decoder) |> result.unwrap(json.null())
}

fn dict_to_list(fields: dict.Dict(String, a)) -> List(#(String, a)) {
  dict.to_list(fields)
}

fn dict_keys(fields: dict.Dict(String, a)) -> List(String) {
  dict.keys(fields)
}

// A tiny counter process for the fake clock and request sequence.

type CounterMessage {
  Advance(Int)
  Read(Subject(Int))
}

fn counter() -> Subject(CounterMessage) {
  let ready = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(ready, inbox)
    counter_loop(inbox, 0)
  })
  let assert Ok(inbox) = process.receive(ready, 1000)
  inbox
}

fn counter_loop(inbox: Subject(CounterMessage), value: Int) -> Nil {
  case process.receive_forever(inbox) {
    Advance(by) -> counter_loop(inbox, value + by)
    Read(reply) -> {
      process.send(reply, value)
      counter_loop(inbox, value)
    }
  }
}

fn advance(counter: Subject(CounterMessage), by: Int) -> Nil {
  process.send(counter, Advance(by))
}

fn read(counter: Subject(CounterMessage)) -> Int {
  process.call(counter, 1000, Read)
}
