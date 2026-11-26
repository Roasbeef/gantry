// The browser primitives the dashboard needs and Lustre does not provide:
// an authenticated GET, a repeating timer, and one stored string. Every
// decision about what to do with the results stays in Gleam.

const key = "gantry.dashboard.token";

// How long one request may take. The page sends one request at a time, so a
// request that never answered would stop the page from polling again.
const timeout_ms = 10000;

// Answer the status and body text of a GET carrying a bearer token. A network
// failure or a timeout answers status 0 with the error's message, so the
// caller sees one shape for every outcome.
export function get(url, token, done) {
  fetch(url, {
    headers: { authorization: "Bearer " + token },
    cache: "no-store",
    credentials: "omit",
    signal: AbortSignal.timeout(timeout_ms),
  })
    .then((response) =>
      response.text().then((body) => done(response.status, body)),
    )
    .catch((error) => done(0, String(error && error.message ? error.message : error)));
}

// Call `tick` every `ms` milliseconds for the life of the page.
export function every(ms, tick) {
  setInterval(() => tick(), ms);
}

// The stored token, or the empty string when there is none or storage is
// refused.
export function load_token() {
  try {
    return window.localStorage.getItem(key) ?? "";
  } catch (_) {
    return "";
  }
}

// Store the token, or forget it when `token` is empty. A refusal is ignored:
// the page still works for this visit.
export function save_token(token) {
  try {
    if (token === "") {
      window.localStorage.removeItem(key);
    } else {
      window.localStorage.setItem(key, token);
    }
  } catch (_) {}
}
