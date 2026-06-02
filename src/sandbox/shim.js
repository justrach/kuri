// shim.js — Web API shim for QuickJS sandbox
//
// Loaded once into a fresh Context before any captured bundle runs.
// Provides the surface a typical anti-bot / HMAC / signed-URL bundle expects:
//   navigator, document, window, screen, location, performance, localStorage,
//   crypto, fetch/XMLHttpRequest, atob/btoa, setTimeout/setInterval.
//
// Native bridges (provided by runtime.zig as globals before this loads):
//   __nativeFetch(method, url, headers, body) -> {status, headers, body}   (sync)
//   __nativeRandomBytes(n) -> Uint8Array
//   __nativeSubtleDigest(alg, data) -> Uint8Array                          (sync)
//   __nativeNowMs() -> number                                              (high-res ms)
//   __fingerprint -> {ua, platform, language, languages[], screen{...},
//                     hardwareConcurrency, deviceMemory, vendor, timezone,
//                     canvasHash, webglVendor, webglRenderer, audioCtxHash,
//                     fonts[], plugins[]}
//   __cookieJarGet(host) -> string  (semicolon-separated cookies)
//   __cookieJarSet(host, setCookieHeader) -> void
//
// Everything else is plain ES2020 — QuickJS-NG handles URL, URLSearchParams,
// TextEncoder/Decoder, Promise, async/await, BigInt natively.

'use strict';

