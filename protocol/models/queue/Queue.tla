------------------------------- MODULE Queue -------------------------------
EXTENDS Naturals, FiniteSets
\* Two groups share one lane and, with an independent build, one executor
\* slot. A group starts Waiting and is prepared in order when the lane is
\* free. A lease that outlives its deadline expires and is reassigned under a
\* new generation. The last permitted attempt fails the run and skips its
\* remaining actions.
Lane == {1, 2}
Runs == {1, 2, 3}
MaxAttempts == 2
Tokens == Runs \X (1..MaxAttempts)
VARIABLES gen, step, sub, base, skip, slot, custody, receipts, proof,
          intent, head, landed, nwrite
vars == <<gen, step, sub, base, skip, slot, custody, receipts, proof,
          intent, head, landed, nwrite>>
Init == /\ gen = [r \in Runs |-> 0] /\ step = [r \in Runs |-> "pending"]
        /\ sub = [r \in Runs |-> IF r \in Lane THEN "waiting" ELSE "build"]
        /\ base = [r \in Runs |-> 0]
        /\ skip = {} /\ slot = 0 /\ custody = {} /\ receipts = {}
        /\ proof = {} /\ intent = 0 /\ head = 0 /\ landed = {}
        /\ nwrite = [r \in Runs |-> 0]
\* A queued group with live work, or a landing group, reserves the lane.
Holds(r) == sub[r] = "queued" /\ step[r] # "failed"
Head(r) == /\ sub[r] = "waiting"
           /\ \A q \in Lane : q < r => sub[q] # "waiting"
           /\ \A q \in Lane : ~Holds(q)
Prepare(r) == /\ Head(r)
              /\ sub' = [sub EXCEPT ![r] = "queued"]
              /\ base' = [base EXCEPT ![r] = head]
              /\ UNCHANGED <<gen, step, skip, slot, custody, receipts, proof,
                             intent, head, landed, nwrite>>
Refuse(r) == /\ Head(r)
             /\ sub' = [sub EXCEPT ![r] = "unprepared"]
             /\ UNCHANGED <<gen, step, base, skip, slot, custody, receipts,
                            proof, intent, head, landed, nwrite>>
Claim(r) == /\ sub[r] \in {"queued", "build"} /\ step[r] = "pending" /\ slot = 0
            /\ gen[r] < MaxAttempts
            /\ gen' = [gen EXCEPT ![r] = @ + 1]
            /\ step' = [step EXCEPT ![r] = "active"] /\ slot' = r
            /\ UNCHANGED <<sub, base, skip, custody, receipts, proof, intent,
                           head, landed, nwrite>>
\* A worker may run any issued generation, including one that has expired.
Deliver(t) == /\ t[2] <= gen[t[1]] /\ t \notin receipts
              /\ custody' = custody \cup {t}
              /\ UNCHANGED <<gen, step, sub, base, skip, slot, receipts, proof,
                             intent, head, landed, nwrite>>
WorkerDone(t) == /\ t \in custody /\ custody' = custody \ {t}
                 /\ receipts' = receipts \cup {t}
                 /\ UNCHANGED <<gen, step, sub, base, skip, slot, proof,
                                intent, head, landed, nwrite>>
\* The clock supplies no fence. The old worker keeps its custody and may
\* still report, but its generation is no longer the live one.
Expire(r) == /\ step[r] = "active"
             /\ step' = [step EXCEPT ![r] = IF gen[r] >= MaxAttempts
                                              THEN "failed" ELSE "pending"]
             /\ skip' = IF gen[r] >= MaxAttempts THEN skip \cup {r} ELSE skip
             /\ slot' = 0
             /\ UNCHANGED <<gen, sub, base, custody, receipts, proof, intent,
                            head, landed, nwrite>>
Accept(t) == LET r == t[1] IN
             /\ t \in receipts /\ step[r] = "active" /\ t[2] = gen[r]
             /\ proof' = proof \cup {t}
             /\ step' = [step EXCEPT ![r] = "passed"] /\ slot' = 0
             /\ UNCHANGED <<gen, sub, base, skip, custody, receipts, intent,
                            head, landed, nwrite>>
