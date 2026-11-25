base='packages/server/src/gantry/'
def edit(name, pairs):
    p=base+name
    s=open(p).read()
    for old,new in pairs:
        if old not in s:
            raise SystemExit('missing in %s: %r' % (name, old[:70]))
        s=s.replace(old,new,1)
    open(p,'w').write(s)

edit('cli/onboarding.gleam',[
('''    False -> Ok(Nil)
  })
  use Nil <- result.try(check_remote(
    effects,
    endpoint,
    profile.worker_token(slot),
    worker_entry_for(slot),
  ))
''','''    False -> Ok(Nil)
  })

  use Nil <- result.try(check_remote(
    effects,
    endpoint,
    profile.worker_token(slot),
    worker_stanza(profile.worker_id(slot), profile.worker_token(slot)),
  ))
'''),
('''/// The `controller.toml` entry that registers a remote slot.
fn worker_entry_for(slot: profile.Worker) -> String {
  worker_stanza(profile.worker_id(slot), profile.worker_token(slot))
}

''',''),
('''  let path = directory <> "/controller.toml"
  use Nil <- result.try(case simplifile.read(path) {
    Error(_) -> profile.save(directory, "controller.toml", config)
    Ok(saved) ->
      case string.contains(saved, "[[worker]]") {
        True -> Ok(Nil)
        False ->
          profile.save(
            directory,
            "controller.toml",
            string.trim_end(saved) <> "\\n\\n" <> worker_entry(local),
          )
      }
  })
''','''  let path = directory <> "/controller.toml"
  use Nil <- result.try(
    // A missing file is new, and a saved one is kept unless it lacks workers.
    case simplifile.read(path) {
      Error(_) -> profile.save(directory, "controller.toml", config)
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
    },
  )
'''),
])

edit('github.gleam',[
('''  use text <- decode.then(decode.string)
  case string.lowercase(text) {
    "open" ->''','''  use text <- decode.then(decode.string)

  // An unknown state is a decoding failure and never a guess.
  case string.lowercase(text) {
    "open" ->'''),
('''    _ -> decode.failure(Open, "PullState")
  }
}''','''    _ -> decode.failure(Open, "PullState")
  }
}'''),
('''  use draft <- decode.then(decode.bool)
  case draft {''','''  use draft <- decode.then(decode.bool)

  // The wire boolean becomes a named state.
  case draft {'''),
('''  use text <- decode.then(decode.string)
  case string.lowercase(text) {
    "clean" ->''','''  use text <- decode.then(decode.string)

  // An unknown merge state is a decoding failure and never a guess.
  case string.lowercase(text) {
    "clean" ->'''),
])

edit('http_api.gleam',[
('''  let worker = bearer(req) |> result.try(config.worker_for(cfg, _))
  case accepts(req, cfg.agent_token), worker {''','''  let worker = bearer(req) |> result.try(config.worker_for(cfg, _))

  // The agent token or any registered worker credential may read.
  case accepts(req, cfg.agent_token), worker {'''),
])

edit('prepare.gleam',[
('''        use Nil <- result.try(case info.size <= blobs.limit {
          True -> Ok(Nil)
          False ->
            Error(fault.Invalid("source archive exceeds worker transfer limit"))
        })
        simplifile.read_bits(path)''','''        use Nil <- result.try(case info.size <= blobs.limit {
          True -> Ok(Nil)
          False ->
            Error(fault.Invalid("source archive exceeds worker transfer limit"))
        })

        simplifile.read_bits(path)'''),
('''      let paths = case inputs {
        ["."] -> []
        other -> other
      }
      let path = git.scratch(s, "source.tar")''','''      let paths = case inputs {
        ["."] -> []
        other -> other
      }

      let path = git.scratch(s, "source.tar")'''),
])

