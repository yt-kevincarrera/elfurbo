import { kvGet, kvSet } from "../kv";

/** El repo de las releases. Los APK son los de `flutter build apk --split-per-abi`. */
export const REPO = "yt-kevincarrera/elfurbo";
export const ABIS = ["arm64-v8a", "armeabi-v7a", "x86_64"] as const;
export type Abi = (typeof ABIS)[number];
export const TAG = /^v\d{1,4}\.\d{1,4}\.\d{1,4}$/;

/** La última release, lo justo para la app. Los APK van por ABI; la URL la pone la ruta. */
export type Release = {
  tag: string;
  version: string;
  build: number | null;
  title: string;
  notes: string;
  publishedAt: string | null;
  /** `sha256` (hex) lo da GitHub; la app comprueba el APK antes de darlo por bueno. */
  assets: { abi: Abi; name: string; size: number; sha256: string | null }[];
};

const CACHE_KEY = "github.latestRelease";
const CACHE_MS = 60 * 60 * 1000;

export const apkName = (abi: Abi) => `app-${abi}-release.apk`;

export function githubHeaders(token?: string): Record<string, string> {
  const h: Record<string, string> = { "user-agent": "furbo-api", accept: "application/vnd.github+json" };
  if (token) h.authorization = `Bearer ${token}`;
  return h;
}

/** Lo que interesa del JSON de `GET /repos/{repo}/releases/latest`. */
export function parseRelease(json: Record<string, unknown>): Release {
  const tag = String(json.tag_name ?? "");
  const title = String(json.name ?? "");
  // `release.sh` titula "El Furbo 0.5.0" y el commit lleva el build; si el título trae "(build N)", se usa.
  const build = /build\s+(\d+)/i.exec(title)?.[1];
  const assets = Array.isArray(json.assets) ? (json.assets as Record<string, unknown>[]) : [];
  return {
    tag,
    version: tag.replace(/^v/i, ""),
    build: build ? Number(build) : null,
    title,
    notes: String(json.body ?? "").trim(),
    publishedAt: typeof json.published_at === "string" ? json.published_at : null,
    assets: ABIS.flatMap((abi) => {
      const a = assets.find((x) => x.name === apkName(abi));
      if (!a) return [];
      const digest = typeof a.digest === "string" ? /^sha256:([0-9a-f]{64})$/i.exec(a.digest)?.[1] : undefined;
      return [{ abi, name: apkName(abi), size: Number(a.size) || 0, sha256: digest?.toLowerCase() ?? null }];
    }),
  };
}

export class UpstreamError extends Error {}

/**
 * La última release publicada (null si no hay ninguna). Se guarda una hora en D1; si GitHub falla
 * (caído, o el límite de 60 peticiones por hora de la IP de Cloudflare), se sirve la última que se vio.
 */
export async function latestRelease(db: D1Database, token?: string, now = Date.now()): Promise<Release | null> {
  const cached = await kvGet(db, CACHE_KEY, now);
  if (cached?.fresh) return JSON.parse(cached.value) as Release | null;
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: githubHeaders(token),
    });
    let release: Release | null;
    if (res.status === 404) release = null; // sin releases todavía
    else if (!res.ok) throw new UpstreamError(`GitHub respondió ${res.status}`);
    else release = parseRelease(await res.json());
    await kvSet(db, CACHE_KEY, JSON.stringify(release), now + CACHE_MS);
    return release;
  } catch (e) {
    if (cached) return JSON.parse(cached.value) as Release | null;
    throw e instanceof UpstreamError ? e : new UpstreamError(String(e));
  }
}
