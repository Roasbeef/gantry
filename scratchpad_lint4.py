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
('''//// Every second the actor runs `maintain_queue`, then reads the landing
//// intents from the queue. For each intent that is due it asks
//// `submit.reconcile` for the observed outcome and records a definite one
//// through the queue. Any error is logged and moves the intent's next
//// attempt later. A resolved intent leaves the table, and so does an intent
//// that another controller resolved first.''','''//// Every second the actor runs `maintain_queue`, then `tick` reads the
//// landing intents from the queue. For each intent that is `due`, `attempt`
//// asks `submit.reconcile` for the observed outcome and records a definite
//// one through the queue. Any error is logged, and `failed` moves the
//// intent's next attempt later. `resolved` removes an intent that reached a
//// decision, and `tick` drops an intent that another controller resolved
//// first.'''),
])

edit('fault.gleam',[
('''//// ## Flow
////
//// A lower layer (store, Git, GitHub, blobs) classifies a failure where it
//// happens, because only that layer knows whether a retry can help. The
//// request layer passes the value through unchanged, and `http_api` maps it
//// to a status once.
////''','''//// ## Flow
////
//// A lower layer (store, Git, GitHub, blobs) classifies a failure where it
//// happens, because only that layer knows whether a retry can help. The
//// request layer passes the value through unchanged. The HTTP layer calls
//// `status` once to pick the response code, and `detail` supplies the
//// message. The table below lists each kind. Nothing else inspects a fault
//// to decide what to do with it.
////'''),
('''//// The Erlang Khepri bridge builds `Unavailable` and `Internal` values as
//// `{unavailable, Detail}` and `{internal, Detail}`, which is how Gleam
//// represents these variants on the BEAM. Renaming either variant requires
//// the same change in `gantry_khepri_ffi.erl`.''','''//// The Erlang Khepri bridge builds Unavailable and Internal values as the
//// tuples `{unavailable, Detail}` and `{internal, Detail}`, which is how
//// Gleam represents these variants on the BEAM. Renaming either variant
//// requires the same change in the bridge.'''),
])