RejectLive(t) == LET r == t[1] IN
                 /\ t \in receipts /\ step[r] = "active" /\ t[2] = gen[r]
                 /\ step' = [step EXCEPT ![r] = "failed"] /\ slot' = 0
                 /\ skip' = skip \cup {r}
                 /\ UNCHANGED <<gen, sub, base, custody, receipts, proof,
                                intent, head, landed, nwrite>>
StartLanding(r) == /\ intent = 0 /\ sub[r] = "queued"
                   /\ <<r, gen[r]>> \in proof /\ r \notin landed
                   /\ intent' = r
                   /\ UNCHANGED <<gen, step, sub, base, skip, slot, custody,
                                  receipts, proof, head, landed, nwrite>>
GitCAS == /\ intent \in Runs /\ head = base[intent]
          /\ head' = intent
          /\ nwrite' = [nwrite EXCEPT ![intent] = @ + 1]
          /\ UNCHANGED <<gen, step, sub, base, skip, slot, custody, receipts,
                         proof, intent, landed>>
\* An outside writer moves the head to a commit that is not a run.
ExternalAdvance == /\ head # 4 /\ ~(intent \in Runs /\ head = intent)
                   /\ head' = 4
                   /\ UNCHANGED <<gen, step, sub, base, skip, slot, custody,
                                  receipts, proof, intent, landed, nwrite>>
Reconcile == /\ intent \in Runs /\ head # base[intent]
             /\ landed' = IF head = intent THEN landed \cup {intent} ELSE landed
             /\ sub' = [sub EXCEPT ![intent] = IF head = intent
                                                 THEN "landed" ELSE "blocked"]
             /\ intent' = 0
             /\ UNCHANGED <<gen, step, base, skip, slot, custody, receipts,
                            proof, head, nwrite>>
\* The provider denies a candidate before any push, so the head is unchanged.
Deny == /\ intent \in Runs /\ head = base[intent]
        /\ sub' = [sub EXCEPT ![intent] = "blocked"] /\ intent' = 0
        /\ UNCHANGED <<gen, step, base, skip, slot, custody, receipts, proof,
                       head, landed, nwrite>>
Next == \/ \E r \in Runs : Prepare(r) \/ Refuse(r) \/ Claim(r) \/ Expire(r)
                           \/ StartLanding(r)
        \/ \E t \in Tokens : Deliver(t) \/ WorkerDone(t) \/ Accept(t)
                             \/ RejectLive(t)
        \/ GitCAS \/ Reconcile \/ Deny \/ ExternalAdvance
Spec == Init /\ [][Next]_vars
\* One live lease per slot and no more than one lease in all.
Capacity == /\ \A r \in Runs : (step[r] = "active") = (slot = r)
            /\ Cardinality({r \in Runs : step[r] = "active"}) <= 1
\* A proof exists only for a generation that was live when it was accepted.
Fresh == \A t \in proof : t \in receipts /\ gen[t[1]] = t[2]
Exact == /\ (intent # 0 => <<intent, gen[intent]>> \in proof)
         /\ (head \in Runs => <<head, gen[head]>> \in proof)
         /\ \A r \in landed : <<r, gen[r]>> \in proof /\ nwrite[r] = 1
\* An intent may mutate the target once.
OneWrite == \A r \in Runs : nwrite[r] <= 1
\* A waiting group never builds, and only a failed group skips actions.
WaitingIdle == \A r \in Runs : sub[r] = "waiting" =>
                 gen[r] = 0 /\ step[r] = "pending" /\ r \notin skip
Skips == \A r \in Runs : (step[r] = "failed") = (r \in skip)
OneHolder == Cardinality({r \in Lane : Holds(r)}) <= 1
Ordered == \A r, q \in Lane : (q < r /\ sub[q] = "waiting") => sub[r] = "waiting"
=============================================================================
