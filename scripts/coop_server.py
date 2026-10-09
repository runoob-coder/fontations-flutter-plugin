#!/usr/bin/env python3
"""Serves a directory with the headers a threaded wasm module needs.

    python3 scripts/coop_server.py [directory] [port]

`SharedArrayBuffer`, which the WebAssembly build of the crate uses for its
worker pool, only exists on a cross origin isolated page. `python3 -m
http.server` does not send the two headers that make a page isolated, so the
module panics at start up when the app is served that way - the same is true
for `flutter run -d chrome`, whose dev server cannot be told to add them either.

Point this at a build made with `flutter build web --no-web-resources-cdn`
(so CanvasKit is served locally instead of from a CDN):

    flutter build web --no-web-resources-cdn
    python3 scripts/coop_server.py example/build/web 8080
    open http://localhost:8080/
"""

import functools
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    """Adds the cross origin isolation headers to every response."""

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        super().end_headers()

    def log_message(self, *args):
        # Quiet: the point of the script is to serve, not to chat.
        pass


def main() -> None:
    directory = sys.argv[1] if len(sys.argv) > 1 else "example/build/web"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
    if not os.path.isdir(directory):
        raise SystemExit(f"{directory} does not exist - build the app first")

    handler = functools.partial(Handler, directory=directory)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    print(f"serving {directory} on http://localhost:{port}/")
    print("cross origin isolation: enabled")
    server.serve_forever()


if __name__ == "__main__":
    main()
