import gantry/fault
import gantry/http_api
import gleam/http/response
import gleam/list

pub fn each_fault_selects_its_http_status_test() {
  let expected = [
    #(fault.Invalid("bad"), 400),
    #(fault.Unauthorized("no credential"), 401),
    #(fault.Forbidden("wrong worker"), 403),
    #(fault.NotFound("unknown run"), 404),
    #(fault.Conflict("attempt is no longer active"), 409),
    #(fault.Unavailable("queue quorum read timed out"), 503),
    #(fault.Internal("invalid durable queue snapshot"), 500),
  ]
  list.each(expected, fn(row) {
    assert fault.status(row.0) == row.1
    assert http_api.fault_reply(row.0).status == row.1
  })
}

pub fn status_ignores_the_wording_of_the_detail_test() {
  // A transient failure that mentions an unknown run is still retryable.
  assert fault.status(fault.Unavailable("unknown run")) == 503
  assert fault.status(fault.Invalid("queue quorum read timed out")) == 400
}

pub fn fault_reply_is_a_json_error_test() {
  let reply = http_api.fault_reply(fault.Forbidden("worker mismatch"))
  assert response.get_header(reply, "content-type") == Ok("application/json")
}
