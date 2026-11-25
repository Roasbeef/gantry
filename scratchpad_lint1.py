import re
base='packages/server/src/gantry/'
def edit(name, pairs):
    p=base+name
    s=open(p).read()
    for old,new in pairs:
        if old not in s:
            raise SystemExit('missing in %s: %r' % (name, old[:60]))
        s=s.replace(old,new,1)
    open(p,'w').write(s)

edit('blobs.gleam',[
('''//// Queue transitions reference objects after their atomic publication.
''','''//// Queue transitions reference objects after their atomic publication.
////
//// `put` stages the bytes under a random name, flushes the file and each
//// directory above it with `sync`, and renames the file into place, so a
//// reader sees the whole object or none of it.
'''),
('''  use Nil <- result.try(check_digest(id))
  case simplifile.file_info(root <> "/objects/" <> id) {
    Ok(info) ->
      case simplifile.file_info_type(info), info.size <= limit {''','''  use Nil <- result.try(check_digest(id))

  // A missing path and a damaged one are different failures. Only a regular
  // file within the limit can be a published object.
  case simplifile.file_info(root <> "/objects/" <> id) {
    Ok(info) ->
      case simplifile.file_info_type(info), info.size <= limit {'''),
])

edit('cli/profile.gleam',[
('''  let worker_token = case worker_token {
    "" -> token(32)
    supplied -> supplied
  }
  use <- bool.guard(''','''  // Setup supplies no token when the operator has none to bring.
  let worker_token = case worker_token {
    "" -> token(32)
    supplied -> supplied
  }

  use <- bool.guard('''),
])

edit('config.gleam',[
('''  let roles = [token_digest(secrets.agent), token_digest(secrets.submit)]
  case workers {''','''  let roles = [token_digest(secrets.agent), token_digest(secrets.submit)]

  // No entry at all is the earlier shared-token format.
  case workers {'''),
])

edit('git.gleam',[
('''//// | Scratch files | Beside the mirror, random names | Deleted by the call that made them. |
''','''//// | Scratch files | Beside the mirror, random names | Deleted by the call that made them. |
////
//// `preserve` writes a candidate bundle under a random name in shared
//// storage, flushes it with `sync`, and renames it into place.
'''),
('''//// `session` takes the repository's lock, creates the mirror on first use,
//// and runs the caller's work against it.''','''//// `session` takes the repository's lock, creates the mirror on first use
//// with `open`, and runs the caller's work against it. `fetch` resolves a
//// ref or object to a commit, `command` and `ancestor` read it, and
//// `preserve` publishes a candidate bundle.'''),
])
