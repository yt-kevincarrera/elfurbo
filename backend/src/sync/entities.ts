import { clubSettings } from "../clubs/model";
import { rulesOf } from "../rules/tournament";
import type { SyncEntity } from "./changes";

type Row = Record<string, unknown>;

/** Cómo se lee cada entidad para el pull: tabla, columnas y forma en JSON (camelCase). */
type EntityDef = {
  table: string;
  /** Columna que filtra por servidor. */
  clubColumn: string;
  keyColumn: string;
  columns: string;
  toJson: (row: Row) => Record<string, unknown>;
};

const jsonOrNull = (v: unknown) => (v === null || v === undefined ? null : (JSON.parse(String(v)) as unknown));

export const ENTITIES: Record<SyncEntity, EntityDef> = {
  club: {
    table: "clubs",
    clubColumn: "id",
    keyColumn: "id",
    columns: "id, name, description, status, settings, kind, visibility, official, province, city, color, host_club_id, delisted",
    toJson: (r) => ({
      id: r.id,
      name: r.name,
      description: r.description,
      status: r.status,
      settings: clubSettings(String(r.settings)),
      kind: r.kind,
      visibility: r.visibility,
      official: r.official === 1,
      province: r.province,
      city: r.city,
      color: r.color,
      hostClubId: r.host_club_id,
      delisted: r.delisted === 1,
    }),
  },
  member: {
    table: "members",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, user_id, role, status, display_name, nickname, claimed_at",
    toJson: (r) => ({
      id: r.id,
      userId: r.user_id,
      role: r.role,
      status: r.status,
      displayName: r.display_name,
      nickname: r.nickname,
      claimedAt: r.claimed_at,
    }),
  },
  season: {
    table: "seasons",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, name, start_date, is_active, is_closed",
    toJson: (r) => ({
      id: r.id,
      name: r.name,
      startDate: r.start_date,
      isActive: r.is_active === 1,
      isClosed: r.is_closed === 1,
    }),
  },
  matchday: {
    table: "matchdays",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, season_id, starts_at, duration_minutes, place, notes, status, teams, created_by",
    toJson: (r) => ({
      id: r.id,
      seasonId: r.season_id,
      startsAt: r.starts_at,
      durationMinutes: r.duration_minutes,
      place: r.place,
      notes: r.notes,
      status: r.status,
      teams: r.teams === null ? null : JSON.parse(String(r.teams)),
      createdBy: r.created_by,
    }),
  },
  attendance: {
    table: "attendance",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, member_id, intent, played, played_set_by",
    toJson: (r) => ({
      id: r.id,
      matchdayId: r.matchday_id,
      memberId: r.member_id,
      intent: r.intent,
      played: r.played === null ? null : r.played === 1,
      playedSetBy: r.played_set_by,
    }),
  },
  report: {
    table: "reports",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, member_id, goals, assists, note, loaded_by, decision, corrected_by, updated_at",
    toJson: (r) => ({
      id: r.id,
      matchdayId: r.matchday_id,
      memberId: r.member_id,
      goals: r.goals,
      assists: r.assists,
      note: r.note,
      loadedBy: r.loaded_by,
      decision: r.decision,
      correctedBy: r.corrected_by,
      updatedAt: r.updated_at,
    }),
  },
  confirmation: {
    table: "report_confirmations",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, member_id, confirmer_id",
    toJson: (r) => ({ id: r.id, matchdayId: r.matchday_id, memberId: r.member_id, confirmerId: r.confirmer_id }),
  },
  tournament: {
    table: "tournaments",
    clubColumn: "club_id",
    keyColumn: "club_id",
    columns: "club_id, format, status, rules, registration_closes_at, starts_on, max_teams, min_players, max_players",
    toJson: (r) => ({
      id: r.club_id,
      format: r.format,
      status: r.status,
      rules: rulesOf(String(r.rules)),
      registrationClosesAt: r.registration_closes_at,
      startsOn: r.starts_on,
      maxTeams: r.max_teams,
      minPlayers: r.min_players,
      maxPlayers: r.max_players,
    }),
  },
  team: {
    table: "teams",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, name, short_name, color, captain_member_id, represents_club_id, status, seed, group_label",
    toJson: (r) => ({
      id: r.id,
      name: r.name,
      shortName: r.short_name,
      color: r.color,
      captainMemberId: r.captain_member_id,
      representsClubId: r.represents_club_id,
      status: r.status,
      seed: r.seed,
      groupLabel: r.group_label,
    }),
  },
  teamPlayer: {
    table: "team_players",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, team_id, member_id, shirt, status",
    toJson: (r) => ({ id: r.id, teamId: r.team_id, memberId: r.member_id, shirt: r.shirt, status: r.status }),
  },
  fixture: {
    table: "fixtures",
    clubColumn: "club_id",
    keyColumn: "id",
    columns:
      "id, stage, round, group_label, leg, slot, home_team_id, away_team_id, home_source, away_source, starts_at, place, scorer_member_id, status, home_score, away_score, home_pens, away_pens, walkover_winner, result_by, result_at",
    toJson: (r) => ({
      id: r.id,
      stage: r.stage,
      round: r.round,
      groupLabel: r.group_label,
      leg: r.leg,
      slot: r.slot,
      homeTeamId: r.home_team_id,
      awayTeamId: r.away_team_id,
      homeSource: jsonOrNull(r.home_source),
      awaySource: jsonOrNull(r.away_source),
      startsAt: r.starts_at,
      place: r.place,
      scorerMemberId: r.scorer_member_id,
      status: r.status,
      homeScore: r.home_score,
      awayScore: r.away_score,
      homePens: r.home_pens,
      awayPens: r.away_pens,
      walkoverWinner: r.walkover_winner,
      resultBy: r.result_by,
      resultAt: r.result_at,
    }),
  },
  fixtureEvent: {
    table: "fixture_events",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, fixture_id, team_id, member_id, kind, assist_member_id, minute",
    toJson: (r) => ({
      id: r.id,
      fixtureId: r.fixture_id,
      teamId: r.team_id,
      memberId: r.member_id,
      kind: r.kind,
      assistMemberId: r.assist_member_id,
      minute: r.minute,
    }),
  },
  fixtureLineup: {
    table: "fixture_lineups",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, fixture_id, team_id, member_id",
    toJson: (r) => ({ id: r.id, fixtureId: r.fixture_id, teamId: r.team_id, memberId: r.member_id }),
  },
  award: {
    table: "awards",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, kind, team_id, member_id, value",
    toJson: (r) => ({ id: r.id, kind: r.kind, teamId: r.team_id, memberId: r.member_id, value: r.value }),
  },
  vote: {
    table: "mvp_votes",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, voter_id, voted_for",
    toJson: (r) => ({ id: r.id, matchdayId: r.matchday_id, voterId: r.voter_id, votedFor: r.voted_for }),
  },
};

