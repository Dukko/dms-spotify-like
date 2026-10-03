#!/usr/bin/env python3
"""One-shot Spotify Web API request helper for the Spotify Like plugin.

Reads a single-line JSON request on stdin, performs it, and prints a
single-line JSON result on stdout:

    {"op": "refresh",  "client_id": "...", "refresh_token": "..."}
    {"op": "contains", "token": "...", "track_id": "..."}
    {"op": "save",     "token": "...", "track_id": "..."}
    {"op": "remove",   "token": "...", "track_id": "..."}

    -> {"ok": true,  "status": 200, "body": "[true]"}
    -> {"ok": false, "status": 401, "body": "..."}   # Spotify answered, we didn't like it
    -> {"ok": false, "error": "network", "detail": "..."}  # no HTTP status at all

Two deliberate choices here:

* Only the four fixed Spotify operations above are reachable. The caller never
  supplies a URL or an HTTP method, so this helper cannot be turned into a
  general-purpose HTTP client that forwards credentials elsewhere.
* The bearer token arrives on stdin, never in argv. Anything in argv is
  world-readable through /proc/<pid>/cmdline on Linux, which would leak the
  token to every other local user for the lifetime of the request.

Stdlib only, matching spotify_auth.py.
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

TOKEN_URL = "https://accounts.spotify.com/api/token"
LIBRARY_URL = "https://api.spotify.com/v1/me/library"
LIBRARY_CONTAINS_URL = LIBRARY_URL + "/contains"
TIMEOUT_SECONDS = 10


def emit(payload):
    """Print one result line and exit. HTTP-level failures are still `ok: false`
    with a status; only a result we could not obtain at all carries an error."""
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()
    sys.exit(0)


def read_request():
    # Exactly one line, so we never block waiting for stdin to close -- the
    # caller writes one JSON object terminated by a newline and we are done.
    line = sys.stdin.readline()
    if not line:
        sys.exit(2)
    try:
        return json.loads(line)
    except ValueError:
        sys.exit(2)


def send(url, method="GET", token=None, form=None):
    """Perform one request, always returning a result dict (never raising)."""
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode("ascii")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            return {
                "ok": True,
                "status": resp.status,
                "body": resp.read().decode("utf-8", "replace"),
            }
    except urllib.error.HTTPError as e:
        # Spotify answered; hand the status back so the caller can tell 401
        # from 403 from 429 instead of collapsing them into "network".
        return {
            "ok": False,
            "status": e.code,
            "body": e.read().decode("utf-8", "replace"),
        }
    except Exception as e:
        return {"ok": False, "error": "network", "detail": type(e).__name__}


def track_uri(track_id):
    return "spotify:track:" + track_id


def require(payload, key, op):
    value = payload.get(key)
    if not value or not isinstance(value, str):
        emit({"ok": False, "error": "bad_request", "detail": "missing " + key + " for " + op})
    return value


def main():
    payload = read_request()
    op = payload.get("op")

    if op == "refresh":
        emit(send(
            TOKEN_URL,
            method="POST",
            form={
                "grant_type": "refresh_token",
                "refresh_token": require(payload, "refresh_token", op),
                "client_id": require(payload, "client_id", op),
            },
        ))

    if op == "contains":
        track_id = require(payload, "track_id", op)
        emit(send(
            LIBRARY_CONTAINS_URL + "?" + urllib.parse.urlencode({"uris": track_uri(track_id)}),
            token=require(payload, "token", op),
        ))

    if op in ("save", "remove"):
        track_id = require(payload, "track_id", op)
        method = "PUT" if op == "save" else "DELETE"
        # uris rides in the query string, which is what the previous curl calls
        # used and what Spotify documents for these two endpoints.
        emit(send(
            LIBRARY_URL + "?" + urllib.parse.urlencode({"uris": track_uri(track_id)}),
            method=method,
            token=require(payload, "token", op),
        ))

    emit({"ok": False, "error": "bad_request", "detail": "unknown op"})


if __name__ == "__main__":
    main()