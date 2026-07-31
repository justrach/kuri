const CHANNEL_BASE = "https://raw.githubusercontent.com/justrach/kuri/release-channel/stable";
const DOWNLOAD_PREFIX = "/download";
const PUBLIC_BASE = "https://kuri.trilok.ai";
const PATH_PATTERN = /^(?:install\.sh|latest\.json|v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\/(?:manifest\.json|sha256sums\.txt|kuri-[A-Za-z0-9._-]+\.tar\.gz))$/;

function responseHeaders(upstream, path) {
  const headers = new Headers(upstream.headers);
  const isMutable = path === "install.sh" || path === "latest.json";

  headers.set("cache-control", isMutable ? "public, max-age=60, must-revalidate" : "public, max-age=31536000, immutable");
  headers.set("x-content-type-options", "nosniff");
  headers.set("x-kuri-download-proxy", "cloudflare-worker");

  if (path.endsWith(".tar.gz")) {
    const filename = path.slice(path.lastIndexOf("/") + 1);
    headers.set("content-disposition", `attachment; filename="${filename}"`);
  }

  return headers;
}

function upstreamPath(pathname) {
  if (pathname === DOWNLOAD_PREFIX || pathname === `${DOWNLOAD_PREFIX}/`) return "install.sh";
  if (!pathname.startsWith(`${DOWNLOAD_PREFIX}/`)) return null;

  const path = pathname.slice(`${DOWNLOAD_PREFIX}/`.length);
  return PATH_PATTERN.test(path) ? path : null;
}

function rewriteManifest(body, origin) {
  let manifest;
  try {
    manifest = JSON.parse(body);
  } catch {
    return null;
  }

  if (!manifest || typeof manifest.version !== "string" || !/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(manifest.version)) {
    return null;
  }

  manifest.install_url = `${origin}${DOWNLOAD_PREFIX}/install.sh`;
  if (manifest.assets && typeof manifest.assets === "object") {
    for (const asset of Object.values(manifest.assets)) {
      if (!asset || typeof asset.url !== "string") continue;
      const filename = asset.url.slice(asset.url.lastIndexOf("/") + 1);
      if (filename.endsWith(".tar.gz")) {
        asset.url = `${origin}${DOWNLOAD_PREFIX}/${manifest.version}/${filename}`;
      }
    }
  }

  return `${JSON.stringify(manifest, null, 2)}\n`;
}

export default {
  async fetch(request) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed\n", {
        status: 405,
        headers: { allow: "GET, HEAD", "content-type": "text/plain; charset=utf-8" },
      });
    }

    const requestUrl = new URL(request.url);
    const path = upstreamPath(requestUrl.pathname);
    if (!path) return new Response("Not Found\n", { status: 404 });

    const upstreamUrl = `${CHANNEL_BASE}/${path}`;
    const requestHeaders = new Headers();
    for (const name of ["accept", "if-modified-since", "if-none-match", "range"]) {
      const value = request.headers.get(name);
      if (value) requestHeaders.set(name, value);
    }

    const upstream = await fetch(upstreamUrl, {
      method: request.method,
      headers: requestHeaders,
      cf: {
        cacheEverything: true,
        cacheTtlByStatus: { "200-299": path === "install.sh" || path === "latest.json" ? 60 : 31536000, "404": 60 },
      },
    });

    const headers = responseHeaders(upstream, path);
    if (request.method === "GET" && upstream.ok && (path === "latest.json" || path.endsWith("/manifest.json"))) {
      const body = await upstream.text();
      const rewritten = rewriteManifest(body, PUBLIC_BASE);
      headers.delete("content-encoding");
      headers.delete("content-length");
      if (rewritten) {
        headers.delete("etag");
        headers.set("content-type", "application/json; charset=utf-8");
      }
      return new Response(rewritten || body, {
        status: upstream.status,
        statusText: upstream.statusText,
        headers,
      });
    }

    return new Response(request.method === "HEAD" ? null : upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers,
    });
  },
};
