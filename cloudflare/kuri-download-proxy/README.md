# Kuri download proxy

This Cloudflare Worker maps the public download surface to the stable
`release-channel` branch without exposing GitHub in the user-facing URL:

- `GET /download` (or `/download/`) serves the installer script, so this works:
  `curl -fsSL https://kuri.trilok.ai/download | sh`
- `GET /download/latest.json` serves the stable manifest, rewriting its
  installer and asset URLs back through this proxy.
- `GET /download/v<version>/<asset>` proxies versioned manifests, checksums,
  and tarballs.

The Worker uses a fixed upstream and rejects arbitrary paths; it is not a
user-controlled proxy. Versioned assets are cached immutably, while the
installer and latest manifest revalidate every minute.

## Deploy

The `kuri.trilok.ai` DNS record must already exist in the `trilok.ai` zone and
be proxied by Cloudflare. Deploy from the repository root with an authenticated
Wrangler session:

```sh
wrangler deploy --config cloudflare/kuri-download-proxy/wrangler.toml
```

The route is intentionally limited to `kuri.trilok.ai/download*`; other paths
on the hostname continue to be handled by the existing origin.