edit('store.gleam',[
('''  use Nil <- result.try(case how {
    // Khepri creates a new singleton if Ra cannot find the server. An
    // established voter must refuse that fallback after disk loss.
    Reopen ->''','''  // Each way of opening ends with a started store server.
  use Nil <- result.try(case how {
    // Khepri creates a new singleton if Ra cannot find the server. An
    // established voter must refuse that fallback after disk loss.
    Reopen ->'''),
('''  use Nil <- result.try(case string.byte_size(bytes) > max_bytes {
    True -> Error(fault.Internal("invalid durable queue snapshot"))
    False -> Ok(Nil)
  })
  use state''','''  use Nil <- result.try(case string.byte_size(bytes) > max_bytes {
    True -> Error(fault.Internal("invalid durable queue snapshot"))
    False -> Ok(Nil)
  })

  use state'''),
('''fn confirm_quiet() -> Result(QuietCheck, Fault) {
  case ffi_khepri.hint_read() {
    Error(Nil) -> Ok(NeedsClaim)
    Ok(remembered) -> {
      use outcome <- result.try(ffi_khepri.matches(remembered))
      case outcome {''','''fn confirm_quiet() -> Result(QuietCheck, Fault) {
  // With nothing remembered there is nothing to confirm.
  case ffi_khepri.hint_read() {
    Error(Nil) -> Ok(NeedsClaim)
    Ok(remembered) -> {
      use outcome <- result.try(ffi_khepri.matches(remembered))

      // The leader's answer decides whether the poll may stop here.
      case outcome {'''),
('''//// The Erlang bridge performs single Khepri, Ra and ETS calls. This module
//// decides what to do with them: whether a node bootstraps or joins, which
//// marker it trusts, how large a snapshot may be, and when a remembered
//// quiet snapshot may answer a poll.''','''//// The Erlang bridge performs single Khepri, Ra and ETS calls. This module
//// decides what to do with them: whether a node bootstraps or joins, which
//// marker it trusts, how large a snapshot may be, and when a remembered
//// quiet snapshot may answer a poll. The remembered snapshot and every
//// leader comparison use the SHA-256 `digest` of its bytes, so a poll
//// sends 32 bytes to the leader and receives a boolean.'''),
])

edit('submit.gleam',[
('''  // History confirms a landing, excludes it, or permits replay of the same update.
  case landed, observed == c.base {
    True, _ -> Ok(Landed)
    False, False -> Ok(Refused(advanced))
    False, True -> {
      use verdict <- result.try(check_members(cfg, repo, s, c))
      case verdict {''','''  // History confirms a landing, excludes it, or permits replay of the same update.
  case landed, observed == c.base {
    True, _ -> Ok(Landed)
    False, False -> Ok(Refused(advanced))
    False, True -> {
      use verdict <- result.try(check_members(cfg, repo, s, c))

      // Only a permitted pull reaches the push. A refusal is checked once
      // more, and an unknown merge state leaves the intent open.
      case verdict {'''),
('''  use landed <- result.try(git.ancestor(s, c.commit, observed))
  case landed, observed == c.base {
    True, _ -> Ok(Landed)
    False, False -> Ok(Refused(advanced))
    False, True -> Ok(Refused(reason))''','''  use landed <- result.try(git.ancestor(s, c.commit, observed))

  // The second look can show a landing, an advance, or the same base.
  case landed, observed == c.base {
    True, _ -> Ok(Landed)
    False, False -> Ok(Refused(advanced))
    False, True -> Ok(Refused(reason))'''),
('''  m: queue.Member,
) -> Result(github.Verdict, Fault) {
  case repo.provider {''','''  m: queue.Member,
) -> Result(github.Verdict, Fault) {
  // The provider decides where the pull's current state comes from.
  case repo.provider {'''),
('''      use actual <- result.try(prepare.member(cfg, repo, s, m.pull))
      case actual == m {''','''      use actual <- result.try(prepare.member(cfg, repo, s, m.pull))

      // The pin must still name the head that was tested.
      case actual == m {'''),
])
