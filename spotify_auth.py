#!/usr/bin/env python3
"""Spotify OAuth (Authorization Code + PKCE) loopback helper.

Invoked as: spotify_auth.py <client_id> <port>

Opens the user's browser to Spotify's consent screen, listens on
127.0.0.1:<port>/callback for the redirect, exchanges the code for
tokens, and prints the resulting JSON to stdout:

  {"access_token": "...", "refresh_token": "...", "expires_in": 3600}

On failure prints {"error": "..."} and exits non-zero. No third-party
dependencies -- stdlib only.
"""
import sys
import os
import json
import base64
import hashlib
import secrets
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs, urlencode
import urllib.request
import urllib.error

SCOPES = "user-library-read user-library-modify"
TOKEN_URL = "https://accounts.spotify.com/api/token"
AUTHORIZE_URL = "https://accounts.spotify.com/authorize"
CALLBACK_TIMEOUT_SECONDS = 120


def _open_browser_quietly(url):
    """webbrowser.open() (via xdg-open) can write status text like
    "Opening in existing browser session." straight to our inherited
    stdout/stderr fds, which would corrupt the JSON we print at the end.
    Redirect the real fds to /dev/null for the duration of the call so
    nothing an external browser process writes can leak through.
    """
    try:
        devnull_fd = os.open(os.devnull, os.O_WRONLY)
    except OSError:
        try:
            webbrowser.open(url)
        except Exception:
            pass
        return

    saved_stdout_fd = os.dup(1)
    saved_stderr_fd = os.dup(2)
    try:
        os.dup2(devnull_fd, 1)
        os.dup2(devnull_fd, 2)
        try:
            webbrowser.open(url)
        except Exception:
            pass
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        os.dup2(saved_stdout_fd, 1)
        os.dup2(saved_stderr_fd, 2)
        os.close(saved_stdout_fd)
        os.close(saved_stderr_fd)
        os.close(devnull_fd)


def fail(code, detail=None):
    payload = {"error": code}
    if detail:
        payload["detail"] = detail
    print(json.dumps(payload))
    sys.exit(1)


def main():
    if len(sys.argv) < 3:
        fail("usage", "spotify_auth.py <client_id> <port>")

    client_id = sys.argv[1]
    try:
        port = int(sys.argv[2])
    except ValueError:
        fail("bad_port")
        return

    redirect_uri = f"http://127.0.0.1:{port}/callback"

    verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode("ascii")
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode("ascii")).digest()
    ).rstrip(b"=").decode("ascii")
    state = secrets.token_urlsafe(16)

    auth_url = AUTHORIZE_URL + "?" + urlencode({
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
        "scope": SCOPES,
        "state": state,
    })

    result = {}
    done = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path != "/callback":
                self.send_response(404)
                self.end_headers()
                return

            qs = parse_qs(parsed.query)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(
                b"<html><body style='font-family:sans-serif;background:#111;"
                b"color:#eee;text-align:center;padding:60px'>"
                b"<h2>Spotify connected</h2>"
                b"<p>You can close this tab and return to DankShell.</p>"
                b"</body></html>"
            )

            if qs.get("error"):
                result["error"] = qs["error"][0]
            elif qs.get("state", [""])[0] != state:
                result["error"] = "state_mismatch"
            elif qs.get("code"):
                result["code"] = qs["code"][0]
            else:
                result["error"] = "no_code"
            done.set()

    try:
        server = HTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        fail("port_in_use", str(e))
        return

    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    _open_browser_quietly(auth_url)
    print(f"AUTH_URL={auth_url}", file=sys.stderr)

    ok = done.wait(CALLBACK_TIMEOUT_SECONDS)
    server.shutdown()

    if not ok:
        fail("timeout")
        return
    if "error" in result:
        fail(result["error"])
        return

    token_body = urlencode({
        "grant_type": "authorization_code",
        "code": result["code"],
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": verifier,
    }).encode("ascii")

    req = urllib.request.Request(
        TOKEN_URL,
        data=token_body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        fail("token_exchange_failed", e.read().decode("utf-8", "ignore"))
        return
    except Exception as e:
        fail("token_exchange_failed", str(e))
        return

    # Log the granted scope for debugging -- Spotify can silently hand back
    # less than what was requested, which is otherwise invisible.
    try:
        granted_scope = json.loads(body).get("scope", "")
        print(f"GRANTED_SCOPE={granted_scope}", file=sys.stderr)
    except Exception:
        pass

    print(body)


if __name__ == "__main__":
    main()
