//// Gantry's dashboard: a Lustre application that polls the controller's
//// fleet snapshot and draws it as a pressure board. `model` holds every
//// state transition, `board` every decision about what the snapshot means,
//// and `view` the page. This module only connects them to the browser's
//// fetch and timer.

import dashboard/internal/ffi_browser
import dashboard/model.{type Model, type Msg}
import dashboard/view
import gleam/option.{None, Some}
import lustre
import lustre/effect.{type Effect}

/// How often the page asks for a new snapshot, in milliseconds. An idle
/// worker polls at most every 2 s, so a faster page would see nothing new.
const poll_ms = 2000

/// Start the page on the `#app` element.
///
/// ## Examples
///
/// ```gleam
/// // dashboard.main()
/// ```
pub fn main() -> Nil {
  let app = lustre.application(init, update, view.view)

  // A missing `#app` element leaves a blank page, so there is nothing to do.
  case lustre.start(app, "#app", Nil) {
    Ok(_) -> Nil
    Error(_) -> Nil
  }
}

/// Build the first model from the saved token and start the poll timer.
/// A saved token also starts the first fetch at once.
fn init(_: Nil) -> #(Model, Effect(Msg)) {
  let start = model.initial(ffi_browser.load_token())
  let ticks =
    effect.from(fn(dispatch) {
      ffi_browser.every(poll_ms, fn() { dispatch(model.Tick) })
    })

  // Fetch immediately only when there is a token to fetch with.
  case model.signed_in(start) {
    True -> #(
      model.Model(..start, in_flight: True),
      effect.batch([ticks, fetch_fleet(start.token)]),
    )
    False -> #(start, ticks)
  }
}

/// Apply one message through `model` and return the effect it asks for:
/// a fetch, a saved or cleared token, or nothing.
fn update(m: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  // Each message has its own transition, and only some start a request.
  case msg {
    model.DraftChanged(draft) -> #(model.Model(..m, draft:), effect.none())
    model.TokenSubmitted ->
      // An empty draft is ignored; any other draft becomes the token.
      case m.draft {
        "" -> #(m, effect.none())
        token -> {
          ffi_browser.save_token(token)
          let next = model.Model(..model.initial(token), in_flight: True)
          #(next, fetch_fleet(token))
        }
      }
    model.SignOut -> {
      ffi_browser.save_token("")
      #(model.initial(""), effect.none())
    }
    model.Tick ->
      // A tick fetches only when signed in with no request outstanding.
      case model.signed_in(m) && !m.in_flight {
        True -> #(model.Model(..m, in_flight: True), fetch_fleet(m.token))
        False -> #(m, effect.none())
      }
    model.FleetAnswered(status, body) -> {
      let next = model.receive(m, status, body)

      // A rejected token is forgotten so the next load asks again.
      case next.connection {
        model.SignedOut(_) -> ffi_browser.save_token("")
        model.Connecting | model.Live | model.Lost(_) -> Nil
      }

      #(next, effect.none())
    }
    model.RunChosen(run) -> {
      let #(next, digest) = model.choose_run(m, run)

      // A broken run opens on its failed action, whose log is fetched now.
      case digest {
        Some(digest) -> #(next, fetch_log(m.token, digest))
        None -> #(next, effect.none())
      }
    }
    model.FinishedToggled -> #(
      model.Model(..m, show_finished: !m.show_finished),
      effect.none(),
    )
    model.ActionChosen(run, action) -> {
      let #(next, digest) = model.choose_action(m, run, action)

      // Only an action with a log not yet held needs a fetch.
      case digest {
        Some(digest) -> #(next, fetch_log(m.token, digest))
        None -> #(next, effect.none())
      }
    }
    model.LogAnswered(digest, status, body) -> #(
      model.receive_log(m, digest, status, body),
      effect.none(),
    )
    model.TabChosen(tab) -> #(model.Model(..m, tab:), effect.none())
  }
}

/// An effect that requests the fleet snapshot and dispatches the answer.
fn fetch_fleet(token: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi_browser.get("/v1/fleet", token, fn(status, body) {
      dispatch(model.FleetAnswered(status, body))
    })
  })
}

/// An effect that requests one log blob by digest and dispatches the answer.
fn fetch_log(token: String, digest: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi_browser.get("/v1/blobs/" <> digest, token, fn(status, body) {
      dispatch(model.LogAnswered(digest, status, body))
    })
  })
}