(function installShim(global) {
  const fp = global.__fingerprint || {};

  // ── globalThis / window / self ────────────────────────────────────────────
  global.window = global;
  global.self = global;
  global.parent = global;
  global.top = global;
  global.frames = global;
  global.origin = (fp.origin || 'https://example.com');
  global.isSecureContext = true;

  // ── navigator ─────────────────────────────────────────────────────────────
  const navigator = Object.create(null);
  Object.defineProperties(navigator, {
    userAgent:           { get: () => fp.ua || 'Mozilla/5.0', configurable: true },
    appVersion:          { get: () => (fp.ua || '').replace(/^Mozilla\//, ''), configurable: true },
    platform:            { get: () => fp.platform || 'MacIntel', configurable: true },
    vendor:              { get: () => fp.vendor || 'Google Inc.', configurable: true },
    language:            { get: () => fp.language || 'en-US', configurable: true },
    languages:           { get: () => fp.languages || ['en-US', 'en'], configurable: true },
    hardwareConcurrency: { get: () => fp.hardwareConcurrency || 8, configurable: true },
    deviceMemory:        { get: () => fp.deviceMemory || 8, configurable: true },
    maxTouchPoints:      { get: () => fp.maxTouchPoints || 0, configurable: true },
    cookieEnabled:       { get: () => true, configurable: true },
    onLine:              { get: () => true, configurable: true },
    webdriver:           { get: () => false, configurable: true },
    doNotTrack:          { get: () => null, configurable: true },
    plugins:             { get: () => fp.plugins || [], configurable: true },
    mimeTypes:           { get: () => [], configurable: true },
    productSub:          { get: () => '20030107', configurable: true },
    product:             { get: () => 'Gecko', configurable: true },
    appName:             { get: () => 'Netscape', configurable: true },
    appCodeName:         { get: () => 'Mozilla', configurable: true },
  });
  navigator.javaEnabled = () => false;
  navigator.permissions = {
    query: (p) => Promise.resolve({ state: p && p.name === 'notifications' ? 'default' : 'granted', onchange: null }),
  };
  navigator.userAgentData = {
    brands: [
      { brand: 'Chromium',       version: '135' },
      { brand: 'Not-A.Brand',    version: '8'   },
      { brand: 'Google Chrome',  version: '135' },
    ],
    mobile: false,
    platform: fp.platform || 'macOS',
    getHighEntropyValues: (hints) => Promise.resolve({
      architecture: 'arm', bitness: '64', model: '', mobile: false,
      platform: fp.platform || 'macOS', platformVersion: '14.5.0',
      uaFullVersion: '135.0.0.0', wow64: false,
    }),
    toJSON: function () { return { brands: this.brands, mobile: this.mobile, platform: this.platform }; },
  };
  navigator.connection = { effectiveType: '4g', rtt: 50, downlink: 10, saveData: false, type: 'wifi' };
  navigator.serviceWorker = { register: () => Promise.reject(new Error('sw unsupported')), controller: null };
  global.navigator = navigator;

  // ── screen ────────────────────────────────────────────────────────────────
  const screen = fp.screen || { width: 1920, height: 1080, availWidth: 1920, availHeight: 1055, colorDepth: 24, pixelDepth: 24 };
  global.screen = screen;
  global.devicePixelRatio = fp.devicePixelRatio || 2;
  global.outerWidth = screen.width;
  global.outerHeight = screen.height;
  global.innerWidth = screen.availWidth;
  global.innerHeight = screen.availHeight;
  global.scrollX = 0; global.scrollY = 0; global.pageXOffset = 0; global.pageYOffset = 0;

  // ── URL polyfill (QuickJS doesn't ship URL natively) ─────────────────────
  // Minimal regex-based parser. Sufficient for location.* accessors.
  function URLPolyfill(input, base) {
    let s = String(input || '');
    if (base && !/^[a-z][a-z0-9+\-.]*:\/\//i.test(s)) {
      s = String(base).replace(/\/$/, '') + (s.startsWith('/') ? s : ('/' + s));
    }
    const m = /^([a-z][a-z0-9+\-.]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(s) ||
              ['', 'https', 'example.com', '/', '', ''];
    const [, proto, authority, pathname, search, hash] = m;
    let userinfo = '', host = authority || '', port = '';
    const at = host.indexOf('@'); if (at >= 0) { userinfo = host.slice(0, at); host = host.slice(at + 1); }
    const colon = host.lastIndexOf(':');
    if (colon >= 0 && /^\d+$/.test(host.slice(colon + 1))) { port = host.slice(colon + 1); host = host.slice(0, colon); }
    this.protocol = proto + ':';
    this.username = userinfo.split(':')[0] || '';
    this.password = userinfo.split(':')[1] || '';
    this.hostname = host;
    this.port = port;
    this.host = port ? (host + ':' + port) : host;
    this.pathname = pathname || '/';
    this.search = search || '';
    this.hash = hash || '';
    this.origin = this.protocol + '//' + this.host;
    this.href = this.origin + this.pathname + this.search + this.hash;
    this.searchParams = { get: (k) => {
      const q = (this.search || '').replace(/^\?/, '');
      for (const p of q.split('&')) { const [pk, pv] = p.split('='); if (decodeURIComponent(pk) === k) return decodeURIComponent(pv || ''); }
      return null;
    }};
    this.toString = () => this.href;
  }
  if (typeof global.URL !== 'function') global.URL = URLPolyfill;

  const targetOrigin = fp.targetOrigin || 'https://example.com';
  let _href = (fp.targetHref || targetOrigin + '/');
  const _parseUrl = (u) => {
    try { return new global.URL(u); } catch (_) { return new global.URL(targetOrigin); }
  };
  let _parsed = _parseUrl(_href);

  // ── TextEncoder / TextDecoder (UTF-8 only — sufficient for HMAC inputs) ──
  if (typeof global.TextEncoder !== 'function') {
    global.TextEncoder = function () {};
    global.TextEncoder.prototype.encode = function (str) {
      str = String(str || '');
      const out = [];
      for (let i = 0; i < str.length; i++) {
        let c = str.charCodeAt(i);
        if (c < 0x80) out.push(c);
        else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
        else if (c < 0xd800 || c >= 0xe000) { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
        else {
          // Surrogate pair
          i++;
          const c2 = str.charCodeAt(i);
          c = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
          out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
        }
      }
      return new Uint8Array(out);
    };
  }
  if (typeof global.TextDecoder !== 'function') {
    global.TextDecoder = function () {};
    global.TextDecoder.prototype.decode = function (buf) {
      const view = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
      let s = '', i = 0;
      while (i < view.length) {
        let c = view[i++];
        if (c < 0x80) s += String.fromCharCode(c);
        else if ((c & 0xe0) === 0xc0) s += String.fromCharCode(((c & 0x1f) << 6) | (view[i++] & 0x3f));
        else if ((c & 0xf0) === 0xe0) s += String.fromCharCode(((c & 0x0f) << 12) | ((view[i++] & 0x3f) << 6) | (view[i++] & 0x3f));
        else {
          const cp = ((c & 0x07) << 18) | ((view[i++] & 0x3f) << 12) | ((view[i++] & 0x3f) << 6) | (view[i++] & 0x3f);
          const off = cp - 0x10000;
          s += String.fromCharCode(0xd800 + (off >> 10), 0xdc00 + (off & 0x3ff));
        }
      }
      return s;
    };
  }
  global.location = {
    get href()     { return _parsed.href; },
    get origin()   { return _parsed.origin; },
    get protocol() { return _parsed.protocol; },
    get host()     { return _parsed.host; },
    get hostname() { return _parsed.hostname; },
    get port()     { return _parsed.port; },
    get pathname() { return _parsed.pathname; },
    get search()   { return _parsed.search; },
    get hash()     { return _parsed.hash; },
    set href(v)    { _href = v; _parsed = _parseUrl(v); },
    assign:  (v) => { _href = v; _parsed = _parseUrl(v); },
    replace: (v) => { _href = v; _parsed = _parseUrl(v); },
    reload:  () => {},
    toString() { return this.href; },
    ancestorOrigins: { length: 0, item: () => null, contains: () => false },
  };

  // ── document ──────────────────────────────────────────────────────────────
  // Minimal — most bundles only touch a few fields. If a bundle calls
  // querySelectorAll and iterates, it gets an empty list, which is fine for
  // headless replay (bundle isn't actually rendering).
  const _docCookies = [];
  const _docElement = (tag) => ({
    tagName: (tag || 'DIV').toUpperCase(),
    children: [], childNodes: [], attributes: {},
    style: {},
    classList: { add: () => {}, remove: () => {}, toggle: () => {}, contains: () => false },
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => true,
    appendChild: function (c) { this.children.push(c); this.childNodes.push(c); return c; },
    removeChild: function (c) { return c; },
    setAttribute: function (k, v) { this.attributes[k] = v; },
    getAttribute: function (k)    { return this.attributes[k] || null; },
    hasAttribute: function (k)    { return k in this.attributes; },
    cloneNode: function () { return _docElement(tag); },
    getBoundingClientRect: () => ({ x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 }),
    contains: () => false,
    closest: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    innerHTML: '', outerHTML: '', textContent: '', innerText: '',
    scrollIntoView: () => {},
    focus: () => {}, blur: () => {}, click: () => {},
  });

  const documentElement = _docElement('html');
  const headEl = _docElement('head');
  const bodyEl = _docElement('body');
  documentElement.children.push(headEl, bodyEl);

  global.document = {
    nodeType: 9,
    documentElement,
    head: headEl,
    body: bodyEl,
    title: '',
    URL: _parsed.href,
    documentURI: _parsed.href,
    referrer: fp.referrer || '',
    domain: _parsed.hostname,
    readyState: 'complete',
    visibilityState: 'visible',
    hidden: false,
    characterSet: 'UTF-8',
    contentType: 'text/html',
    compatMode: 'CSS1Compat',
    createElement: (tag) => _docElement(tag),
    createElementNS: (_ns, tag) => _docElement(tag),
    createTextNode: (text) => ({ nodeType: 3, textContent: text || '', data: text || '' }),
    createDocumentFragment: () => _docElement('fragment'),
    createEvent: () => ({ initEvent: () => {} }),
    getElementById: () => null,
    getElementsByTagName: () => [],
    getElementsByClassName: () => [],
    getElementsByName: () => [],
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => true,
    open: () => {}, close: () => {}, write: () => {}, writeln: () => {},
    execCommand: () => false,
    hasFocus: () => true,
    elementFromPoint: () => null,
    get cookie() { return _docCookies.join('; '); },
    set cookie(v) {
      if (typeof v !== 'string') return;
      // Mirror to native cookie jar if available
      if (typeof __cookieJarSet === 'function') {
        try { __cookieJarSet(_parsed.host, v); } catch (_) {}
      }
      const eqIdx = v.indexOf('=');
      if (eqIdx > 0) {
        const name = v.slice(0, eqIdx).trim();
        const semi = v.indexOf(';');
        const pair = semi === -1 ? v : v.slice(0, semi);
        const idx = _docCookies.findIndex((c) => c.startsWith(name + '='));
        if (idx >= 0) _docCookies[idx] = pair; else _docCookies.push(pair);
      }
    },
  };

  // ── performance ───────────────────────────────────────────────────────────
  const _perfStart = (typeof __nativeNowMs === 'function') ? __nativeNowMs() : Date.now();
  global.performance = {
    timeOrigin: _perfStart,
    now: () => (typeof __nativeNowMs === 'function' ? __nativeNowMs() : Date.now()) - _perfStart,
    timing: {},
    navigation: { type: 0, redirectCount: 0 },
    getEntries: () => [], getEntriesByName: () => [], getEntriesByType: () => [],
    mark: () => {}, measure: () => {}, clearMarks: () => {}, clearMeasures: () => {},
    setResourceTimingBufferSize: () => {}, clearResourceTimings: () => {},
    toJSON: () => ({}),
  };

  // ── crypto ────────────────────────────────────────────────────────────────
  const _hexAlg = (a) => {
    if (typeof a === 'string') return a.toUpperCase().replace('-', '');
    if (a && a.name) return a.name.toUpperCase().replace('-', '');
    return 'SHA256';
  };
  global.crypto = {
    getRandomValues: (typedArray) => {
      if (typeof __nativeRandomBytes === 'function') {
        const buf = __nativeRandomBytes(typedArray.byteLength);
        const view = new Uint8Array(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
        for (let i = 0; i < view.length; i++) view[i] = buf[i];
      } else {
        for (let i = 0; i < typedArray.length; i++) typedArray[i] = (Math.random() * 256) | 0;
      }
      return typedArray;
    },
    randomUUID: () => {
      const b = new Uint8Array(16);
      global.crypto.getRandomValues(b);
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
      return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
    },
    subtle: {
      digest: (alg, data) => {
        if (typeof __nativeSubtleDigest !== 'function') {
          return Promise.reject(new Error('crypto.subtle.digest unavailable in shim'));
        }
        const view = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer || data);
        const out = __nativeSubtleDigest(_hexAlg(alg), view);
        return Promise.resolve(out.buffer);
      },
      // TODO Phase 1.5: importKey, sign, verify, encrypt, decrypt — stub for now
      importKey:   () => Promise.reject(new Error('crypto.subtle.importKey not yet shimmed')),
      sign:        () => Promise.reject(new Error('crypto.subtle.sign not yet shimmed')),
      verify:      () => Promise.reject(new Error('crypto.subtle.verify not yet shimmed')),
      encrypt:     () => Promise.reject(new Error('crypto.subtle.encrypt not yet shimmed')),
      decrypt:     () => Promise.reject(new Error('crypto.subtle.decrypt not yet shimmed')),
      generateKey: () => Promise.reject(new Error('crypto.subtle.generateKey not yet shimmed')),
      deriveKey:   () => Promise.reject(new Error('crypto.subtle.deriveKey not yet shimmed')),
      deriveBits:  () => Promise.reject(new Error('crypto.subtle.deriveBits not yet shimmed')),
      exportKey:   () => Promise.reject(new Error('crypto.subtle.exportKey not yet shimmed')),
      wrapKey:     () => Promise.reject(new Error('crypto.subtle.wrapKey not yet shimmed')),
      unwrapKey:   () => Promise.reject(new Error('crypto.subtle.unwrapKey not yet shimmed')),
    },
  };

  // ── atob / btoa ───────────────────────────────────────────────────────────
  if (typeof global.atob !== 'function') {
    const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    global.btoa = (s) => {
      let str = String(s), out = '';
      for (let i = 0; i < str.length; ) {
        const c1 = str.charCodeAt(i++) & 0xff;
        const c2 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
        const c3 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
        const t1 = c1 >> 2;
        const t2 = ((c1 & 3) << 4) | ((isNaN(c2) ? 0 : c2) >> 4);
        const t3 = isNaN(c2) ? 64 : (((c2 & 15) << 2) | ((isNaN(c3) ? 0 : c3) >> 6));
        const t4 = isNaN(c3) ? 64 : (c3 & 63);
        out += B64[t1] + B64[t2] + (t3 === 64 ? '=' : B64[t3]) + (t4 === 64 ? '=' : B64[t4]);
      }
      return out;
    };
    global.atob = (s) => {
      const str = String(s).replace(/=+$/, '');
      let out = '';
      for (let i = 0; i < str.length; ) {
        const e1 = B64.indexOf(str[i++]);
        const e2 = B64.indexOf(str[i++]);
        const e3 = B64.indexOf(str[i++]);
        const e4 = B64.indexOf(str[i++]);
        const c1 = (e1 << 2) | (e2 >> 4);
        out += String.fromCharCode(c1);
        if (e3 !== -1 && e3 !== 64) out += String.fromCharCode(((e2 & 15) << 4) | (e3 >> 2));
        if (e4 !== -1 && e4 !== 64) out += String.fromCharCode(((e3 & 3)  << 6) |  e4);
      }
      return out;
    };
  }

  // ── timers (synchronous-ish — no real event loop in QuickJS) ──────────────
  const _timers = new Map();
  let _nextTimerId = 1;
  global.setTimeout = (fn, delay) => {
    const id = _nextTimerId++;
    _timers.set(id, fn);
    // Best-effort: fire immediately on next microtask tick. Most bundles
    // that depend on timer ordering fall back gracefully.
    Promise.resolve().then(() => { if (_timers.has(id)) { _timers.delete(id); try { fn(); } catch (_) {} } });
    return id;
  };
  global.clearTimeout = (id) => _timers.delete(id);
  global.setInterval = (fn) => { /* no-op — bundles rarely depend on intervals */ return _nextTimerId++; };
  global.clearInterval = (id) => _timers.delete(id);
  global.requestAnimationFrame = (fn) => global.setTimeout(() => fn(performance.now()), 16);
  global.cancelAnimationFrame  = (id) => global.clearTimeout(id);
  global.queueMicrotask = (fn) => Promise.resolve().then(fn);

  // ── storage (in-memory) ───────────────────────────────────────────────────
  const _makeStorage = () => {
    const map = new Map();
    return {
      get length() { return map.size; },
      getItem: (k) => map.has(String(k)) ? map.get(String(k)) : null,
      setItem: (k, v) => { map.set(String(k), String(v)); },
      removeItem: (k) => { map.delete(String(k)); },
      clear: () => { map.clear(); },
      key: (i) => Array.from(map.keys())[i] || null,
    };
  };
  global.localStorage = _makeStorage();
  global.sessionStorage = _makeStorage();

  // ── fetch ─────────────────────────────────────────────────────────────────
  // Sync bridge → async wrapper. __nativeFetch is synchronous (curl-impersonate
  // call), but Web fetch is Promise-shaped, so we resolve the result.
  global.fetch = (input, init) => {
    return new Promise((resolve, reject) => {
      try {
        const req = (input && typeof input === 'object' && input.url) ? input : { url: String(input) };
        const url = req.url;
        const method = (init && init.method) || req.method || 'GET';
        const headersIn = (init && init.headers) || req.headers || {};
        const headers = {};
        if (headersIn && typeof headersIn.forEach === 'function') {
          headersIn.forEach((v, k) => { headers[k] = v; });
        } else if (Array.isArray(headersIn)) {
          for (const [k, v] of headersIn) headers[k] = v;
        } else {
          Object.assign(headers, headersIn);
        }
        const body = (init && init.body) || req.body || null;
        const result = __nativeFetch(method, url, headers, body);
        const respHeaders = result.headers || {};
        const respBody = result.body || '';
        const response = {
          ok: result.status >= 200 && result.status < 300,
          status: result.status,
          statusText: result.statusText || '',
          url: result.url || url,
          redirected: !!result.redirected,
          type: 'basic',
          headers: {
            get: (k) => {
              const lk = String(k).toLowerCase();
              for (const h in respHeaders) if (h.toLowerCase() === lk) return respHeaders[h];
              return null;
            },
            has: (k) => response.headers.get(k) !== null,
            forEach: (fn) => { for (const h in respHeaders) fn(respHeaders[h], h); },
            entries: () => Object.entries(respHeaders),
            keys:    () => Object.keys(respHeaders),
            values:  () => Object.values(respHeaders),
          },
          text:        () => Promise.resolve(respBody),
          json:        () => { try { return Promise.resolve(JSON.parse(respBody)); } catch (e) { return Promise.reject(e); } },
          arrayBuffer: () => {
            const buf = new ArrayBuffer(respBody.length);
            const view = new Uint8Array(buf);
            for (let i = 0; i < respBody.length; i++) view[i] = respBody.charCodeAt(i) & 0xff;
            return Promise.resolve(buf);
          },
          blob:  () => Promise.resolve({ size: respBody.length, type: '', text: () => Promise.resolve(respBody) }),
          clone: function () { return Object.assign({}, this); },
        };
        resolve(response);
      } catch (e) {
        reject(e);
      }
    });
  };

  // ── XMLHttpRequest ────────────────────────────────────────────────────────
  function XMLHttpRequest() {
    this.readyState = 0;
    this.status = 0;
    this.statusText = '';
    this.responseText = '';
    this.response = '';
    this.responseURL = '';
    this.responseType = '';
    this.timeout = 0;
    this.withCredentials = false;
    this.upload = { addEventListener: () => {}, removeEventListener: () => {} };
    this._method = 'GET';
    this._url = '';
    this._headers = {};
    this._listeners = {};
  }
  XMLHttpRequest.prototype.open = function (m, u) { this._method = m; this._url = u; this.readyState = 1; this._fire('readystatechange'); };
  XMLHttpRequest.prototype.setRequestHeader = function (k, v) { this._headers[k] = v; };
  XMLHttpRequest.prototype.getResponseHeader = function (k) {
    const lk = String(k).toLowerCase();
    for (const h in (this._respHeaders || {})) if (h.toLowerCase() === lk) return this._respHeaders[h];
    return null;
  };
  XMLHttpRequest.prototype.getAllResponseHeaders = function () {
    return Object.entries(this._respHeaders || {}).map(([k, v]) => `${k}: ${v}`).join('\r\n');
  };
  XMLHttpRequest.prototype.addEventListener = function (ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); };
  XMLHttpRequest.prototype.removeEventListener = function (ev, fn) {
    const arr = this._listeners[ev]; if (!arr) return;
    const i = arr.indexOf(fn); if (i >= 0) arr.splice(i, 1);
  };
  XMLHttpRequest.prototype._fire = function (ev) {
    const arr = this._listeners[ev]; if (arr) for (const fn of arr) try { fn.call(this, { type: ev, target: this }); } catch (_) {}
    const handler = this['on' + ev]; if (typeof handler === 'function') try { handler.call(this, { type: ev, target: this }); } catch (_) {}
  };
  XMLHttpRequest.prototype.send = function (body) {
    try {
      const result = __nativeFetch(this._method, this._url, this._headers, body || null);
      this._respHeaders = result.headers || {};
      this.status = result.status;
      this.statusText = result.statusText || '';
      this.responseURL = result.url || this._url;
      this.responseText = result.body || '';
      this.response = this.responseText;
      this.readyState = 4;
      this._fire('readystatechange');
      this._fire('load');
      this._fire('loadend');
    } catch (e) {
      this.status = 0;
      this._fire('error');
      this._fire('loadend');
    }
  };
  XMLHttpRequest.prototype.abort = function () { this._fire('abort'); this._fire('loadend'); };
  XMLHttpRequest.UNSENT = 0; XMLHttpRequest.OPENED = 1; XMLHttpRequest.HEADERS_RECEIVED = 2;
  XMLHttpRequest.LOADING = 3; XMLHttpRequest.DONE = 4;
  global.XMLHttpRequest = XMLHttpRequest;

  // ── Worker / MessageChannel / BroadcastChannel — stubs ───────────────────
  global.Worker = function () { throw new Error('Worker unsupported in sandbox'); };
  global.SharedWorker = function () { throw new Error('SharedWorker unsupported in sandbox'); };
  global.MessageChannel = function () {
    this.port1 = { postMessage: () => {}, start: () => {}, close: () => {}, addEventListener: () => {}, onmessage: null };
    this.port2 = { postMessage: () => {}, start: () => {}, close: () => {}, addEventListener: () => {}, onmessage: null };
  };
  global.BroadcastChannel = function (name) {
    this.name = name; this.postMessage = () => {}; this.close = () => {};
    this.addEventListener = () => {}; this.removeEventListener = () => {}; this.onmessage = null;
  };
  global.postMessage = () => {};
  global.addEventListener    = (ev, fn) => {};
  global.removeEventListener = (ev, fn) => {};
  global.dispatchEvent = () => true;

  // ── Canvas / WebGL fingerprint stubs ─────────────────────────────────────
  // The bundle calls canvas.toDataURL() or gl.getParameter(VENDOR) to fingerprint.
  // We return a stable hash from the fingerprint pool so coherence checks pass.
  const _origCreateElement = global.document.createElement;
  global.document.createElement = function (tag) {
    const el = _origCreateElement.call(this, tag);
    const t = String(tag || '').toLowerCase();
    if (t === 'canvas') {
      el.width = 300; el.height = 150;
      el.toDataURL = () => fp.canvasHash || 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII=';
      el.getContext = (kind) => {
        if (kind === '2d') {
          return {
            fillRect: () => {}, clearRect: () => {}, fillText: () => {}, strokeText: () => {},
            getImageData: () => ({ data: new Uint8ClampedArray(4) }),
            putImageData: () => {}, drawImage: () => {}, beginPath: () => {}, closePath: () => {},
            moveTo: () => {}, lineTo: () => {}, stroke: () => {}, fill: () => {}, arc: () => {},
            measureText: (t) => ({ width: t.length * 8 }),
            save: () => {}, restore: () => {}, translate: () => {}, scale: () => {}, rotate: () => {},
            font: '10px sans-serif', fillStyle: '#000', strokeStyle: '#000',
          };
        }
        if (kind === 'webgl' || kind === 'webgl2' || kind === 'experimental-webgl') {
          return {
            VENDOR: 0x1F00, RENDERER: 0x1F01, VERSION: 0x1F02, SHADING_LANGUAGE_VERSION: 0x8B8C,
            UNMASKED_VENDOR_WEBGL: 0x9245, UNMASKED_RENDERER_WEBGL: 0x9246,
            getParameter: (p) => {
              if (p === 0x1F00 || p === 0x9245) return fp.webglVendor   || 'Google Inc. (Apple)';
              if (p === 0x1F01 || p === 0x9246) return fp.webglRenderer || 'ANGLE (Apple, Apple M1 Pro, OpenGL 4.1)';
              if (p === 0x1F02) return 'WebGL 1.0 (OpenGL ES 2.0 Chromium)';
              if (p === 0x8B8C) return 'WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)';
              return 0;
            },
            getExtension: () => null, getSupportedExtensions: () => [],
            createBuffer: () => ({}), bindBuffer: () => {}, bufferData: () => {},
            createShader: () => ({}), shaderSource: () => {}, compileShader: () => {},
            createProgram: () => ({}), attachShader: () => {}, linkProgram: () => {}, useProgram: () => {},
            enable: () => {}, disable: () => {}, viewport: () => {}, clear: () => {}, clearColor: () => {},
            drawArrays: () => {}, drawElements: () => {},
          };
        }
        return null;
      };
    }
    return el;
  };

  // ── AudioContext fingerprint stub ────────────────────────────────────────
  global.AudioContext = global.webkitAudioContext = function () {
    return {
      sampleRate: 44100, currentTime: 0, state: 'running', destination: {},
      createOscillator: () => ({ connect: () => {}, start: () => {}, stop: () => {}, frequency: { value: 0 } }),
      createAnalyser:   () => ({ connect: () => {}, fftSize: 2048, getByteFrequencyData: (a) => { for (let i = 0; i < a.length; i++) a[i] = (fp.audioCtxHash || 0) % 256; } }),
      createGain:       () => ({ connect: () => {}, gain: { value: 1 } }),
      createBuffer:     () => ({ getChannelData: () => new Float32Array(1024) }),
      createBufferSource: () => ({ connect: () => {}, start: () => {}, stop: () => {} }),
      createScriptProcessor: () => ({ connect: () => {} }),
      createDynamicsCompressor: () => ({ connect: () => {}, threshold: { value: 0 }, knee: { value: 0 }, ratio: { value: 0 }, attack: { value: 0 }, release: { value: 0 } }),
      decodeAudioData: () => Promise.resolve({}),
      close: () => Promise.resolve(),
      resume: () => Promise.resolve(),
      suspend: () => Promise.resolve(),
    };
  };
  global.OfflineAudioContext = function (channels, length, rate) {
    return Object.assign(new global.AudioContext(), { length, sampleRate: rate, startRendering: () => Promise.resolve({ getChannelData: () => new Float32Array(length) }) });
  };

  // ── matchMedia / IntersectionObserver / ResizeObserver / MutationObserver ─
  global.matchMedia = (q) => ({
    matches: false, media: q, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  });
  global.IntersectionObserver = function () { return { observe: () => {}, unobserve: () => {}, disconnect: () => {}, takeRecords: () => [] }; };
  global.ResizeObserver       = function () { return { observe: () => {}, unobserve: () => {}, disconnect: () => {} }; };
  global.MutationObserver     = function () { return { observe: () => {}, disconnect: () => {}, takeRecords: () => [] }; };
  global.PerformanceObserver  = function () { return { observe: () => {}, disconnect: () => {}, takeRecords: () => [] }; };

  // ── chrome global (some bundles probe for it) ────────────────────────────
  global.chrome = {
    app: { isInstalled: false, InstallState: {}, RunningState: {} },
    runtime: { connect: () => {}, sendMessage: () => {}, id: undefined, onMessage: { addListener: () => {} } },
    csi: () => ({}), loadTimes: () => ({}),
  };

  // ── alert/confirm/prompt — silent ────────────────────────────────────────
  global.alert = () => {}; global.confirm = () => true; global.prompt = () => '';
  global.open = () => null; global.close = () => {}; global.focus = () => {}; global.blur = () => {};
  global.getComputedStyle = () => ({ getPropertyValue: () => '' });

  // ── done ─────────────────────────────────────────────────────────────────
  global.__shimInstalled = true;
})(globalThis);
