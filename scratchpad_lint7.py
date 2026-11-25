p='packages/server/src/gantry/cli/onboarding.gleam'
s=open(p).read()
a=s.index('  let config = controller_config(directory, local)\n\n  // The configuration is written once')
b=s.index("  // The controller's HOME holds its distribution cookie")
s=s[:a]+'''  use Nil <- result.try(write_controller_config(directory, local))

'''+s[b:]
s=s.replace('''/// Write the controller configuration and cookie once, and the client''','''/// Write the controller configuration once, so an operator's edits survive.
/// A file from an earlier release lists no worker and would fail to load, so
/// the local worker is appended to it once.
fn write_controller_config(
  directory: String,
  local: profile.Local,
) -> Result(Nil, String) {
  let path = directory <> "/controller.toml"

  // A missing file is new, and a saved one is kept unless it lacks workers.
  case simplifile.read(path) {
    Error(_) ->
      profile.save(
        directory,
        "controller.toml",
        controller_config(directory, local),
      )
    Ok(saved) ->
      // Only the earlier format needs the worker appended.
      case string.contains(saved, "[[worker]]") {
        True -> Ok(Nil)
        False ->
          profile.save(
            directory,
            "controller.toml",
            string.trim_end(saved) <> "\\n\\n" <> worker_entry(local),
          )
      }
  }
}

/// Write the controller configuration and cookie once, and the client''',1)
open(p,'w').write(s)
