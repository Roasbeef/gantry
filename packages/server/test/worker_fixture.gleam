//// Shared builders for worker tests: a temporary directory, an assignment and
//// a journal connection.

import envoy
import gantry/blobs
import gantry/worker/custody
import gantry_core/graph
import gantry_core/queue
import gantry_core/sandbox
import gleam/int
import gleam/result
import simplifile
import sqlight

/// Create a unique empty directory under the system temporary directory.
pub fn temp_directory() -> String {
  let root = envoy.get("TMPDIR") |> result.unwrap("/tmp")
  let root = case root {
    "" -> "/tmp"
    _ -> root
  }
  let path =
    root <> "/gantry-worker-test-" <> int.to_string(int.random(1_000_000_000))
  let assert Ok(Nil) = simplifile.create_directory_all(path)
  path
}

/// Remove a directory made by `temp_directory`.
pub fn remove(path: String) -> Nil {
  let _ = simplifile.delete(path)
  Nil
}

/// Open a fresh journal for worker `w1` in a new directory.
pub fn journal() -> #(String, sqlight.Connection) {
  let directory = temp_directory()
  let assert Ok(db) = custody.open(directory <> "/custody.sqlite3", "w1")
  #(directory, db)
}

/// A valid assignment for worker `w1` with the given lease serial.
pub fn assignment(serial: Int) -> queue.Assignment {
  let digest = blobs.digest(<<"fixture":utf8>>)
  let assert Ok(lease) =
    queue.lease(serial, "w1", 0, 1, queue.Key(recipe: digest, dependencies: []))
  queue.Assignment(
    run: "run-1",
    task: queue.whole_task(
      action: graph.action(
        name: "build",
        argv: ["true"],
        inputs: ["."],
        outputs: ["out.txt"],
        dependencies: [],
        after: [],
        timeout: 60,
      ),
      source: digest,
      recipe: digest,
      pool: "linux",
      image: "alpine",
      sandbox: sandbox.Strict,
    ),
    lease: lease,
  )
}

/// A Docker-shaped attempt name derived from the serial.
pub fn name(serial: Int) -> String {
  "gantry-" <> blobs.digest(<<int.to_string(serial):utf8>>)
}
