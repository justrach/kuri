// kuri React fiber introspector.
//
// Injected on every new document (via Page.addScriptToEvaluateOnNewDocument)
// and once into the live page, same dual pattern as stealth.js and
// console_collector.js. Populates window.__kuri_react, a small namespace of
// entry points read by the /react/tree, /react/inspect, /react/renders and
// /react/suspense endpoints.
//
// Deliberately does NOT depend on window.__REACT_DEVTOOLS_GLOBAL_HOOK__ being
// populated by a real extension -- kuri runs in an automated Chrome with no
// DevTools extension installed, so that hook never exists on its own. Fibers
// are found directly via the `__reactFiber$*` / `__reactContainer$*` /
// `__reactInternalInstance$*` own-properties react-dom stamps onto DOM nodes.
// A lightweight hook *stub* is installed only so react-dom's own `inject()`
// call (which happens unconditionally on init, hook-or-no-hook) hands us the
// renderer version and a commit callback for free -- kuri never behaves like
// a real DevTools backend and never claims to.
(function () {
  if (window.__kuri_react) return;

  var K = (window.__kuri_react = {
    _registry: new Map(), // id -> fiber, cleared + repopulated by every /react/tree or /react/suspense call
    _nextId: 1,
    _renderers: {}, // rendererId -> {version, rendererPackageName}, populated by the hook-stub's inject()
    _commitLog: [], // bounded ring, populated by onCommitFiberRoot
  });
  var MAX_COMMITS = 200;

  // ---- version-detection + commit-observation hook stub ----
  // Never overwrite a real extension's hook if one somehow exists.
  if (!window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
    var nextRendererId = 0;
    window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      supportsFiber: true,
      renderers: new Map(),
      inject: function (renderer) {
        nextRendererId++;
        K._renderers[nextRendererId] = {
          version: renderer.version || null,
          rendererPackageName: renderer.rendererPackageName || null,
        };
        this.renderers.set(nextRendererId, renderer);
        return nextRendererId;
      },
      onScheduleFiberRoot: function () {},
      onCommitFiberRoot: function (id) {
        try {
          K._commitLog.push({ ts: Date.now(), rendererId: id });
          if (K._commitLog.length > MAX_COMMITS) K._commitLog.splice(0, K._commitLog.length - MAX_COMMITS);
        } catch (e) {}
      },
      onCommitFiberUnmount: function () {},
      checkDCE: function () {},
    };
  }

  function versionInfo() {
    var ids = Object.keys(K._renderers);
    for (var i = 0; i < ids.length; i++) {
      var r = K._renderers[ids[i]];
      if (r && r.version) return { version: r.version, versionSource: "devtools-hook" };
    }
    if (window.React && window.React.version) return { version: window.React.version, versionSource: "window.React" };
    return { version: null, versionSource: "unknown" };
  }

  // ---- fiber-key discovery: no devtools hook needed ----
  function keyOn(el, prefix) {
    var names = Object.getOwnPropertyNames(el);
    for (var i = 0; i < names.length; i++) if (names[i].indexOf(prefix) === 0) return names[i];
    return null;
  }
  function getFiberForElement(el) {
    var k = keyOn(el, "__reactFiber$") || keyOn(el, "__reactInternalInstance$"); // 17+ / 16
    return k ? el[k] : null;
  }

  // React double-buffers fibers: every fiber has an `alternate`, and each
  // commit swaps which of the pair is "current". The `__reactContainer$`
  // property is stamped on the container element once at mount and keeps
  // pointing at whichever HostRoot fiber existed then — so after the very
  // first commit it is typically the OFF-SCREEN one, whose `.child` is null.
  // Walking it yields a root with zero children on every real app (verified
  // against React 19.2.5 / TodoMVC: hasChild=false, alternate.child=truthy).
  // Always prefer whichever side of the pair actually has a rendered tree.
  function currentSide(fiber) {
    if (!fiber) return fiber;
    if (fiber.child) return fiber;
    if (fiber.alternate && fiber.alternate.child) return fiber.alternate;
    return fiber;
  }

  var MAX_SCAN = 20000; // safety valve on pathological DOMs
  function findRoots() {
    var roots = [];
    var all = document.getElementsByTagName("*");
    var n = Math.min(all.length, MAX_SCAN);
    for (var i = 0; i < n; i++) {
      var ck = keyOn(all[i], "__reactContainer$"); // value is the HostRoot fiber directly
      if (ck) roots.push(currentSide(all[i][ck]));
    }
    if (roots.length === 0) {
      for (var j = 0; j < n; j++) {
        var f = getFiberForElement(all[j]);
        if (f) {
          while (f.return) f = f.return;
          roots.push(currentSide(f));
          break;
        }
      }
    }
    return roots;
  }

  // ---- classification: prefer Symbol.for('react.*') over fiber.tag numbers ----
  function sf(name) {
    try {
      return Symbol.for(name);
    } catch (e) {
      return null;
    }
  }
  var SYM = {
    suspense: sf("react.suspense"),
    suspense_list: sf("react.suspense_list"),
    fragment: sf("react.fragment"),
    strict_mode: sf("react.strict_mode"),
    profiler: sf("react.profiler"),
    provider: sf("react.provider"),
    context: sf("react.context"),
    forward_ref: sf("react.forward_ref"),
    memo: sf("react.memo"),
    offscreen: sf("react.offscreen"),
    activity: sf("react.activity"),
    element: sf("react.element"),
  };
  function displayName(t) {
    return t ? t.displayName || t.name || null : null;
  }

  function classifyFiber(fiber) {
    var type = fiber.type;
    if (type && type.$$typeof) {
      if (type.$$typeof === SYM.forward_ref) return { kind: "ForwardRef", name: displayName(type.render) || "(ForwardRef)" };
      if (type.$$typeof === SYM.memo) return { kind: "Memo", name: displayName(type.type) || "(Memo)" };
      if (type.$$typeof === SYM.provider) return { kind: "Context.Provider", name: displayName(type._context) || "Provider" };
      if (type.$$typeof === SYM.context) return { kind: "Context.Consumer", name: "Consumer" };
    }
    if (type === SYM.suspense) return { kind: "Suspense", name: "Suspense" };
    if (type === SYM.suspense_list) return { kind: "SuspenseList", name: "SuspenseList" };
    if (type === SYM.fragment) return { kind: "Fragment", name: "Fragment" };
    if (type === SYM.strict_mode) return { kind: "StrictMode", name: "StrictMode" };
    if (type === SYM.profiler) return { kind: "Profiler", name: (fiber.pendingProps && fiber.pendingProps.id) || "Profiler" };
    if (type === SYM.offscreen || type === SYM.activity) return { kind: "Offscreen", name: "Offscreen" };
    if (type === null) {
      var isText = fiber.tag === 6; // no Symbol exists for host text; tag is the only signal
      return isText ? { kind: "HostText", name: null } : { kind: "Root", name: "#root" };
    }
    if (typeof type === "string") return { kind: "HostComponent", name: type }; // 'div', 'span', ...
    if (typeof type === "function") {
      var isClass = !!(type.prototype && type.prototype.isReactComponent);
      return { kind: isClass ? "ClassComponent" : "FunctionComponent", name: displayName(type) || "(anonymous)" };
    }
    return { kind: "tag" + fiber.tag, name: "(unrecognized)" };
  }

  // ---- safe serializer: depth cap + array/key caps + total-value budget + cycle guard ----
  function safeSerialize(value, depth, seenStack, maxDepth, budget) {
    if (budget.n++ > budget.cap) return { __kuri: "truncated", reason: "max-values" };
    if (depth > maxDepth) return { __kuri: "truncated", reason: "max-depth" };
    if (value === undefined) return { __kuri: "undefined" };
    if (value === null) return null;
    var t = typeof value;
    if (t === "string") return value.length > 2000 ? value.slice(0, 2000) + "…" : value;
    if (t === "number" || t === "boolean") return value;
    if (t === "function") return { __kuri: "function", name: value.name || "(anonymous)" };
    if (t === "symbol") return { __kuri: "symbol", description: String(value) };
    if (t === "bigint") return { __kuri: "bigint", value: value.toString() };
    if (t !== "object") return String(value);

    if (seenStack.indexOf(value) !== -1) return { __kuri: "circular" };
    if (typeof Node !== "undefined" && value instanceof Node)
      return { __kuri: "domnode", tag: (value.nodeName || "?").toLowerCase(), id: value.id || undefined };
    if (value.$$typeof === SYM.element) return { __kuri: "reactelement", type: displayName(value.type) || String(value.type) };
    if (value instanceof Error) return { __kuri: "error", name: value.name, message: value.message };

    seenStack.push(value);
    try {
      if (Array.isArray(value)) {
        var lim = Math.min(value.length, 50);
        var arr = [];
        for (var i = 0; i < lim; i++) arr.push(safeSerialize(value[i], depth + 1, seenStack, maxDepth, budget));
        if (value.length > lim) arr.push({ __kuri: "truncated", reason: "max-array-len", remaining: value.length - lim });
        return arr;
      }
      if (value instanceof Map || value instanceof Set) {
        var items = [];
        var k2 = 0;
        var isMap = value instanceof Map;
        value.forEach(function (v, k) {
          if (k2++ >= 50) return;
          items.push(isMap ? [safeSerialize(k, depth + 1, seenStack, maxDepth, budget), safeSerialize(v, depth + 1, seenStack, maxDepth, budget)] : safeSerialize(v, depth + 1, seenStack, maxDepth, budget));
        });
        return { __kuri: isMap ? "map" : "set", size: value.size, entries: items };
      }
      var keys;
      try {
        keys = Object.keys(value);
      } catch (e) {
        return { __kuri: "unserializable", error: String(e && e.message) };
      }
      var res = {};
      var kn = Math.min(keys.length, 50);
      for (var ki = 0; ki < kn; ki++) {
        try {
          res[keys[ki]] = safeSerialize(value[keys[ki]], depth + 1, seenStack, maxDepth, budget);
        } catch (e2) {
          res[keys[ki]] = { __kuri: "unserializable", error: String(e2 && e2.message) };
        }
      }
      if (keys.length > kn) res.__kuriTruncatedKeys = keys.length - kn;
      return res;
    } finally {
      seenStack.pop(); // pop, don't keep -- allows the same object at sibling branches (a diamond, not a cycle)
    }
  }

  // ---- /react/tree ----
  K.tree = function (opts) {
    opts = opts || {};
    var maxNodes = Math.min(opts.maxNodes || 500, 3000);
    var maxDepth = Math.min(opts.maxDepth || 40, 150); // recursion depth == maxDepth, safe for JS's call stack
    var includeHostText = !!opts.includeHostText;
    var roots = findRoots();
    if (roots.length === 0) return { react: false };

    K._registry.clear();
    K._nextId = 1;
    var vi = versionInfo();
    var out = { react: true, version: vi.version, versionSource: vi.versionSource, roots: [], truncated: false, nodeCount: 0 };
    for (var r = 0; r < roots.length; r++) out.roots.push(build(roots[r], 0));
    return out;

    function build(fiber, depth) {
      out.nodeCount++;
      var info = classifyFiber(fiber);
      var id = "k" + K._nextId++;
      K._registry.set(id, fiber);
      var node = {
        id: id,
        name: info.name,
        kind: info.kind,
        key: fiber.key != null ? String(fiber.key) : null,
        depth: depth,
        children: [],
      };
      if (depth >= maxDepth) {
        node.truncated = true;
        out.truncated = true;
        delete node.children;
        return node;
      }
      var child = fiber.child;
      while (child) {
        if (!includeHostText && child.tag === 6) {
          child = child.sibling;
          continue;
        }
        if (out.nodeCount >= maxNodes) {
          node.moreChildren = true;
          out.truncated = true;
          break;
        }
        node.children.push(build(child, depth + 1));
        child = child.sibling;
      }
      return node;
    }
  };

  // ---- /react/inspect ----
  function inspectFiber(fiber) {
    if (!fiber) return { ok: false, react: true, error: "no fiber" };
    var info = classifyFiber(fiber);
    var maxDepth = 6;
    var budget = { n: 0, cap: 2000 };
    var isClass = !!(fiber.type && fiber.type.prototype && fiber.type.prototype.isReactComponent);
    var props = safeSerialize(fiber.memoizedProps, 0, [], maxDepth, budget);
    var state = isClass ? safeSerialize(fiber.memoizedState, 0, [], maxDepth, budget) : null;
    var hooks = !isClass && typeof fiber.type === "function" ? walkHooks(fiber.memoizedState, maxDepth, budget) : null;
    return {
      ok: true,
      react: true,
      name: info.name,
      kind: info.kind,
      key: fiber.key != null ? String(fiber.key) : null,
      props: props,
      state: state,
      hooks: hooks,
      source: fiber._debugSource ? { fileName: fiber._debugSource.fileName, lineNumber: fiber._debugSource.lineNumber } : null,
    };
  }
  function walkHooks(memoizedState, maxDepth, budget) {
    var out = [];
    var h = memoizedState;
    var i = 0;
    while (h && i < 200) {
      out.push({ index: i, value: safeSerialize(h.memoizedState, 0, [], maxDepth, budget) });
      h = h.next;
      i++;
    }
    if (h) out.push({ __kuri: "truncated", reason: "max-hooks" });
    return out;
  }
  K.inspect = function (opts) {
    opts = opts || {};
    if (findRoots().length === 0) return { react: false };
    var fiber = null;
    if (opts.id) fiber = K._registry.get(opts.id) || null;
    else if (opts.selector) {
      var el = document.querySelector(opts.selector);
      fiber = el ? getFiberForElement(el) : null;
    }
    if (!fiber)
      return {
        ok: false,
        react: true,
        error: opts.id ? "unknown id (ids reset on every /react/tree or /react/suspense call)" : "selector matched no element with a React fiber",
      };
    return inspectFiber(fiber);
  };
  K.inspectElement = function (el) {
    // entry point for the ref path (`this` bound via Runtime.callFunctionOn)
    if (findRoots().length === 0) return { react: false };
    var fiber = getFiberForElement(el);
    return fiber ? inspectFiber(fiber) : { ok: false, react: true, error: "element has no React fiber" };
  };

  // ---- /react/renders ----
  // Not the Profiler API (that needs the profiling bundle + explicit
  // start/stopProfiling and is a much heavier commitment than this endpoint
  // warrants). Instead: a real, small, bounded commit log fed by the hook
  // stub's onCommitFiberRoot, which fires on every commit -- but only for
  // commits that happen *after* kuri's persistent script installed the stub,
  // and only if it was installed before react-dom's own init ran (i.e. this
  // is the persistent Page.addScriptToEvaluateOnNewDocument copy, not the
  // one-shot patch of an already-running page). hookAttachedBeforeInit tells
  // the caller whether that happened for this page load.
  K.renders = function () {
    if (findRoots().length === 0) return { react: false };
    var vi = versionInfo();
    var attached = Object.keys(K._renderers).length > 0;
    return {
      ok: true,
      react: true,
      version: vi.version,
      versionSource: vi.versionSource,
      hookAttachedBeforeInit: attached,
      commits: K._commitLog.slice(),
      note: attached
        ? "commit timestamps observed since kuri attached"
        : "no commits observed -- this page loaded before kuri's persistent hook was installed, or nothing has re-rendered yet; reload the page to get commit tracking",
    };
  };

  // ---- /react/suspense ----
  K.suspense = function (opts) {
    opts = opts || {};
    var maxNodes = Math.min(opts.maxNodes || 500, 3000);
    var maxDepth = Math.min(opts.maxDepth || 150, 300);
    var roots = findRoots();
    if (roots.length === 0) return { react: false };
    K._registry.clear();
    K._nextId = 1;
    var out = { react: true, ok: true, boundaries: [], truncated: false };
    var count = 0;

    function walk(fiber, path, depth) {
      if (count >= maxNodes) {
        out.truncated = true;
        return;
      }
      if (depth > maxDepth) {
        out.truncated = true;
        return;
      }
      count++;
      var info = classifyFiber(fiber);
      var nextPath = path;
      if (info.kind === "Suspense") {
        var id = "k" + K._nextId++;
        K._registry.set(id, fiber);
        out.boundaries.push({ id: id, path: path.slice(), showingFallback: fiber.memoizedState !== null });
        nextPath = path.concat([info.name || "Suspense"]);
      } else if (info.name) {
        nextPath = path.concat([info.name]);
      }
      var child = fiber.child;
      while (child && count < maxNodes) {
        walk(child, nextPath, depth + 1);
        child = child.sibling;
      }
    }
    for (var r = 0; r < roots.length && count < maxNodes; r++) walk(roots[r], [], 0);
    return out;
  };
})();
