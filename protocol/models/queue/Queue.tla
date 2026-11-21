------------------------------- MODULE Queue -------------------------------
EXTENDS Naturals, FiniteSets
Runs == {1, 2}
Tokens == Runs \X (1..2)
VARIABLES gen, active, slot, custody, receipts, proof, intent, head, landed
vars == <<gen, active, slot, custody, receipts, proof, intent, head, landed>>
Init == /\ gen = [r \in Runs |-> 0] /\ active = {}
        /\ slot = 0 /\ custody = {} /\ receipts = {} /\ proof = {}
        /\ intent = 0 /\ head = 0 /\ landed = {}
Claim(r) == /\ slot = 0 /\ gen[r] < 2
            /\ \A t \in proof : t[1] # r
            /\ gen' = [gen EXCEPT ![r] = @ + 1]
            /\ active' = active \cup {r} /\ slot' = r
            /\ UNCHANGED <<custody, receipts, proof, intent, head, landed>>
Deliver(r) == LET t == <<r, gen[r]>> IN
              /\ r \in active /\ t \notin receipts /\ custody' = custody \cup {t}
              /\ UNCHANGED <<gen, active, slot, receipts, proof, intent, head, landed>>
WorkerDone(t) == /\ t \in custody /\ custody' = custody \ {t}
                 /\ receipts' = receipts \cup {t}
                 /\ UNCHANGED <<gen, active, slot, proof, intent, head, landed>>
Fence(r) == /\ r \in active /\ active' = active \ {r}
            /\ slot' = 0 /\ custody' = custody \ {<<r, gen[r]>>}
            /\ UNCHANGED <<gen, receipts, proof, intent, head, landed>>
Accept(t) == LET r == t[1] IN
             /\ t \in receipts /\ r \in active /\ t[2] = gen[r]
             /\ proof' = proof \cup {t}
             /\ active' = active \ {r} /\ slot' = 0
             /\ UNCHANGED <<gen, custody, receipts, intent, head, landed>>
Prepare(r) == /\ intent = 0 /\ <<r, gen[r]>> \in proof
              /\ r \notin landed /\ intent' = r
              /\ UNCHANGED <<gen, active, slot, custody, receipts, proof, head, landed>>
GitCAS == /\ intent \in Runs /\ head = 0 /\ head' = intent
          /\ UNCHANGED <<gen, active, slot, custody, receipts, proof, intent, landed>>
ExternalAdvance == /\ head = 0 /\ head' = 3
                   /\ UNCHANGED <<gen, active, slot, custody, receipts, proof, intent, landed>>
Reconcile == /\ intent \in Runs /\ head # 0
             /\ landed' = IF head = intent THEN landed \cup {intent} ELSE landed
             /\ intent' = 0
             /\ UNCHANGED <<gen, active, slot, custody, receipts, proof, head>>
Next == \/ \E r \in Runs : Claim(r) \/ Deliver(r) \/ Fence(r) \/ Prepare(r)
        \/ \E t \in Tokens : WorkerDone(t) \/ Accept(t)
        \/ GitCAS \/ Reconcile \/ ExternalAdvance
Spec == Init /\ [][Next]_vars
Capacity == /\ Cardinality(custody) <= 1
            /\ \A r \in Runs : (r \in active) = (slot = r)
            /\ \A t \in custody : slot = t[1] /\ gen[t[1]] = t[2]
Fresh == \A t \in proof : t \in receipts /\ gen[t[1]] = t[2]
Exact == /\ (intent # 0 => <<intent, gen[intent]>> \in proof)
         /\ (head \in Runs => <<head, gen[head]>> \in proof)
         /\ \A r \in landed : r = head /\ <<r, gen[r]>> \in proof
=============================================================================
