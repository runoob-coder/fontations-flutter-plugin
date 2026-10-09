// Flutter generates this file when it is missing, but the generated version
// passes `serviceWorkerSettings`, which makes `flutter.js` register
// `flutter_service_worker.js`.
//
// That registration has to stay off: a scope can only be controlled by one
// service worker, so Flutter's worker and `coi_serviceworker.js` - which the
// wasm module needs for cross origin isolation, see that file - would evict
// each other on every load. The app loses nothing here: Flutter's worker only
// caches assets for offline use, and this is a demo.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load();
