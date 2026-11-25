base='packages/server/src/gantry/'
def edit(name, pairs, root=base):
    p=root+name
    s=open(p).read()
    for old,new in pairs:
        if old not in s:
            raise SystemExit('missing in %s: %r' % (name, old[:70]))
        s=s.replace(old,new,1)
    open(p,'w').write(s)

edit('fault.gleam',[('//// ## Flow\n','//// ## Kinds\n')])

edit('github.gleam',[
('''//// Admission reads a pull over REST and `validate_submission` checks it.
//// Landing reads the same pull over GraphQL, because GraphQL reports the
//// merge state authoritatively, and `landing_verdict` judges it. Both''','''//// Admission calls `read_pull` for a REST response and `validate_submission`
//// to check it. Landing calls `read_landing_pull` for the same pull over
//// GraphQL, because GraphQL reports the merge state authoritatively, and
//// `landing_verdict` judges it. Both'''),
])

edit('submit.gleam',[
('''//// `reconcile` fetches the target and the stored bundle, then decides from
//// history alone whether the candidate already landed, the target moved
//// away from the tested base, or the same update can still be replayed.
//// Before a replay it checks policy, and it dispatches the push only when
//// every member passes.''','''//// `reconcile` fetches the target and the stored bundle, then decides from
//// history alone whether the candidate already landed, the target moved
//// away from the tested base, or the same update can still be replayed.
//// Before a replay, `check_members` asks `check_member` for each pull's
//// verdict, and the push is dispatched only when every member passes.
//// `confirm_refusal` looks at the target once more before a refusal stands.'''),
])

edit('../gantry.gleam',[
('''//// `start` loads configuration and opens the Khepri replica, which has its
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
//// the restart.''','''//// `main` calls `start`, which loads configuration and opens the Khepri
//// replica, which has its own OTP supervision under the Ra system. `start`
//// then calls `supervise` to start one supervisor with two children, the
//// HTTP listener and the submit reconciler. The children are independent, so
//// the supervisor restarts only the one that crashes. Weft provides the
//// reconciler's actor but has no supervisor of its own, so the tree uses the
//// static supervisor from the OTP package, which accepts the child
//// specifications of both Weft and Mist.
////
//// A child that crashes more than five times in a minute exceeds the
//// supervisor's restart tolerance. The supervisor then exits, `main` sees
//// it go down and stops the VM with status 1, and the service manager owns
//// the restart.'''),
])
