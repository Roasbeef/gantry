%% A node-local mutual exclusion lock for the controller's Git mirrors.
%%
%% OTP's global:trans/4 is the primitive: it queues the caller until the lock
%% is free, runs the work, and releases the lock when the work returns or its
%% process dies, so a crashed holder never leaves a stale lock behind.
%% Restricting the lock nodes to this node keeps it a local lock even on a
%% controller that is clustered for Khepri.
-module(gantry_lock_ffi).
-export([with_lock/2]).

with_lock(Key, Work) ->
    global:trans({{gantry_git_mirror, Key}, self()}, Work, [node()], infinity).
