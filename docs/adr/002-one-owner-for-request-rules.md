# One owner for admission request rules

**Status** · Accepted · 2026-11-24

The controller and the CLI both validate build and submit requests. The
Bash CLI carried a second copy of the rules as a JSON Schema validator
written in jq, and the two had already drifted: the CLI rejected unknown
keys while the controller ignored them. A request that passed one side
could fail on the other, and a misspelled optional field such as `pull`
for `pulls` or `dep` for `deps` vanished on the controller instead of
failing.

`gantry_core/request` now owns the rules. It decodes a body, rejects
unknown keys, checks every field, and returns an opaque `Build` or
`Submit`. The controller's `api` module calls it,
and `prepare` accepts only those typed values, so no path can reach Git
with an unchecked request. The module is portable and is tested on BEAM
and JavaScript.

Unknown keys are rejected at both levels of a build request, including
inside an ad hoc action, and in a submit request. The controller answers
HTTP 400 with `unknown request field: NAME`. Manifest actions in
`gantry.json` keep their existing decoder and still ignore unknown keys,
because a manifest is versioned with the repository rather than typed by
an agent at request time.

`scripts/gantry-schema.json` states the same rule for the CLI and remains the published description for
`gantry describe`. A test decodes each of its examples with the Gleam
rules, so the document cannot claim a shape the rules reject.
