base='packages/server/src/gantry/'
def edit(name, pairs):
    p=base+name
    s=open(p).read()
    for old,new in pairs:
        if old not in s:
            raise SystemExit('missing in %s: %r' % (name, old[:70]))
        s=s.replace(old,new,1)
    open(p,'w').write(s)

edit('reconcile.gleam',[
('''fn tick(state: State, now: Int) -> State {
  case store.change(''','''fn tick(state: State, now: Int) -> State {
  // An unreadable queue changes nothing. Otherwise each due intent gets an
  // attempt, and intents that left the queue lose their retry entries.
  case store.change('''),
('''  let name = key(intent)
  case due(retries, name, now) {
    False -> retries
    True ->
      case reconcile_one(cfg, intent) {''','''  let name = key(intent)

  // An intent inside its backoff window waits for a later tick.
  case due(retries, name, now) {
    False -> retries
    True ->
      // A decision clears the entry, and an error doubles the wait.
      case reconcile_one(cfg, intent) {'''),
('''  let delay = case dict.get(retries, name) {
    Ok(previous) -> int.min(previous.delay * 2, longest_delay)
    Error(Nil) -> first_delay
  }
  dict.insert''','''  // A first failure waits the base delay. Later ones double the last wait.
  let delay = case dict.get(retries, name) {
    Ok(previous) -> int.min(previous.delay * 2, longest_delay)
    Error(Nil) -> first_delay
  }

  dict.insert'''),
('''  store.change(fn(state) {
    queue.record_landing(state, intent, recorded)''','''
  store.change(fn(state) {
    queue.record_landing(state, intent, recorded)'''),
('''  let level = case reason {
    fault.Unavailable(_) | fault.Conflict(_) -> logging.Warning
    _ -> logging.Error
  }
  logging.log''','''  // Dependency failures clear themselves, and the fault kinds below describe
  // a request or durable state that an operator must look at.
  let level = case reason {
    fault.Unavailable(_) | fault.Conflict(_) -> logging.Warning
    fault.Invalid(_)
    | fault.Unauthorized(_)
    | fault.Forbidden(_)
    | fault.NotFound(_)
    | fault.Internal(_) -> logging.Error
  }

  logging.log'''),
('''//// | Event for an intent | Retry table |''','''//// | Event for an intent | Retry table |'''),
])
