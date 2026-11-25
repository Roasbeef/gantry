import gantry/internal/ffi_worker_http.{
  type Timeouts, ControllerRequest, Timeouts,
}
import gantry/worker/controllers
import gleam/bit_array
import gleam/http

type Server

type Script {
  Body(bytes: BitArray)
  Chunks(count: Int, delay: Int)
  CloseAfter(bytes: BitArray)
}

@external(erlang, "gantry_test_http", "ensure_gun")
fn ensure_gun() -> Nil

@external(erlang, "gantry_test_http", "start")
fn start(script: Script) -> Server

@external(erlang, "gantry_test_http", "port")
fn port(server: Server) -> Int

@external(erlang, "gantry_test_http", "accepted")
fn accepted(server: Server) -> Int

@external(erlang, "gantry_test_http", "stop")
fn stop(server: Server) -> a

fn request(
  server: Server,
  body: BitArray,
  timeouts: Timeouts,
) -> Result(#(Int, BitArray), ffi_worker_http.DispatchError) {
  ensure_gun()
  ffi_worker_http.dispatch(
    ControllerRequest(
      scheme: http.Http,
      host: "127.0.0.1",
      port: port(server),
      method: http.Post,
      target: "/v1/claims",
      headers: [#("content-type", "application/octet-stream")],
      body:,
      timeouts:,
    ),
    1_048_576,
  )
}

const quick = Timeouts(connect: 2000, first_byte: 2000, idle: 2000)

pub fn one_connection_serves_many_exchanges_test() {
  let server = start(Body(<<"pong":utf8>>))
  assert request(server, <<"a":utf8>>, quick) == Ok(#(200, <<"pong":utf8>>))
  assert request(server, <<"b":utf8>>, quick) == Ok(#(200, <<"pong":utf8>>))
  assert request(server, <<"c":utf8>>, quick) == Ok(#(200, <<"pong":utf8>>))
  assert accepted(server) == 1
  stop(server)
}

pub fn a_closed_connection_is_replaced_before_the_next_exchange_test() {
  let server = start(CloseAfter(<<"bye":utf8>>))
  assert request(server, <<"a":utf8>>, quick) == Ok(#(200, <<"bye":utf8>>))
  assert request(server, <<"b":utf8>>, quick) == Ok(#(200, <<"bye":utf8>>))
  assert accepted(server) == 2
  stop(server)
}

pub fn a_large_upload_completes_test() {
  let server = start(Body(<<"ok":utf8>>))
  let big = bit_array.from_string(string_of(8 * 1024 * 1024))
  assert request(server, big, quick) == Ok(#(200, <<"ok":utf8>>))
  stop(server)
}

pub fn idle_timeout_restarts_with_each_chunk_test() {
  // Five chunks 300 ms apart take 1.5 s in total. The old single deadline of
  // that size would fail, while each gap is well inside the 1 s idle bound.
  let server = start(Chunks(5, 300))
  let timeouts = Timeouts(connect: 2000, first_byte: 2000, idle: 1000)
  assert request(server, <<>>, timeouts)
    == Ok(#(200, <<"abcdabcdabcdabcdabcd":utf8>>))
  stop(server)
}

pub fn a_stalled_response_times_out_between_chunks_test() {
  let server = start(Chunks(2, 800))
  let timeouts = Timeouts(connect: 2000, first_byte: 2000, idle: 300)
  assert request(server, <<>>, timeouts) == Error(ffi_worker_http.Unavailable)
  stop(server)
}

pub fn an_unreachable_origin_is_unavailable_test() {
  ensure_gun()
  let result =
    ffi_worker_http.dispatch(
      ControllerRequest(
        scheme: http.Http,
        host: "127.0.0.1",
        port: 1,
        method: http.Get,
        target: "/",
        headers: [],
        body: <<>>,
        timeouts: quick,
      ),
      1024,
    )
  assert result == Error(ffi_worker_http.Unavailable)
}

pub fn upload_allowance_grows_with_the_declared_size_test() {
  assert controllers.first_byte_allowance(0) == 30_000
  let blob = 64 * 1024 * 1024
  let allowance = controllers.first_byte_allowance(blob)

  // The old fixed 20 s deadline needed 3.4 MB/s. The allowance accepts a
  // link of 256 KiB/s with the idle margin on top.
  assert allowance >= 30_000 + blob * 1000 / 262_144
  assert allowance > 200_000
}

fn string_of(length: Int) -> String {
  string_repeat("x", length)
}

@external(erlang, "binary", "copy")
fn string_repeat(piece: String, times: Int) -> String
