// Stealth script — injected via Page.addScriptToEvaluateOnNewDocument AND
// evaluated once into the already-loaded page (same dual pattern as
// console_collector.js / react_fiber.js).
//
// That dual injection is why this whole file is an IIFE with an idempotence
// guard. Previously the body was top-level, so re-running it in the SAME
// global (which happens whenever discoverTabs re-runs against a live tab)
// re-declared `const originalQuery` — a SyntaxError that (a) aborted the
// entire re-injection at parse time, so nothing after it applied, and (b)
// surfaced in the page's error stream, polluting /errors with a kuri-internal
// failure on every page. The guard also prevents the permissions-query
// wrapper from being wrapped around itself on repeat application.
(function () {
    if (window.__kuri_stealth_applied) return;
    window.__kuri_stealth_applied = true;

    // 1. Override navigator.webdriver
    Object.defineProperty(navigator, 'webdriver', {
        get: () => false,
        configurable: true,
    });

    // 2. Fake plugins array (Chrome normally has plugins)
    Object.defineProperty(navigator, 'plugins', {
        get: () => {
            const plugins = [
                { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
                { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '' },
                { name: 'Native Client', filename: 'internal-nacl-plugin', description: '' },
            ];
            plugins.length = 3;
            return plugins;
        },
        configurable: true,
    });

    // 3. Fake languages
    Object.defineProperty(navigator, 'languages', {
        get: () => ['en-US', 'en'],
        configurable: true,
    });

    // 4. Override chrome.runtime to appear as real Chrome
    if (!window.chrome) {
        window.chrome = {};
    }
    if (!window.chrome.runtime) {
        window.chrome.runtime = {
            connect: () => {},
            sendMessage: () => {},
            id: undefined,
        };
    }

    // 5. Override permissions query
    const originalQuery = window.navigator.permissions?.query;
    if (originalQuery) {
        window.navigator.permissions.query = (parameters) => {
            if (parameters.name === 'notifications') {
                return Promise.resolve({ state: Notification.permission });
            }
            return originalQuery(parameters);
        };
    }

    // 6. Spoof iframe contentWindow
    try {
        const elementDescriptor = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow');
        if (elementDescriptor) {
            Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow', {
                get: function () {
                    return elementDescriptor.get.call(this);
                },
            });
        }
    } catch (e) {
        // Silently fail
    }
})();