export const ENTITY_NAMES = Object.keys(ENTITIES) as SyncEntity[];

const TOURNAMENT_ONLY = new Set<SyncEntity>(["tournament", "team", "teamPlayer", "fixture", "fixtureEvent", "fixtureLineup", "award"]);
const GROUP_ONLY = new Set<SyncEntity>(["season", "matchday", "attendance", "report", "confirmation", "vote"]);

/** Las entidades de un servidor según su tipo: la foto completa no pregunta por tablas que no usa. */
export function entitiesFor(kind: string) {
  const skip = kind === "tournament" ? GROUP_ONLY : TOURNAMENT_ONLY;
  return ENTITY_NAMES.filter((e) => !skip.has(e));
}

/** D1 admite como mucho 100 parámetros por sentencia. */
const CHUNK = 90;

/** Las filas actuales de `keys` (o de todo el servidor si `keys` es null). */
export async function readRows(db: D1Database, clubId: string, entity: SyncEntity, keys: string[] | null) {
  const def = ENTITIES[entity];
  const base = `SELECT ${def.columns} FROM ${def.table} WHERE ${def.clubColumn} = ?`;
  if (keys === null) {
    const { results } = await db.prepare(base).bind(clubId).all<Row>();
    return results.map(def.toJson);
  }
  const rows: Record<string, unknown>[] = [];
  for (let i = 0; i < keys.length; i += CHUNK) {
    const chunk = keys.slice(i, i + CHUNK);
    const { results } = await db
      .prepare(`${base} AND ${def.keyColumn} IN (${chunk.map(() => "?").join(", ")})`)
      .bind(clubId, ...chunk)
      .all<Row>();
    rows.push(...results.map(def.toJson));
  }
  return rows;
}
