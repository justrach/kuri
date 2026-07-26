// kuri console + error collector.
// Injected on every new document (via Page.addScriptToEvaluateOnNewDocument)
// and once into the live page. Populates window.__kuri_console and
// window.__kuri_errors, which the /console and /errors endpoints read + clear.
// Runs before page scripts so it captures console output and errors from load.
(function () {
  if (window.__kuri_collector_installed) return;
  window.__kuri_collector_installed = true;
  window.__kuri_console = window.__kuri_console || [];
  window.__kuri_errors = window.__kuri_errors || [];

  var MAX = 500;
  function trim(a) { if (a.length > MAX) a.splice(0, a.length - MAX); }

  function fmt(args) {
    try {
      return Array.prototype.map.call(args, function (a) {
        if (a instanceof Error) return a.stack || (a.name + ": " + a.message);
        if (a && typeof a === "object") {
          try { return JSON.stringify(a); } catch (e) { return String(a); }
        }
        return String(a);
      }).join(" ");
    } catch (e) { return ""; }
  }

  ["log", "info", "warn", "error", "debug"].forEach(function (level) {
    var orig = (console && console[level]) ? console[level].bind(console) : function () {};
    console[level] = function () {
      try {
        window.__kuri_console.push({ type: level, text: fmt(arguments), ts: Date.now() });
        trim(window.__kuri_console);
      } catch (e) {}
      return orig.apply(console, arguments);
    };
  });

  window.addEventListener("error", function (e) {
    try {
      window.__kuri_errors.push({
        type: "error",
        text: e.message || String((e && e.error) || "error"),
        source: e.filename || "",
        line: e.lineno || 0,
        col: e.colno || 0,
        stack: (e.error && e.error.stack) || "",
        ts: Date.now()
      });
      trim(window.__kuri_errors);
    } catch (_) {}
  }, true);

  window.addEventListener("unhandledrejection", function (e) {
    try {
      var r = e && e.reason;
      window.__kuri_errors.push({
        type: "unhandledrejection",
        text: (r && (r.message || String(r))) || "unhandledrejection",
        stack: (r && r.stack) || "",
        ts: Date.now()
      });
      trim(window.__kuri_errors);
    } catch (_) {}
  });
})();
