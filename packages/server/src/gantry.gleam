//// Serve HTTP after the shared queue is online. Reconciliation runs
//// independently so repository effects cannot hold up a worker.
////
//// ## Flow
////
//// `start` loads configuration and opens the Khepri replica, which has its
//// own OTP supervision under the Ra system. It then starts one supervisor
//// with two children, the HTTP listener and the submit reconciler. The
//// children are independent, so the supervisor restarts only the one that
//// crashes. Weft provides the reconciler's actor but has no supervisor of
//// its own, so the tree uses `gleam_otp`'s static supervisor, which accepts
//// Weft's `supervised` child specification and Mist's.
////
//// A child that crashes more than five times in a minute exceeds the
//// supervisor's restart tolerance. The supervisor then exits, `main` sees
//// it go down and stops the VM with status 1, and the service manager owns
//// the restart.

import gantry/config.{type Config}
import gantry/http_api
import gantry/internal/ffi_host
import gantry/reconcile
import gantry/store
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import logging
import mist

/// Start the controller on its configured loopback port.
///
/// ## Examples
///
/// ```gleam
/// // GANTRY_CONFIG=controller.toml gleam run
/// ```
pub fn main() -> Nil {
  logging.configure()

  // Keep serving after startup or report the failed dependency to the supervisor.
  case start() {
    Ok(tree) -> {
      // Stopping with the supervisor makes a restart-intensity failure
      // visible to the service manager instead of leaving a dead listener.
      let monitor = process.monitor(tree)
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_) { Nil })
      |> process.selector_receive_forever
      logging.log(logging.Critical, "controller supervisor stopped")
      ffi_host.exit_failure()
    }
    Error(reason) -> {
      logging.log(logging.Critical, reason)
      ffi_host.exit_failure()
    }
  }
}

/// Bring the queue online, then start the supervised listener and reconciler.
fn start() -> Result(process.Pid, String) {
  use cfg <- result.try(config.load())
  use Nil <- result.try(store.boot(cfg.data, cfg.seed))
  supervise(cfg)
  |> result.map(fn(started) { started.pid })
  |> result.map_error(fn(_) { "cannot start the controller supervisor" })
}

/// One supervisor over the listener and the reconciler. Each restarts alone.
fn supervise(
  cfg: Config,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let listener =
    mist.new(fn(req) { http_api.handle(cfg, req) })
    |> mist.bind("127.0.0.1")
    |> mist.port(cfg.port)

  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 60)
  |> supervisor.add(reconcile.supervised(cfg))
  |> supervisor.add(mist.supervised(listener))
  |> supervisor.start
}
