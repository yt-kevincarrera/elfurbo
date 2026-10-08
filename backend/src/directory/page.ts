import { Hono } from "hono";
import { DOWNLOAD, escapeHtml, layout } from "../invites/page";
import { PROVINCES, type Province } from "../rules/provinces";
import type { AppEnv } from "../types";
import { publicExtras } from "./routes";

const TIER_LABEL: Record<string, string> = {
  official: "⭐ Oficial",
  verified: "✓ Verificado",
  established: "Establecido",
  casual: "Casual",
  new: "Nuevo",
};

type PageClub = {
  id: string;
  name: string;
  description: string;
  province: string | null;
  city: string | null;
  official: number;
  tier: string | null;
};

const notFound = () =>
  layout(`<h1>⚽ No está</h1><p>Este servidor no existe o no es público.</p>${DOWNLOAD}`, "El Furbo");

/** La fecha en La Habana: "sábado 11 oct, 16:00". */
function when(iso: string) {
  return new Intl.DateTimeFormat("es", {
    timeZone: "America/Havana",
    weekday: "long",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(iso));
}

export function clubPage(club: PageClub | null, extras: Awaited<ReturnType<typeof publicExtras>> | null) {
  if (!club || !extras) return notFound();
  const place = [club.city, club.province ? PROVINCES[club.province as Province] : null].filter(Boolean).join(", ");
  const tier = TIER_LABEL[club.official === 1 ? "official" : (club.tier ?? "new")] ?? "";
  const scorers = extras.topScorers.length
    ? `<h2>Goleadores${extras.season ? ` · ${escapeHtml(extras.season)}` : ""}</h2><ol class="list">${extras.topScorers
        .map((s) => `<li>${escapeHtml(s.name)} <b>${s.goals}</b> <small>(${s.played} PJ)</small></li>`)
        .join("")}</ol>`
    : "";
  const next = extras.upcoming[0];
  const nextLine = next
    ? `<p>Próxima jornada: <b>${escapeHtml(when(next.startsAt))}</b>${next.place ? ` · ${escapeHtml(next.place)}` : ""}</p>`
    : "";
  return layout(
    `<p>${escapeHtml(tier)}${place ? ` · ${escapeHtml(place)}` : ""}</p>
<h1>⚽ ${escapeHtml(club.name)}</h1>
${club.description ? `<p>${escapeHtml(club.description)}</p>` : ""}
${nextLine}${scorers}
<p><a class="button" href="elfurbo://club/${encodeURIComponent(club.id)}">Pedir entrar en El Furbo</a></p>
${DOWNLOAD}`,
    `${club.name} · El Furbo`,
  );
}

/** `/s/:clubId`: la página que se comparte de un servidor público (sin sesión). */
export const clubPageRoutes = new Hono<AppEnv>();

clubPageRoutes.get("/:clubId", async (c) => {
  const db = c.env.DB;
  const club = await db
    .prepare(
      `SELECT c.id, c.name, c.description, c.province, c.city, c.official, cm.tier
         FROM clubs c LEFT JOIN club_metrics cm ON cm.club_id = c.id
        WHERE c.id = ? AND c.visibility = 'public' AND c.status = 'active' AND c.delisted = 0 AND c.kind = 'group'`,
    )
    .bind(c.req.param("clubId"))
    .first<PageClub>();
  c.header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'");
  c.header("Referrer-Policy", "no-referrer");
  if (!club) return c.html(clubPage(null, null), 404);
  return c.html(clubPage(club, await publicExtras(db, club.id)));
});
