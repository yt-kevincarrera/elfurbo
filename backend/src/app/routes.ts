import { Hono } from "hono";
import { ApiError, errors } from "../http/errors";
import { downloadErrorPage } from "../invites/page";
import type { AppEnv } from "../types";
import { ABIS, type Abi, apkName, latestRelease, REPO, TAG, UpstreamError } from "./github";

/**
 * Actualizaciones de la app sin GitHub: desde Cuba GitHub no abre, así que el Worker hace de
 * intermediario. No hace falta sesión (también se actualiza quien no ha entrado).
 */
export const appRoutes = new Hono<AppEnv>();

const upstream = () =>
  new ApiError(502, "upstream_unavailable", "Ahora mismo no se puede consultar la versión nueva. Prueba más tarde");

/** `{minSupportedBuild, release}`; `release` es null si no hay ninguna publicada. */
appRoutes.get("/latest", async (c) => {
  const minSupportedBuild = Number(c.env.MIN_SUPPORTED_BUILD ?? 0) || 0;
  let release;
  try {
    release = await latestRelease(c.env.DB, c.env.GITHUB_TOKEN);
  } catch (e) {
    if (e instanceof UpstreamError) throw upstream();
    throw e;
  }
  const origin = new URL(c.req.url).origin;
  return c.json({
    minSupportedBuild,
    release: release && {
      ...release,
      assets: release.assets.map((a) => ({ ...a, url: `${origin}/app/apk/${release.tag}/${a.abi}` })),
    },
  });
});

/**
 * Para bajar la app desde el navegador (la página de invitación): la última release para
 * `?abi=` (por defecto arm64-v8a, la de casi todos los teléfonos de hoy).
 */
appRoutes.get("/download", async (c) => {
  const abi = (c.req.query("abi") ?? "arm64-v8a") as Abi;
  const fail = (message: string, status: 404 | 502) => c.html(downloadErrorPage(message), status);
  if (!ABIS.includes(abi)) return fail("Ese tipo de teléfono no existe.", 404);
  let release;
  try {
    release = await latestRelease(c.env.DB, c.env.GITHUB_TOKEN);
  } catch (e) {
    if (e instanceof UpstreamError) return fail("Ahora mismo no se puede. Prueba en un rato.", 502);
    throw e;
  }
  if (!release?.assets.some((a) => a.abi === abi)) {
    return fail("Todavía no hay una versión publicada para este teléfono.", 404);
  }
  return c.redirect(`/app/apk/${release.tag}/${abi}`, 302);
});

/**
 * Transmite el APK desde GitHub (el teléfono nunca toca GitHub; en Cloudflare no se guarda nada).
 * Respeta `Range`: con la conexión de Cuba, una descarga cortada sigue donde se quedó.
 */
appRoutes.get("/apk/:tag/:abi", async (c) => {
  const tag = c.req.param("tag");
  const abi = c.req.param("abi") as Abi;
  if (!TAG.test(tag) || !ABIS.includes(abi)) throw errors.notFound();
  const headers: Record<string, string> = { "user-agent": "furbo-api" };
  const range = c.req.header("range");
  if (range) headers.range = range;
  let res: Response;
  try {
    res = await fetch(`https://github.com/${REPO}/releases/download/${tag}/${apkName(abi)}`, { headers });
  } catch {
    throw upstream();
  }
  if (res.status === 404) throw errors.notFound();
  if (res.status !== 200 && res.status !== 206 && res.status !== 416) throw upstream();
  const out = new Headers({
    "content-type": "application/vnd.android.package-archive",
    "content-disposition": `attachment; filename="${apkName(abi)}"`,
    "accept-ranges": "bytes",
    "cache-control": "public, max-age=86400",
  });
  for (const h of ["content-length", "content-range", "etag", "last-modified"]) {
    const v = res.headers.get(h);
    if (v) out.set(h, v);
  }
  return new Response(res.body, { status: res.status, headers: out });
});
