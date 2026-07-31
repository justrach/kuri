// Thin client for the kuri HTTP API — the browser engine that produces the
// observations we price. One instance is bound to a base URL + token + tab.
export interface KuriOpts {
  base?: string; // default http://127.0.0.1:8081
  token?: string; // Bearer / KURI_API_TOKEN
  tab?: string; // resolved from /tabs if omitted
}

export class Kuri {
  base: string;
  token: string;
  tab: string;

  private constructor(base: string, token: string, tab: string) {
    this.base = base;
    this.token = token;
    this.tab = tab;
  }

  static async connect(opts: KuriOpts = {}): Promise<Kuri> {
    const base = opts.base ?? process.env.KURI_BASE ?? "http://127.0.0.1:8081";
    const token = opts.token ?? process.env.KURI_API_TOKEN ?? "";
    let tab = opts.tab ?? "";
    if (!tab) {
      const res = await fetch(`${base}/tabs`, { headers: authHeader(token) });
      const tabs = (await res.json()) as Array<{ id: string }>;
      if (!tabs.length) throw new Error("kuri: no open tabs (start the server + open a tab first)");
      tab = tabs[0].id;
    }
    return new Kuri(base, token, tab);
  }

  private async get(path: string): Promise<string> {
    const url = `${this.base}${path}${path.includes("?") ? "&" : "?"}tab_id=${encodeURIComponent(this.tab)}`;
    const res = await fetch(url, { headers: authHeader(this.token) });
    return await res.text();
  }

  async navigate(url: string): Promise<void> {
    await this.get(`/navigate?url=${encodeURIComponent(url)}`);
  }

  // Observation modes — each returns the exact text an agent would receive.
  snapshot(o: { filter?: "interactive"; format?: "compact"; limit?: number; scope?: string; hierarchy?: boolean } = {}): Promise<string> {
    const q = new URLSearchParams();
    q.set("format", o.format ?? "compact");
    if (o.filter) q.set("filter", o.filter);
    if (o.limit != null) q.set("limit", String(o.limit));
    if (o.scope) q.set("scope", o.scope);
    if (o.hierarchy) q.set("hierarchy", "true");
    return this.get(`/snapshot?${q.toString()}`);
  }

  diff(limit?: number): Promise<string> {
    return this.get(limit != null ? `/diff/snapshot?limit=${limit}` : `/diff/snapshot`);
  }

  pageState(): Promise<string> {
    return this.get(`/page/state`);
  }

  action(action: string, ref?: string, value?: string): Promise<string> {
    let p = `/action?action=${encodeURIComponent(action)}`;
    if (ref) p += `&ref=${encodeURIComponent(ref)}`;
    if (value != null) p += `&value=${encodeURIComponent(value)}`;
    return this.get(p);
  }
}

function authHeader(token: string): Record<string, string> {
  return token ? { authorization: `Bearer ${token}` } : {};
}

// Pull the @eN refs out of a compact snapshot line-set, optionally filtered by a
// substring (e.g. "Upvote") — used by the synthetic estimator to pick targets.
export function refsMatching(snapshot: string, contains?: string): string[] {
  const out: string[] = [];
  for (const line of snapshot.split("\n")) {
    if (contains && !line.includes(contains)) continue;
    const m = line.match(/@(e\d+)/);
    if (m) out.push(m[1]);
  }
  return out;
}
