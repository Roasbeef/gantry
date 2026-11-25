base='packages/server/src/gantry/'
def edit(name, pairs):
    p=base+name
    s=open(p).read()
    for old,new in pairs:
        if old not in s:
            raise SystemExit('missing in %s: %r' % (name, old[:70]))
        s=s.replace(old,new,1)
    open(p,'w').write(s)

edit('git.gleam',[
('''  // Send credentials only to the configured GitHub HTTPS endpoint. Git's
  // housekeeping must finish inside the call that triggers it, or it would
  // run after the lock is released.
  let #(url, configuration) = case repo.provider {''','''  // Send credentials only to the configured GitHub HTTPS endpoint. Git's
  // housekeeping must finish inside the call that triggers it, or it would
  // run after the lock is released.
  let #(url, configuration) = case repo.provider {'''),
('''  let s = Session(mirror(cfg, repo), url, environment(configuration))

  ffi_lock''','''
  let s = Session(mirror(cfg, repo), url, environment(configuration))

  ffi_lock'''),
('''fn open(s: Session) -> Result(Nil, Fault) {
  case simplifile.is_file(s.dir <> "/HEAD") {''','''fn open(s: Session) -> Result(Nil, Fault) {
  // A finished initialization is the only state worth reusing.
  case simplifile.is_file(s.dir <> "/HEAD") {'''),
('''pub fn fetch(s: Session, reference: String) -> Result(String, Fault) {
  case string.starts_with(reference, "refs/") {''','''pub fn fetch(s: Session, reference: String) -> Result(String, Fault) {
  // A ref moves, so it is tracked and refetched. An object ID is fixed.
  case string.starts_with(reference, "refs/") {'''),
])
