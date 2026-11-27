// Makes the page cross origin isolated without help from the server.
//
// Why this exists: the wasm module is built with shared memory, and
// `flutter_rust_bridge` runs Rust on a pool of Web Workers. Spawning those
// workers needs `SharedArrayBuffer`, which browsers only hand out to a
// *cross origin isolated* page, i.e. one served with
//
//   Cross-Origin-Opener-Policy: same-origin
//   Cross-Origin-Embedder-Policy: require-corp
//
// Flutter's dev server (`flutter run -d chrome`) cannot be told to send them,
// and neither can most static hosts (GitHub Pages among them). A service
// worker can: it intercepts the navigation and rewrites the response headers,
// so the page becomes isolated without anyone touching the server.
//
// Registered from `index.html`, which reloads the page once so that this
// worker is in control and can do the rewrite.
//
// `install` and `activate` skip the waiting phase on purpose: the point of the
// reload in `index.html` is to be isolated on the *next* load, not eventually.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('fetch', (event) => {
  // Only the document needs the headers. Everything else - `main.dart.js`,
  // CanvasKit, `pkg/fontations.js`, the wasm module, fonts - is left to the
  // browser: rewriting those would only add a hop per request.
  if (event.request.mode !== 'navigate') {
    return;
  }
  event.respondWith(isolate(event.request));
});

async function isolate(request) {
  const response = await fetch(request);
  if (!response.body) {
    return response;
  }
  const headers = new Headers(response.headers);
  headers.set('Cross-Origin-Opener-Policy', 'same-origin');
  headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: headers,
  });
}
