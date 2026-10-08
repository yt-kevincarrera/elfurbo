import { Hono } from "hono";
import { DOWNLOAD, escapeHtml, layout } from "../invites/page";
import { standings } from "../rules/standings";
import { rulesOf } from "../rules/tournament";
import type { AppEnv } from "../types";

/**
 * `/t/:clubId`: la página que se comparte de un torneo público (spec 2.0 §7.7): el campeón si ya
 * terminó, las tablas (liga o grupos), los últimos resultados y los goleadores. Sin sesión. Todo lo
 * que escribió alguien sale escapado.
 */
export const tournamentPageRoutes = new Hono<AppEnv>();

type Team = { id: string; name: string; seed: number | null; group_label: string | null };
type Fixture = {
  id: string;
  stage: string;
  round: number;
  group_label: string | null;
  home_team_id: string | null;
  away_team_id: string | null;
  status: string;
  home_score: number | null;
  away_score: number | null;
  home_pens: number | null;
  away_pens: number | null;
  walkover_winner: string | null;
  result_at: string | null;
};

const notFound = () =>
  layout(`<h1>⚽ No está</h1><p>Este torneo no existe o no es público.</p>${DOWNLOAD}`, "El Furbo");

const FORMAT: Record<string, string> = { league: "Liga", cup: "Copa", groups_cup: "Grupos y copa" };

tournamentPageRoutes.get("/:clubId", async (c) => {
  const db = c.env.DB;
  c.header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'");
  c.header("Referrer-Policy", "no-referrer");
  const t = await db
    .prepare(
      `SELECT c.id, c.name, c.description, t.format, t.status, t.rules FROM clubs c JOIN tournaments t ON t.club_id = c.id
        WHERE c.id = ? AND c.kind = 'tournament' AND c.visibility = 'public' AND c.status = 'active' AND c.delisted = 0`,
    )
    .bind(c.req.param("clubId"))
    .first<{ id: string; name: string; description: string; format: string; status: string; rules: string }>();
  if (!t) return c.html(notFound(), 404);
  const { results: teams } = await db
    .prepare("SELECT id, name, seed, group_label FROM teams WHERE club_id = ? AND status = 'approved'")
    .bind(t.id)
    .all<Team>();
  const { results: fixtures } = await db
    .prepare(
      `SELECT id, stage, round, group_label, home_team_id, away_team_id, status, home_score, away_score, home_pens, away_pens,
              walkover_winner, result_at
         FROM fixtures WHERE club_id = ?`,
    )
    .bind(t.id)
    .all<Fixture>();
  const { results: cards } = await db
    .prepare("SELECT fixture_id, team_id, kind FROM fixture_events WHERE club_id = ? AND kind IN ('yellow', 'red')")
    .bind(t.id)
    .all<{ fixture_id: string; team_id: string; kind: string }>();
  const { results: scorers } = await db
    .prepare(
      `SELECT COALESCE(NULLIF(m.nickname, ''), m.display_name) AS name, COUNT(*) AS goals
         FROM fixture_events e JOIN members m ON m.id = e.member_id JOIN fixtures f ON f.id = e.fixture_id
        WHERE e.club_id = ? AND e.kind = 'goal' AND f.status = 'played'
        GROUP BY e.member_id ORDER BY goals DESC LIMIT 5`,
    )
    .bind(t.id)
    .all<{ name: string; goals: number }>();
  const champion = await db
    .prepare("SELECT tm.name FROM awards a JOIN teams tm ON tm.id = a.team_id WHERE a.club_id = ? AND a.kind = 'champion'")
    .bind(t.id)
    .first<{ name: string }>();

  const rules = rulesOf(t.rules);
  const names = new Map(teams.map((x) => [x.id, x.name]));
  const toStandings = (f: Fixture) => ({
    id: f.id,
    homeTeamId: f.home_team_id,
    awayTeamId: f.away_team_id,
    status: f.status,
    homeScore: f.home_score,
    awayScore: f.away_score,
    walkoverWinner: f.walkover_winner,
  });
  const events = cards.map((e) => ({ fixtureId: e.fixture_id, teamId: e.team_id, kind: e.kind }));
  const table = (group: string | null) => {
    const ts = teams.filter((x) => group === null || x.group_label === group);
    const fs = fixtures.filter((f) => (group === null ? f.stage === "league" : f.stage === "group" && f.group_label === group));
    if (fs.length === 0) return "";
    const rows = standings(ts.map((x) => ({ id: x.id, name: x.name, seed: x.seed })), fs.map(toStandings), events, rules);
    return `<h2>${group === null ? "Tabla" : `Grupo ${escapeHtml(group)}`}</h2>
<table><tr><th></th><th>Equipo</th><th>PJ</th><th>DG</th><th>Pts</th></tr>${rows
      .map(
        (r, i) =>
          `<tr><td>${i + 1}</td><td class="team">${escapeHtml(names.get(r.teamId) ?? "")}</td><td>${r.played}</td>` +
          `<td>${r.goalsFor - r.goalsAgainst}</td><td><b>${r.points}</b></td></tr>`,
      )
      .join("")}</table>`;
  };
  const groups = [...new Set(teams.map((x) => x.group_label).filter((g): g is string => !!g))].sort();
  const recent = fixtures
    .filter((f) => f.status === "played" || f.status === "walkover")
    .sort((a, b) => (b.result_at ?? "").localeCompare(a.result_at ?? ""))
    .slice(0, 6);
  const result = (f: Fixture) => {
    const home = escapeHtml(names.get(f.home_team_id ?? "") ?? "?");
    const away = escapeHtml(names.get(f.away_team_id ?? "") ?? "?");
    const score =
      f.status === "walkover"
        ? "W.O."
        : `${f.home_score} - ${f.away_score}${f.home_pens !== null ? ` (${f.home_pens}-${f.away_pens} pen.)` : ""}`;
    return `<li>${home} <b>${escapeHtml(score)}</b> ${away}</li>`;
  };

  const body = `<p>${escapeHtml(FORMAT[t.format] ?? "Torneo")}</p>
<h1>🏆 ${escapeHtml(t.name)}</h1>
${t.description ? `<p>${escapeHtml(t.description)}</p>` : ""}
${champion ? `<p class="code">Campeón: ${escapeHtml(champion.name)}</p>` : ""}
${table(null)}${groups.map((g) => table(g)).join("")}
${recent.length ? `<h2>Últimos resultados</h2><ul class="list">${recent.map(result).join("")}</ul>` : ""}
${scorers.length ? `<h2>Goleadores</h2><ol class="list">${scorers.map((s) => `<li>${escapeHtml(s.name)} <b>${s.goals}</b></li>`).join("")}</ol>` : ""}
<p><a class="button" href="elfurbo://club/${encodeURIComponent(t.id)}">Abrir en El Furbo</a></p>
${DOWNLOAD}`;
  return c.html(layout(body, `${t.name} · El Furbo`));
});
