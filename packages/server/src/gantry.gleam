//// Serve HTTP after the shared queue is online. Reconciliation runs
//// independently so repository effects cannot hold up a worker.

import gantry/config
import gantry/http_api
import gantry/internal/ffi_host
import gantry/reconcile
import gantry/store
import gleam/erlang/process
import gleam/io
import gleam/result
import mist

/// Start the controller on its configured loopback port.
///
/// ## Examples
///
/// ```gleam
/// // GANTRY_CONFIG=controller.toml gleam run
/// ```
pub fn main() -> Nil {
  // Keep serving after startup or report the failed dependency to the supervisor.
  case start() {
    Ok(Nil) -> process.sleep_forever()
    Error(reason) -> {
      io.println_error(reason)
      ffi_host.exit_failure()
    }
  }
}

/// Bring the queue and reconciler online before binding the loopback listener.
fn start() -> Result(Nil, String) {
  use cfg <- result.try(config.load())
  use Nil <- result.try(store.boot(cfg.data, cfg.seed))
  use Nil <- result.try(reconcile.start(cfg))
  mist.new(fn(req) { http_api.handle(cfg, req) })
  |> mist.bind("127.0.0.1")
  |> mist.port(cfg.port)
  |> mist.start
  |> result.replace_error("cannot start HTTP listener")
  |> result.map(fn(_) { Nil })
}
