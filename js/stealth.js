// Stealth script — injected via Page.addScriptToEvaluateOnNewDocument
// Hides automation indicators from bot detection

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

// 7. WebGL renderer spoofing
try {
    const getParameterProto = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function (param) {
        if (param === 0x1F01) return 'Intel Inc.'; // VENDOR
        if (param === 0x1F00) return 'Intel Iris OpenGL Engine'; // RENDERER
        if (param === 0x9245) return 'Intel Inc.'; // UNMASKED_VENDOR_WEBGL
        if (param === 0x9246) return 'Intel Iris OpenGL Engine'; // UNMASKED_RENDERER_WEBGL
        return getParameterProto.call(this, param);
    };
    if (typeof WebGL2RenderingContext !== 'undefined') {
        const getParameter2Proto = WebGL2RenderingContext.prototype.getParameter;
        WebGL2RenderingContext.prototype.getParameter = function (param) {
            if (param === 0x1F01) return 'Intel Inc.';
            if (param === 0x1F00) return 'Intel Iris OpenGL Engine';
            if (param === 0x9245) return 'Intel Inc.';
            if (param === 0x9246) return 'Intel Iris OpenGL Engine';
            return getParameter2Proto.call(this, param);
        };
    }
} catch (e) {}

// 8. Canvas fingerprint noise
try {
    const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
    HTMLCanvasElement.prototype.toDataURL = function (type) {
        const ctx = this.getContext('2d');
        if (ctx) {
            const shift = (Math.random() - 0.5) * 0.01;
            const { width, height } = this;
            if (width && height) {
                const imageData = ctx.getImageData(0, 0, width, height);
                for (let i = 0; i < imageData.data.length; i += 4) {
                    imageData.data[i] = Math.max(0, Math.min(255, imageData.data[i] + shift));
                }
                ctx.putImageData(imageData, 0, 0);
            }
        }
        return origToDataURL.apply(this, arguments);
    };
    const origToBlob = HTMLCanvasElement.prototype.toBlob;
    HTMLCanvasElement.prototype.toBlob = function (callback, type, quality) {
        const ctx = this.getContext('2d');
        if (ctx) {
            const shift = (Math.random() - 0.5) * 0.01;
            const { width, height } = this;
            if (width && height) {
                const imageData = ctx.getImageData(0, 0, width, height);
                for (let i = 0; i < imageData.data.length; i += 4) {
                    imageData.data[i] = Math.max(0, Math.min(255, imageData.data[i] + shift));
                }
                ctx.putImageData(imageData, 0, 0);
            }
        }
        return origToBlob.apply(this, arguments);
    };
} catch (e) {}

// 9. AudioContext fingerprint noise
try {
    const origCreateOscillator = AudioContext.prototype.createOscillator;
    AudioContext.prototype.createOscillator = function () {
        const oscillator = origCreateOscillator.apply(this, arguments);
        const origStart = oscillator.start.bind(oscillator);
        oscillator.start = function (when) {
            const noise = Math.random() * 1e-7;
            return origStart((when || 0) + noise);
        };
        return oscillator;
    };
} catch (e) {}

// 10. navigator.hardwareConcurrency spoofing
Object.defineProperty(navigator, 'hardwareConcurrency', {
    get: () => 4,
    configurable: true,
});

// 11. navigator.deviceMemory spoofing
Object.defineProperty(navigator, 'deviceMemory', {
    get: () => 8,
    configurable: true,
});

// 12. navigator.connection spoofing
if (!navigator.connection) {
    Object.defineProperty(navigator, 'connection', {
        get: () => ({
            effectiveType: '4g',
            rtt: 50,
            downlink: 10,
            saveData: false,
        }),
        configurable: true,
    });
}

// 13. window.chrome.csi and window.chrome.loadTimes stubs
if (window.chrome) {
    if (!window.chrome.csi) {
        window.chrome.csi = () => ({
            startE: Date.now(),
            onloadT: Date.now(),
            pageT: Math.random() * 1000 + 100,
            tpiT: 0,
        });
    }
    if (!window.chrome.loadTimes) {
        window.chrome.loadTimes = () => ({
            commitLoadTime: Date.now() / 1000,
            connectionInfo: 'h2',
            finishDocumentLoadTime: Date.now() / 1000,
            finishLoadTime: Date.now() / 1000,
            firstPaintAfterLoadTime: 0,
            firstPaintTime: Date.now() / 1000,
            navigationType: 'Other',
            npnNegotiatedProtocol: 'h2',
            requestTime: Date.now() / 1000 - 0.3,
            startLoadTime: Date.now() / 1000 - 0.5,
            wasAlternateProtocolAvailable: false,
            wasFetchedViaSpdy: true,
            wasNpnNegotiated: true,
        });
    }
}
