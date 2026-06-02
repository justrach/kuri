# Vendored libcurl-impersonate

Source: https://github.com/lexiforest/curl-impersonate (active fork)
Version: v1.5.6 (2025-05-02)

Why vendored: Kuri statically links libcurl-impersonate so adversarial
TLS handshake mimicry is built-in. No `brew install`, no per-platform
runtime download, no subprocess fork — just one Zig FFI call into a
self-contained 32MB static archive.

## Layout

```
include/curl/        # vanilla curl 8.10.0 headers (libcurl-impersonate
                     # is ABI-compatible with stock libcurl + adds one
                     # function: curl_easy_impersonate)
aarch64-macos/       # Apple Silicon (M1/M2/M3/M4)
x86_64-macos/        # Intel Mac
aarch64-linux-gnu/   # ARM64 Linux (servers, Raspberry Pi 4+)
x86_64-linux-gnu/    # x64 Linux
```

Each platform dir contains a single `libcurl-impersonate.a` (~30MB) with
BoringSSL, nghttp2, ngtcp2, brotli, zstd, libpsl all baked in.

## Refreshing a platform

```bash
TAG=v1.5.6
ARCH=arm64-macos   # or x86_64-macos, aarch64-linux-gnu, x86_64-linux-gnu

curl -L -o /tmp/libcurl-imp.tar.gz \
  "https://github.com/lexiforest/curl-impersonate/releases/download/${TAG}/libcurl-impersonate-${TAG}.${ARCH}.tar.gz"
mkdir -p /tmp/libcurl-imp && tar -xzf /tmp/libcurl-imp.tar.gz -C /tmp/libcurl-imp

# Map release-arch → vendor-dir
case "$ARCH" in
  arm64-macos)        VDIR=aarch64-macos ;;
  x86_64-macos)       VDIR=x86_64-macos ;;
  aarch64-linux-gnu)  VDIR=aarch64-linux-gnu ;;
  x86_64-linux-gnu)   VDIR=x86_64-linux-gnu ;;
esac

cp /tmp/libcurl-imp/libcurl-impersonate.a \
   submodules/kuri/vendor/curl-impersonate/$VDIR/
```

## License

curl-impersonate: MIT (carries forward libcurl's MIT license)
BoringSSL (statically linked inside the .a): BSD-style with attribution
nghttp2: MIT
brotli: MIT
zstd: BSD

All compatible with Kuri's SSPL distribution.

## Headers

`include/curl/*` are vanilla curl 8.10.0 headers. The ONE addition
libcurl-impersonate makes is:

```c
CURLcode curl_easy_impersonate(CURL *handle, const char *target, int default_headers);
```

Declared inline in `src/sandbox/curl_lib.zig` rather than added to the
vendored headers — keeps the headers a clean upstream copy.
