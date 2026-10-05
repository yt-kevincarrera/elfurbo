import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./helpers";

const RELEASE = {
  tag_name: "v0.6.0",
  name: "El Furbo 0.6.0 (build 9)",
  body: "  Novedades  ",
  published_at: "2026-10-05T12:00:00Z",
  draft: false,
  assets: [
    { name: "app-arm64-v8a-release.apk", size: 21_000_000, digest: "sha256:" + "AB".repeat(32) },
    { name: "app-armeabi-v7a-release.apk", size: 19_000_000 },
    { name: "app-x86_64-release.apk", size: 22_000_000 },
    { name: "otra-cosa.txt", size: 3 },
  ],
};

type Handler = (url: string, init?: RequestInit) => Response | Promise<Response>;
let github: Handler;
let calls: { url: string; headers: Headers }[];

beforeEach(() => {
  calls = [];
  github = () => Response.json(RELEASE);
  const real = globalThis.fetch;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (!url.startsWith("https://api.github.com/") && !url.startsWith("https://github.com/")) return real(input, init);
    calls.push({ url, headers: new Headers(init?.headers) });
    return github(url, init);
  });
});
afterEach(() => vi.restoreAllMocks());

describe("GET /app/latest", () => {
  it("la última release, con un enlace a nuestro servidor por ABI", async () => {
    const res = await api("/app/latest");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      minSupportedBuild: 0,
      release: {
        tag: "v0.6.0",
        version: "0.6.0",
        build: 9,
        title: "El Furbo 0.6.0 (build 9)",
        notes: "Novedades",
        publishedAt: "2026-10-05T12:00:00Z",
        assets: [
          {
            abi: "arm64-v8a",
            name: "app-arm64-v8a-release.apk",
            size: 21_000_000,
            sha256: "ab".repeat(32),
            url: "https://api.test/app/apk/v0.6.0/arm64-v8a",
          },
          {
            abi: "armeabi-v7a",
            name: "app-armeabi-v7a-release.apk",
            size: 19_000_000,
            sha256: null,
            url: "https://api.test/app/apk/v0.6.0/armeabi-v7a",
          },
          {
            abi: "x86_64",
            name: "app-x86_64-release.apk",
            size: 22_000_000,
            sha256: null,
            url: "https://api.test/app/apk/v0.6.0/x86_64",
          },
        ],
      },
    });
    expect(calls[0]!.url).toBe("https://api.github.com/repos/yt-kevincarrera/elfurbo/releases/latest");
    expect(calls[0]!.headers.get("user-agent")).toBeTruthy();
  });

  it("no hace falta sesión y GitHub se consulta una vez por hora", async () => {
    await api("/app/latest");
    await api("/app/latest");
    expect(calls).toHaveLength(1);
    await env.DB.prepare("UPDATE kv SET expires_at = 1").run();
    await api("/app/latest");
    expect(calls).toHaveLength(2);
  });

  it("sin releases todavía: release null", async () => {
    github = () => new Response("{}", { status: 404 });
    expect((await api("/app/latest")).body).toEqual({ minSupportedBuild: 0, release: null });
  });

  it("si GitHub falla, sirve la última que vio; si nunca vio ninguna, 502", async () => {
    github = () => new Response("rate limited", { status: 403 });
    const none = await api("/app/latest");
    expect(none.status).toBe(502);
    expect(none.body.error.code).toBe("upstream_unavailable");

    github = () => Response.json(RELEASE);
    await api("/app/latest");
    await env.DB.prepare("UPDATE kv SET expires_at = 1").run();
    github = () => {
      throw new Error("sin red");
    };
    const stale = await api("/app/latest");
    expect(stale.status).toBe(200);
    expect(stale.body.release.tag).toBe("v0.6.0");
  });

  it("una release sin el build en el título da build null", async () => {
    github = () => Response.json({ ...RELEASE, name: "El Furbo 0.6.0" });
    expect((await api("/app/latest")).body.release.build).toBeNull();
  });
});

async function apk(path: string, headers: Record<string, string> = {}) {
  return exports.default.fetch(`https://api.test${path}`, { headers });
}

describe("GET /app/apk/:tag/:abi", () => {
  it("transmite el APK de GitHub con sus cabeceras", async () => {
    github = () =>
      new Response("APK-BYTES", { headers: { "content-length": "9", etag: '"abc"', "x-github": "no-pasa" } });
    const res = await apk("/app/apk/v0.6.0/arm64-v8a");
    expect(res.status).toBe(200);
    expect(new TextDecoder().decode(await res.arrayBuffer())).toBe("APK-BYTES");
    expect(res.headers.get("content-type")).toBe("application/vnd.android.package-archive");
    expect(res.headers.get("content-length")).toBe("9");
    expect(res.headers.get("etag")).toBe('"abc"');
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("x-github")).toBeNull();
    expect(calls[0]!.url).toBe(
      "https://github.com/yt-kevincarrera/elfurbo/releases/download/v0.6.0/app-arm64-v8a-release.apk",
    );
  });

  it("pasa el Range: una descarga cortada sigue donde se quedó", async () => {
    github = (_u, init) => {
      expect(new Headers(init?.headers).get("range")).toBe("bytes=5-");
      return new Response("BYTES", {
        status: 206,
        headers: { "content-range": "bytes 5-9/10", "content-length": "5" },
      });
    };
    const res = await apk("/app/apk/v0.6.0/arm64-v8a", { range: "bytes=5-" });
    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe("bytes 5-9/10");
    expect(new TextDecoder().decode(await res.arrayBuffer())).toBe("BYTES");
  });

  it("una versión o ABI raras dan 404 sin preguntar a GitHub", async () => {
    for (const p of [
      "/app/apk/latest/arm64-v8a",
      "/app/apk/v0.6.0/mips",
      "/app/apk/v0.6.0/..%2F..%2Fx",
      "/app/apk/v1.2/arm64-v8a",
    ]) {
      const res = await apk(p);
      expect(res.status, p).toBe(404);
      await res.body?.cancel();
    }
    expect(calls).toHaveLength(0);
  });

  it("si GitHub no lo tiene, 404; si falla, 502", async () => {
    github = () => new Response("no", { status: 404 });
    const missing = await apk("/app/apk/v9.9.9/arm64-v8a");
    expect(missing.status).toBe(404);
    await missing.body?.cancel();
    github = () => new Response("boom", { status: 500 });
    const broken = await apk("/app/apk/v0.6.0/arm64-v8a");
    expect(broken.status).toBe(502);
    await broken.body?.cancel();
  });
});
