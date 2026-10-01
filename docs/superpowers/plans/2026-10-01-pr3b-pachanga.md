# PR3b · La pachanga sobre el motor de sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que la app pueda usar el motor de sync del PR3a para todo lo que hace hoy con Firestore: jornadas, asistencia, reportes de goles y asistencias, confirmaciones, MVP y equipos. También añade unir jornadas duplicadas y reglas de cierre que no castigan a quien no tenía señal.

**Architecture:**
- **Migración 0004:** las tablas de la pachanga. Las tablas "por persona" usan un `id` compuesto (`jornada:miembro`), así el pull las lee por clave como al resto.
- **Reglas puras** en `src/rules/matchday.ts`: jugada, acepta intención, cerrada y día local. Sus casos están en `shared-fixtures/matchday-rules.json`; los ejecutan el backend ahora y la app en Dart desde el PR4.
- **Comandos** en `src/commands/{matchdays,attendance,reports,votes}.ts`, con piezas comunes en `src/commands/pachanga.ts`.
- **Borrados en cascada y uniones:** escriben sus `changes` con `INSERT … SELECT`, en el mismo `batch` y sin leer las filas.

**Tech Stack:** el de los PRs anteriores.

**Spec:** `docs/superpowers/specs/2026-10-01-servidores-backend-propio-design.md`. Secciones: §2 (tablas de la pachanga y regla de "cuenta"), §5 (comandos, conflictos, plazo con `clientAt`, jornadas duplicadas) y §6. Además, la spec de jornadas `docs/superpowers/specs/2026-09-14-jornadas-presencia-cierre-design.md` (cierre, presencia real, rechazo definitivo, desempate de MVP), que manda en todo lo que la primera no cambia.

## Alcance de este PR

Entra:
- **Tablas:** `matchdays`, `attendance`, `reports`, `report_confirmations` y `mvp_votes`, como entidades del pull (`matchday`, `attendance`, `report`, `confirmation`, `vote`).
- **Comandos de jornadas:** `matchday.create`, `matchday.update`, `matchday.setStatus`, `matchday.delete` (en cascada), `matchday.merge` y `teams.save`.
- **Comandos de asistencia:** `attendance.setIntent`, `attendance.setPlayed` y `attendance.rollCall`.
- **Comandos de reportes:** `report.upsert`, `report.delete`, `report.loadFor`, `report.confirm`, `report.unconfirm`, `report.decide` y `report.correct`.
- **Comandos de votos:** `vote.cast` y `vote.clear`.
- **Temporadas:** `season.delete` solo si la temporada no tiene jornadas.
- **`shared-fixtures/matchday-rules.json`** y su test en TypeScript.

Queda para PRs siguientes (no implementar aquí):
- **PR4/PR5 (app):**
  - calcular "cuenta / no cuenta" de cada reporte (spec §2) y las estadísticas, en Dart sobre la base local; el servidor guarda los datos crudos;
  - detectar jornadas duplicadas (mismo día local) y proponer unirlas;
  - ejecutar `shared-fixtures/` en Dart.
- **PR6:**
  - notificaciones ("nuevo reporte para confirmar", "editaron un reporte que confirmaste", recordatorios);
  - purga de `changes`;
  - foto completa paginada si un servidor acumula mucho historial.

## Global Constraints

- Todo lo del PR1, el PR2 y el PR3a sigue valiendo. En especial: **toda escritura sobre una entidad sincronizada añade sus `changes` en el mismo `batch`**, y los ids de lo que se crea los pone la app.
- **Las personas se referencian siempre por `members.id`**, nunca por `user_id`. Así un jugador sin cuenta y uno con cuenta funcionan igual.
- **Cerrada = no acepta cambios de nadie.**
  - Está cerrada si la temporada está cerrada, si se canceló o se cerró a mano, o si pasaron `closeAfterHours` desde el inicio y no se reabrió.
  - El plazo se mide con `ctx.clientAt` (la hora del teléfono, acotada). El estado (`closed`, `reopened`…) se lee en el momento de aplicar, así que un cierre manual gana siempre.
  - El staff reabre para corregir.
- **"Ya se jugó" se mide con `ctx.now`.** La intención (Voy / Quizás / No voy) se acepta si `ctx.clientAt` es anterior al final.
- **Reportes:**
  - mandar uno marca "jugué";
  - editar o recargar uno borra sus confirmaciones, su decisión y su corrección;
  - si la decisión es `rejected`, el autor no puede ni editarlo ni borrarlo.
- **Confirmar y votar** exigen presencia real (`played = 1`). El que vota y el votado tienen que haber jugado, y nadie se vota a sí mismo.
- **Ningún handler lee más de 4 veces de D1.** `MAX_HANDLER_READS = 4`, por `matchday.merge`.
- **Rama:** `feature/pachanga`, creada desde `main`. Ya existe y contiene este plan. El PR va contra `main`.

## Review Focus

1. **Reporte hecho sin señal dentro del plazo y subido después.** Se acepta: el plazo usa la hora del teléfono, acotada. Si la jornada se cerró a mano, se rechaza siempre. Tests: Task 2 (reportes y asistencia).
2. **Teléfono con la hora adelantada o atrasada.** No sirve para votar o reportar antes de que termine la jornada ("jugada" usa la hora del servidor), ni para saltarse el plazo (`clientAt` acotado). Tests: Task 2.
3. **Borrar o unir jornadas.** Los demás teléfonos reciben los borrados de todo lo que colgaba: asistencia, reportes, confirmaciones y votos. Si no, quedarían datos huérfanos en las tablas locales. Tests: Tasks 2 y 3.
4. **Unir dos jornadas en las que la misma persona tiene datos en ambas.** Gana lo más reciente, y las confirmaciones van con su reporte, no se mezclan. Test: Task 3.
5. **Jugadores sin cuenta.** Se les pasa lista, se les carga el reporte, se les vota y entran en los equipos, igual que a cualquiera. Tests: Task 2.

---

### Task 1: Esquema, reglas puras y casos compartidos

**Files:**
- Create:
  - `backend/migrations/0004_pachanga.sql`
  - `backend/src/rules/matchday.ts`
  - `shared-fixtures/matchday-rules.json` (en la raíz del repo)
  - `backend/test/shared-fixtures.test.ts`

**Interfaces:**
- Produces:
  - Las tablas de la pachanga.
  - En `src/rules/matchday.ts`:
    - `type MatchdayStatus`;
    - `type MatchdayTimes = { startsAt, durationMinutes, status, seasonClosed }`;
    - `endsAt(md)`, `isPlayed(md, at)`, `acceptsIntent(md, at)`, `isClosed(md, at, closeAfterHours)` y `localDay(at, timezone)`.

- [ ] **Step 1: Escribir el test que falla**

`shared-fixtures/matchday-rules.json`:

```json
{
  "description": "Casos de las reglas de jornada. Los ejecutan backend/test/shared-fixtures.test.ts (TypeScript) y, desde el PR4, la app en Dart. Si cambias una regla, cambia aquí el caso y ambos lados tienen que pasar.",
  "matchday": { "startsAt": "2026-10-04T14:00:00.000Z", "durationMinutes": 120, "status": "scheduled", "seasonClosed": false },
  "cases": [
    { "name": "antes de empezar no se jugó", "fn": "isPlayed", "at": "2026-10-04T13:59:00.000Z", "expected": false },
    { "name": "durante la jornada no se jugó todavía", "fn": "isPlayed", "at": "2026-10-04T15:30:00.000Z", "expected": false },
    { "name": "justo al terminar ya se jugó", "fn": "isPlayed", "at": "2026-10-04T16:00:00.000Z", "expected": true },
    { "name": "una cancelada nunca se jugó", "fn": "isPlayed", "at": "2026-10-05T10:00:00.000Z", "matchday": { "status": "cancelled" }, "expected": false },
    { "name": "la intención se marca hasta que termina", "fn": "acceptsIntent", "at": "2026-10-04T15:59:00.000Z", "expected": true },
    { "name": "al terminar ya no se marca intención", "fn": "acceptsIntent", "at": "2026-10-04T16:00:00.000Z", "expected": false },
    { "name": "en una cancelada no se marca intención", "fn": "acceptsIntent", "at": "2026-10-04T10:00:00.000Z", "matchday": { "status": "cancelled" }, "expected": false },
    { "name": "abierta antes del plazo de cierre", "fn": "isClosed", "at": "2026-10-07T13:59:00.000Z", "closeAfterHours": 72, "expected": false },
    { "name": "cerrada al cumplirse el plazo desde el inicio", "fn": "isClosed", "at": "2026-10-07T14:00:00.000Z", "closeAfterHours": 72, "expected": true },
    { "name": "el plazo es el del servidor (48 h)", "fn": "isClosed", "at": "2026-10-06T14:00:00.000Z", "closeAfterHours": 48, "expected": true },
    { "name": "cerrada a mano: cerrada aunque no haya empezado", "fn": "isClosed", "at": "2026-10-01T10:00:00.000Z", "closeAfterHours": 72, "matchday": { "status": "closed" }, "expected": true },
    { "name": "cancelada: cerrada", "fn": "isClosed", "at": "2026-10-04T15:00:00.000Z", "closeAfterHours": 72, "matchday": { "status": "cancelled" }, "expected": true },
    { "name": "reabierta: abierta aunque haya pasado el plazo", "fn": "isClosed", "at": "2026-11-30T10:00:00.000Z", "closeAfterHours": 72, "matchday": { "status": "reopened" }, "expected": false },
    { "name": "temporada cerrada: cerrada aunque esté reabierta", "fn": "isClosed", "at": "2026-10-04T15:00:00.000Z", "closeAfterHours": 72, "matchday": { "status": "reopened", "seasonClosed": true }, "expected": true },
    { "name": "día local en La Habana (de noche sigue siendo el mismo día)", "fn": "localDay", "at": "2026-10-05T03:30:00.000Z", "timezone": "America/Havana", "expected": "2026-10-04" },
    { "name": "día local en Madrid", "fn": "localDay", "at": "2026-10-04T23:30:00.000Z", "timezone": "Europe/Madrid", "expected": "2026-10-05" }
  ]
}
```

`backend/test/shared-fixtures.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import fixtures from "../../shared-fixtures/matchday-rules.json";
import { acceptsIntent, isClosed, isPlayed, localDay, type MatchdayTimes } from "../src/rules/matchday";

type Case = {
  name: string;
  fn: "isPlayed" | "acceptsIntent" | "isClosed" | "localDay";
  at: string;
  expected: boolean | string;
  matchday?: Partial<MatchdayTimes>;
  closeAfterHours?: number;
  timezone?: string;
};

describe("shared-fixtures/matchday-rules.json (los mismos casos que ejecuta la app en Dart)", () => {
  it.each(fixtures.cases as Case[])("$name", (c) => {
    const md = { ...(fixtures.matchday as MatchdayTimes), ...c.matchday };
    const at = new Date(c.at);
    const result = {
      isPlayed: () => isPlayed(md, at),
      acceptsIntent: () => acceptsIntent(md, at),
      isClosed: () => isClosed(md, at, c.closeAfterHours!),
      localDay: () => localDay(c.at, c.timezone!),
    }[c.fn]();
    expect(result).toBe(c.expected);
  });
});
```

- [ ] **Step 2: Ver que falla**

Run: `cd backend && npx vitest run test/shared-fixtures.test.ts`
Expected: FAIL, no se puede resolver `../src/rules/matchday`.

- [ ] **Step 3: Implementar**

`backend/src/rules/matchday.ts`:

```ts
/**
 * Reglas puras de una jornada (spec §5 y la spec de jornadas del 2026-09-14). Sin I/O: las usa el
 * backend al aplicar comandos, y los mismos casos de `shared-fixtures/matchday-rules.json` los
 * ejecuta la app en Dart para responder igual sin conexión.
 */

export type MatchdayStatus = "scheduled" | "cancelled" | "closed" | "reopened";

export type MatchdayTimes = {
  startsAt: string;
  durationMinutes: number;
  status: MatchdayStatus;
  seasonClosed: boolean;
};

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;

export function endsAt(md: MatchdayTimes) {
  return new Date(Date.parse(md.startsAt) + md.durationMinutes * MINUTE_MS);
}

/** Ya terminó: se pueden cargar goles, confirmar y votar. Una cancelada nunca "se jugó". */
export function isPlayed(md: MatchdayTimes, at: Date) {
  return md.status !== "cancelled" && at.getTime() >= endsAt(md).getTime();
}

/** Todavía no terminó: se puede marcar la intención (Voy / Quizás / No voy). */
export function acceptsIntent(md: MatchdayTimes, at: Date) {
  return md.status !== "cancelled" && at.getTime() < endsAt(md).getTime();
}

/**
 * No acepta cambios: temporada cerrada, cancelada o cerrada a mano; o pasaron `closeAfterHours`
 * desde el inicio, salvo que la hayan reabierto (entonces solo se cierra a mano).
 */
export function isClosed(md: MatchdayTimes, at: Date, closeAfterHours: number) {
  if (md.seasonClosed || md.status === "cancelled" || md.status === "closed") return true;
  if (md.status === "reopened") return false;
  return at.getTime() >= Date.parse(md.startsAt) + closeAfterHours * HOUR_MS;
}

/** Fecha local (AAAA-MM-DD) de un instante en una zona horaria: para detectar jornadas del mismo día. */
export function localDay(at: string, timezone: string) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).format(
    new Date(at),
  );
}
```

`backend/migrations/0004_pachanga.sql`:

```sql
-- La pachanga: jornadas, asistencia, reportes de goles y asistencias, confirmaciones y votos de MVP.
-- Las tablas por persona tienen un `id` compuesto ("jornada:miembro") para que el pull las lea por
-- clave como al resto de entidades. Todas las referencias a personas son `members.id`.

CREATE TABLE matchdays (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  season_id TEXT NOT NULL REFERENCES seasons (id),
  starts_at TEXT NOT NULL,
  duration_minutes INTEGER NOT NULL DEFAULT 120 CHECK (duration_minutes BETWEEN 30 AND 600),
  place TEXT,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'cancelled', 'closed', 'reopened')),
  teams TEXT, -- JSON {"a": [memberId], "b": [memberId]} o NULL
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX matchdays_club ON matchdays (club_id, starts_at);
CREATE INDEX matchdays_season ON matchdays (season_id);

CREATE TABLE attendance (
  id TEXT PRIMARY KEY, -- matchday_id:member_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  member_id TEXT NOT NULL,
  intent TEXT CHECK (intent IN ('yes', 'no', 'maybe')),
  played INTEGER CHECK (played IN (0, 1)),
  played_set_by TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX attendance_matchday ON attendance (matchday_id);

CREATE TABLE reports (
  id TEXT PRIMARY KEY, -- matchday_id:member_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  member_id TEXT NOT NULL,
  goals INTEGER NOT NULL CHECK (goals BETWEEN 0 AND 30),
  assists INTEGER NOT NULL CHECK (assists BETWEEN 0 AND 30),
  note TEXT,
  loaded_by TEXT NOT NULL,
  decision TEXT CHECK (decision IN ('confirmed', 'rejected')),
  corrected_by TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX reports_matchday ON reports (matchday_id);

-- Tabla aparte (no una lista dentro del reporte) para que confirmar sin conexión nunca choque.
CREATE TABLE report_confirmations (
  id TEXT PRIMARY KEY, -- matchday_id:member_id:confirmer_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  member_id TEXT NOT NULL,
  confirmer_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX report_confirmations_matchday ON report_confirmations (matchday_id, member_id);

CREATE TABLE mvp_votes (
  id TEXT PRIMARY KEY, -- matchday_id:voter_id
  club_id TEXT NOT NULL,
  matchday_id TEXT NOT NULL REFERENCES matchdays (id),
  voter_id TEXT NOT NULL,
  voted_for TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK (voter_id <> voted_for)
);
CREATE INDEX mvp_votes_matchday ON mvp_votes (matchday_id);
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos, incluidos los 16 casos compartidos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend/migrations/0004_pachanga.sql backend/src/rules shared-fixtures backend/test/shared-fixtures.test.ts
git commit -m "Backend: tablas de la pachanga, reglas puras de jornada y casos compartidos con la app"
```

---

### Task 2: Comandos de la pachanga

**Files:**
- Create:
  - `backend/src/commands/pachanga.ts`, `backend/src/commands/matchdays.ts`, `backend/src/commands/attendance.ts`
  - `backend/src/commands/reports.ts`, `backend/src/commands/votes.ts`
  - `backend/test/pachanga-helpers.ts`
  - `backend/test/commands-matchdays.test.ts`, `backend/test/commands-attendance.test.ts`, `backend/test/commands-reports.test.ts`
- Modify:
  - `backend/src/http/errors.ts`, `backend/src/sync/changes.ts`, `backend/src/sync/entities.ts`
  - `backend/src/sync/handlers.ts` (reemplazo completo), `backend/src/sync/push.ts`, `backend/src/commands/seasons.ts`
  - `backend/test/commands-seasons.test.ts`, `backend/test/sync-push-limits.test.ts`

**Interfaces:**
- Consumes:
  - las reglas de la Task 1;
  - `command`, `CommandContext`, `upsert`, `remove` y `changeStatement` (PR3a);
  - `canCreateMatchday`, `canEditMatchday`, `canManageMatchday`, `canActForOthers` y `canDecideReports` (PR2).
- Produces:
  - `src/commands/pachanga.ts`: `type Matchday`, `findMatchday(ctx, id)`, `assertOpen(ctx, md)`, `assertPlayed(ctx, md)`, `assertActiveMembers(ctx, ids, field)`, `childChanges(ctx, table, entity, op, where, ...binds)`, `CHILDREN`, `key(...parts)` y los esquemas `matchdayId`, `memberId` y `goalsOrAssists`.
  - `src/commands/attendance.ts`: `playedStatement(ctx, matchday, member, played)`, que también usan los reportes.
  - Todos los comandos de la sección Alcance salvo `matchday.merge` (Task 3).
  - Las entidades `matchday`, `attendance`, `report`, `confirmation` y `vote` en el pull.
  - Los errores `matchdayClosed`, `matchdayNotPlayed`, `matchdayAlreadyPlayed`, `notPresent`, `reportRejected`, `noActiveSeason`, `seasonClosed` y `seasonHasMatchdays`.
  - `test/pachanga-helpers.ts`: `hoursAgo(h)`, `matchday(token, clubId, extra?)`, `played(clubId, matchdayId, ...tokens)`, `squad(clubId)`, `row(table, id)` y `count(table, where?, ...binds)`.

- [ ] **Step 1: Escribir los tests que fallan**

`backend/test/pachanga-helpers.ts`:

```ts
import { env } from "cloudflare:workers";
import { expect } from "vitest";
import { addGuest, addMember } from "./fixtures";
import { apply, cmd } from "./sync-helpers";

export const hoursAgo = (h: number) => new Date(Date.now() - h * 3600_000).toISOString();

/**
 * Crea una jornada con un comando. Por defecto empezó hace 3 h y duró 2 (ya se jugó, sigue abierta).
 * `startsAt` en el futuro = todavía no se jugó.
 */
export async function matchday(token: string, clubId: string, extra: Record<string, unknown> = {}) {
  const id = crypto.randomUUID();
  await apply(token, cmd(clubId, "matchday.create", { id, startsAt: hoursAgo(3), durationMinutes: 120, ...extra }));
  return id;
}

/** Marca "jugué" a varios con el comando del propio jugador. */
export async function played(clubId: string, matchdayId: string, ...tokens: string[]) {
  for (const token of tokens) await apply(token, cmd(clubId, "attendance.setPlayed", { matchdayId, played: true }));
}

/** Un grupo típico: dueño, un admin, un anotador, dos jugadores y uno sin cuenta. */
export async function squad(clubId: string) {
  return {
    admin: await addMember(clubId, "jefe", "admin"),
    scorer: await addMember(clubId, "anotador", "scorer"),
    raul: await addMember(clubId, "raul", "player"),
    pepe: await addMember(clubId, "pepe", "player"),
    guest: await addGuest(clubId, "Yoandry"),
  };
}

export async function row(table: string, id: string) {
  return env.DB.prepare(`SELECT * FROM ${table} WHERE id = ?`).bind(id).first();
}

export async function count(table: string, where = "1", ...binds: unknown[]) {
  const r = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${where}`).bind(...binds).first<{ n: number }>();
  expect(r).not.toBeNull();
  return r!.n;
}
```

`backend/test/commands-matchdays.test.ts`:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, auditActions } from "./fixtures";
import { count, hoursAgo, matchday, played, row, squad } from "./pachanga-helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

describe("matchday.create", () => {
  it("cualquier miembro la crea en la temporada activa, con 120 min por defecto", async () => {
    const { clubId } = await activeClub();
    const { raul } = await squad(clubId);
    const id = crypto.randomUUID();
    await apply(raul.token, cmd(clubId, "matchday.create", { id, startsAt: "2026-10-10T14:00:00-04:00", place: "Cancha de 23" }));
    const active = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ? AND is_active = 1").bind(clubId).first<{ id: string }>();
    expect(await row("matchdays", id)).toMatchObject({
      season_id: active!.id,
      starts_at: "2026-10-10T18:00:00.000Z",
      duration_minutes: 120,
      place: "Cancha de 23",
      status: "scheduled",
      created_by: raul.memberId,
      teams: null,
    });
  });

  it("si el servidor dice 'solo staff', un player no puede", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    await apply(owner.token, cmd(clubId, "club.updateSettings", { matchdayCreators: "staff" }));
    expect(await rejection(raul.token, cmd(clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: hoursAgo(-24) }))).toBe("forbidden");
  });

  it("sin temporada activa, o en una cerrada, no se crea", async () => {
    const { clubId, owner } = await activeClub();
    const season = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(clubId).first<{ id: string }>();
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: season!.id, closed: true }));
    const create = (extra = {}) => cmd(clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: hoursAgo(-24), ...extra });
    expect(await rejection(owner.token, create())).toBe("no_active_season");
    expect(await rejection(owner.token, create({ seasonId: season!.id }))).toBe("season_closed");
  });

  it("valida fecha y duración (30 a 600 min)", async () => {
    const { clubId, owner } = await activeClub();
    const create = (extra: Record<string, unknown>) => cmd(clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: hoursAgo(-24), ...extra });
    expect(await rejection(owner.token, create({ startsAt: "sábado" }))).toBe("invalid_input");
    expect(await rejection(owner.token, create({ durationMinutes: 20 }))).toBe("invalid_input");
    expect(await rejection(owner.token, create({ durationMinutes: 601 }))).toBe("invalid_input");
  });
});

describe("matchday.update / setStatus / delete", () => {
  it("el player que la creó la edita; otro player no; null borra el lugar", async () => {
    const { clubId } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(raul.token, clubId, { place: "Cancha vieja" });
    await apply(raul.token, cmd(clubId, "matchday.update", { matchdayId: id, place: null, notes: "Traer pelota" }));
    expect(await row("matchdays", id)).toMatchObject({ place: null, notes: "Traer pelota" });
    expect(await rejection(pepe.token, cmd(clubId, "matchday.update", { matchdayId: id, notes: "x" }))).toBe("forbidden");
  });

  it("el creador player la cancela si nadie más cargó datos; si ya hay datos de otros, solo el staff", async () => {
    const { clubId } = await activeClub();
    const { raul, pepe, scorer } = await squad(clubId);
    const id = await matchday(raul.token, clubId);
    await apply(raul.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "cancelled" }));
    await apply(raul.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "scheduled" }));
    await played(clubId, id, pepe.token);
    expect(await rejection(raul.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "cancelled" }))).toBe("forbidden");
    await apply(scorer.token, cmd(clubId, "matchday.setStatus", { matchdayId: id, status: "closed" }));
    expect(await auditActions(clubId)).toContain("matchday.setStatus");
  });

  it("borrar se lleva la asistencia, los reportes, las confirmaciones y los votos, y el pull los manda como borrados", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 2, assists: 1 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(pepe.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }));
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;

    await apply(owner.token, cmd(clubId, "matchday.delete", { matchdayId: id }));
    for (const table of ["matchdays", "attendance", "reports", "report_confirmations", "mvp_votes"]) {
      expect(await count(table), table).toBe(0);
    }
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.deletes.matchday).toEqual([id]);
    expect(next.deletes.attendance).toHaveLength(2);
    expect(next.deletes.report).toEqual([`${id}:${raul.memberId}`]);
    expect(next.deletes.confirmation).toEqual([`${id}:${raul.memberId}:${pepe.memberId}`]);
    expect(next.deletes.vote).toEqual([`${id}:${pepe.memberId}`]);
  });
});

describe("teams.save", () => {
  it("el staff guarda equipos de miembros del servidor (también sin cuenta); null los quita", async () => {
    const { clubId } = await activeClub();
    const { scorer, raul, pepe, guest } = await squad(clubId);
    const id = await matchday(scorer.token, clubId, { startsAt: hoursAgo(-24) });
    await apply(scorer.token, cmd(clubId, "teams.save", { matchdayId: id, teams: { a: [raul.memberId], b: [pepe.memberId, guest] } }));
    expect(JSON.parse(String((await row("matchdays", id))!.teams))).toEqual({ a: [raul.memberId], b: [pepe.memberId, guest] });
    await apply(scorer.token, cmd(clubId, "teams.save", { matchdayId: id, teams: null }));
    expect((await row("matchdays", id))!.teams).toBeNull();
  });

  it("rechaza ids que no son miembros activos, y un player no puede", async () => {
    const { clubId } = await activeClub();
    const { scorer, raul } = await squad(clubId);
    const id = await matchday(scorer.token, clubId, { startsAt: hoursAgo(-24) });
    expect(await rejection(scorer.token, cmd(clubId, "teams.save", { matchdayId: id, teams: { a: ["inventado"], b: [] } }))).toBe("invalid_input");
    expect(await rejection(raul.token, cmd(clubId, "teams.save", { matchdayId: id, teams: { a: [], b: [] } }))).toBe("forbidden");
  });
});

describe("pull de la pachanga", () => {
  it("la foto trae jornadas, asistencia, reportes, confirmaciones y votos con su forma", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 3, assists: 0, note: "Hat-trick" }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(pepe.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }));
    const c = (await pullAll(pepe.token)).clubs[clubId]!;
    expect(c.upserts.matchday).toMatchObject([{ id, durationMinutes: 120, status: "scheduled", teams: null }]);
    expect(c.upserts.report).toMatchObject([{ memberId: raul.memberId, goals: 3, assists: 0, note: "Hat-trick", decision: null, loadedBy: raul.memberId }]);
    expect(c.upserts.attendance).toEqual(
      expect.arrayContaining([expect.objectContaining({ memberId: raul.memberId, played: true, intent: null })]),
    );
    expect(c.upserts.confirmation).toEqual([{ id: `${id}:${raul.memberId}:${pepe.memberId}`, matchdayId: id, memberId: raul.memberId, confirmerId: pepe.memberId }]);
    expect(c.upserts.vote).toEqual([{ id: `${id}:${pepe.memberId}`, matchdayId: id, voterId: pepe.memberId, votedFor: raul.memberId }]);
  });
});
```

`backend/test/commands-attendance.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { activeClub } from "./fixtures";
import { hoursAgo, matchday, row, squad } from "./pachanga-helpers";
import { apply, cmd, rejection } from "./sync-helpers";

describe("asistencia", () => {
  it("antes de jugarse: Voy / Quizás / No voy, y se puede quitar con null", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(-48) });
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }));
    expect(await row("attendance", `${id}:${raul.memberId}`)).toMatchObject({ intent: "yes", played: null });
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: null }));
    expect(await row("attendance", `${id}:${raul.memberId}`)).toMatchObject({ intent: null });
  });

  it("ya jugada, la intención no se cambia; pero si se marcó antes sin señal y llega tarde, vale", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId); // empezó hace 3 h, terminó hace 1
    expect(await rejection(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }))).toBe("matchday_already_played");
    await apply(pepe.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }, { clientAt: hoursAgo(5) }));
  });

  it("'Jugué' solo cuando terminó, con la hora del servidor", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const future = await matchday(owner.token, clubId, { startsAt: hoursAgo(-1) });
    expect(await rejection(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: future, played: true }))).toBe("matchday_not_played");
    const past = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: past, played: true }));
    expect(await row("attendance", `${past}:${raul.memberId}`)).toMatchObject({ played: 1, played_set_by: raul.memberId });
  });

  it("pasar lista: el staff marca a todos, incluido el que no tiene cuenta, sin tocar su intención", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, pepe, guest } = await squad(clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(-1), durationMinutes: 30 });
    await apply(raul.token, cmd(clubId, "attendance.setIntent", { matchdayId: id, intent: "yes" }));
    const later = await matchday(owner.token, clubId);
    await apply(
      scorer.token,
      cmd(clubId, "attendance.rollCall", {
        matchdayId: later,
        entries: [
          { memberId: raul.memberId, played: true },
          { memberId: pepe.memberId, played: false },
          { memberId: guest, played: true },
        ],
      }),
    );
    expect(await row("attendance", `${later}:${guest}`)).toMatchObject({ played: 1, played_set_by: scorer.memberId });
    expect(await row("attendance", `${later}:${pepe.memberId}`)).toMatchObject({ played: 0 });
    expect(await rejection(raul.token, cmd(clubId, "attendance.rollCall", { matchdayId: later, entries: [{ memberId: raul.memberId, played: true }] }))).toBe("forbidden");
  });

  it("cerrada no acepta nada: a mano siempre; por plazo, según la hora del teléfono", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const old = await matchday(owner.token, clubId, { startsAt: hoursAgo(80) }); // más de 72 h
    expect(await rejection(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: old, played: true }))).toBe("matchday_closed");
    // Lo marcó sin señal a las 70 h (dentro del plazo) y llega ahora: vale.
    await apply(pepe.token, cmd(clubId, "attendance.setPlayed", { matchdayId: old, played: true }, { clientAt: hoursAgo(10) }));

    const fresh = await matchday(owner.token, clubId);
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: fresh, status: "closed" }));
    expect(await rejection(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: fresh, played: true }, { clientAt: hoursAgo(1) }))).toBe(
      "matchday_closed",
    );
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: old, status: "reopened" }));
    await apply(raul.token, cmd(clubId, "attendance.setPlayed", { matchdayId: old, played: true }));
  });

  it("una jornada de otro servidor no existe", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul2", "Otro");
    const id = await matchday(b.owner.token, b.clubId);
    expect(await rejection(a.owner.token, cmd(a.clubId, "attendance.setPlayed", { matchdayId: id, played: true }))).toBe("not_found");
  });
});
```

`backend/test/commands-reports.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { activeClub, auditActions } from "./fixtures";
import { count, hoursAgo, matchday, played, row, squad } from "./pachanga-helpers";
import { apply, cmd, rejection } from "./sync-helpers";

describe("reportes", () => {
  it("mi reporte cuenta como 'jugué'; antes de jugarse no se puede", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const future = await matchday(owner.token, clubId, { startsAt: hoursAgo(-2) });
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: future, goals: 1, assists: 0 }))).toBe("matchday_not_played");
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 2, assists: 1, note: "Golazo" }));
    expect(await row("reports", `${id}:${raul.memberId}`)).toMatchObject({ goals: 2, assists: 1, note: "Golazo", loaded_by: raul.memberId, decision: null });
    expect(await row("attendance", `${id}:${raul.memberId}`)).toMatchObject({ played: 1 });
  });

  it("valida 0 a 30 goles y asistencias", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 31, assists: 0 }))).toBe("invalid_input");
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: -1, assists: 0 }))).toBe("invalid_input");
  });

  it("confirman los compañeros que jugaron; uno mismo no; confirmar dos veces no duplica", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    expect(await rejection(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }))).toBe("not_present");
    await played(clubId, id, pepe.token);
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    expect(await count("report_confirmations")).toBe(1);
    expect(await rejection(raul.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }))).toBe("forbidden");
    expect(await rejection(admin.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }))).toBe("not_present");
    await apply(pepe.token, cmd(clubId, "report.unconfirm", { matchdayId: id, memberId: raul.memberId }));
    expect(await count("report_confirmations")).toBe(0);
  });

  it("editar mi reporte lo vuelve pendiente: se van las confirmaciones y la decisión", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: id, memberId: raul.memberId, decision: "confirmed" }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 4, assists: 0 }));
    expect(await row("reports", `${id}:${raul.memberId}`)).toMatchObject({ goals: 4, decision: null });
    expect(await count("report_confirmations")).toBe(0);
  });

  it("rechazo definitivo: el autor ya no lo edita ni lo borra; el admin puede quitar la decisión", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 9, assists: 0 }));
    await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: id, memberId: raul.memberId, decision: "rejected" }));
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 8, assists: 0 }))).toBe("report_rejected");
    expect(await rejection(raul.token, cmd(clubId, "report.delete", { matchdayId: id }))).toBe("report_rejected");
    await apply(admin.token, cmd(clubId, "report.decide", { matchdayId: id, memberId: raul.memberId, decision: null }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    expect(await auditActions(clubId)).toContain("report.decide");
  });

  it("corregir: queda confirmado y marcado; solo owner o admin", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, scorer, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 5, assists: 0 }));
    expect(await rejection(scorer.token, cmd(clubId, "report.correct", { matchdayId: id, memberId: raul.memberId, goals: 2, assists: 1 }))).toBe(
      "forbidden",
    );
    await apply(admin.token, cmd(clubId, "report.correct", { matchdayId: id, memberId: raul.memberId, goals: 2, assists: 1 }));
    expect(await row("reports", `${id}:${raul.memberId}`)).toMatchObject({ goals: 2, assists: 1, decision: "confirmed", corrected_by: admin.memberId });
  });

  it("el staff carga el reporte de un sin cuenta (y queda como presente)", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, guest } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await apply(scorer.token, cmd(clubId, "report.loadFor", { matchdayId: id, memberId: guest, goals: 1, assists: 2 }));
    expect(await row("reports", `${id}:${guest}`)).toMatchObject({ goals: 1, assists: 2, loaded_by: scorer.memberId });
    expect(await row("attendance", `${id}:${guest}`)).toMatchObject({ played: 1 });
    expect(await rejection(raul.token, cmd(clubId, "report.loadFor", { matchdayId: id, memberId: guest, goals: 1, assists: 0 }))).toBe("forbidden");
    expect(await auditActions(clubId)).toContain("report.loadFor");
  });

  it("borrar mi reporte se lleva sus confirmaciones", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, pepe.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 0 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: id, memberId: raul.memberId }));
    await apply(raul.token, cmd(clubId, "report.delete", { matchdayId: id }));
    expect(await count("reports")).toBe(0);
    expect(await count("report_confirmations")).toBe(0);
  });

  it("reportar hecho a tiempo sin señal (a las 70 h) y subido a las 80 h: se acepta", async () => {
    const { clubId, owner } = await activeClub();
    const { raul } = await squad(clubId);
    const id = await matchday(owner.token, clubId, { startsAt: hoursAgo(80) });
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 1, assists: 1 }, { clientAt: hoursAgo(10) }));
    expect(await rejection(raul.token, cmd(clubId, "report.upsert", { matchdayId: id, goals: 2, assists: 1 }))).toBe("matchday_closed");
  });
});

describe("votos de MVP", () => {
  it("votan los que jugaron por otro que jugó (también sin cuenta); cambiar el voto lo reemplaza", async () => {
    const { clubId, owner } = await activeClub();
    const { scorer, raul, pepe, guest } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token, pepe.token);
    await apply(scorer.token, cmd(clubId, "attendance.rollCall", { matchdayId: id, entries: [{ memberId: guest, played: true }] }));
    await apply(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: pepe.memberId }));
    await apply(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: guest }));
    expect(await row("mvp_votes", `${id}:${raul.memberId}`)).toMatchObject({ voted_for: guest });
    expect(await count("mvp_votes")).toBe(1);
    await apply(raul.token, cmd(clubId, "vote.clear", { matchdayId: id }));
    expect(await count("mvp_votes")).toBe(0);
  });

  it("no a uno mismo, ni si alguno de los dos no jugó, ni antes de jugarse", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const id = await matchday(owner.token, clubId);
    await played(clubId, id, raul.token);
    expect(await rejection(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }))).toBe("invalid_input");
    expect(await rejection(raul.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: pepe.memberId }))).toBe("not_present");
    expect(await rejection(admin.token, cmd(clubId, "vote.cast", { matchdayId: id, votedFor: raul.memberId }))).toBe("not_present");
    const future = await matchday(owner.token, clubId, { startsAt: hoursAgo(-3) });
    expect(await rejection(raul.token, cmd(clubId, "vote.cast", { matchdayId: future, votedFor: pepe.memberId }))).toBe("matchday_not_played");
  });
});
```

Reemplaza `backend/test/commands-seasons.test.ts` por (añade "una temporada con jornadas no se borra"):

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember, auditActions } from "./fixtures";
import { apply, cmd, rejection } from "./sync-helpers";

async function seasons(clubId: string) {
  const { results } = await env.DB.prepare(
    "SELECT name, start_date, is_active, is_closed FROM seasons WHERE club_id = ? ORDER BY start_date",
  )
    .bind(clubId)
    .all();
  return results;
}

const year = String(new Date().getFullYear());

describe("temporadas", () => {
  it("al aprobar el servidor ya tiene la temporada del año en curso, activa", async () => {
    const { clubId } = await activeClub();
    expect(await seasons(clubId)).toEqual([{ name: year, start_date: `${year}-01-01`, is_active: 1, is_closed: 0 }]);
  });

  it("crear una nueva activa desactiva la anterior (solo una activa)", async () => {
    const { clubId, owner } = await activeClub();
    await apply(owner.token, cmd(clubId, "season.create", { id: crypto.randomUUID(), name: "Apertura", startDate: "2099-01-01", activate: true }));
    expect((await seasons(clubId)).map((s) => [s.name, s.is_active])).toEqual([
      [year, 0],
      ["Apertura", 1],
    ]);
  });

  it("activar, renombrar y cambiar la fecha", async () => {
    const { clubId, owner } = await activeClub();
    const id = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "season.create", { id, name: "Clausura", startDate: "2099-06-01" }));
    await apply(owner.token, cmd(clubId, "season.activate", { seasonId: id }));
    await apply(owner.token, cmd(clubId, "season.update", { seasonId: id, name: "Clausura 99", startDate: "2099-07-01" }));
    expect((await seasons(clubId)).at(-1)).toEqual({ name: "Clausura 99", start_date: "2099-07-01", is_active: 1, is_closed: 0 });
  });

  it("cerrar la activa la desactiva; una cerrada no se puede activar hasta reabrirla", async () => {
    const { clubId, owner } = await activeClub();
    const current = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(clubId).first<{ id: string }>();
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: current!.id, closed: true }));
    expect((await seasons(clubId))[0]).toMatchObject({ is_active: 0, is_closed: 1 });
    expect(await rejection(owner.token, cmd(clubId, "season.activate", { seasonId: current!.id }))).toBe("invalid_state");
    await apply(owner.token, cmd(clubId, "season.setClosed", { seasonId: current!.id, closed: false }));
    await apply(owner.token, cmd(clubId, "season.activate", { seasonId: current!.id }));
    expect((await seasons(clubId))[0]).toMatchObject({ is_active: 1, is_closed: 0 });
  });

  it("borrar queda auditado", async () => {
    const { clubId, owner } = await activeClub();
    const id = crypto.randomUUID();
    await apply(owner.token, cmd(clubId, "season.create", { id, name: "Prueba", startDate: "2099-01-01" }));
    await apply(owner.token, cmd(clubId, "season.delete", { seasonId: id }));
    expect(await seasons(clubId)).toHaveLength(1);
    expect(await auditActions(clubId)).toContain("season.delete");
  });

  it("una temporada con jornadas no se borra", async () => {
    const { clubId, owner } = await activeClub();
    const season = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(clubId).first<{ id: string }>();
    await apply(owner.token, cmd(clubId, "matchday.create", { id: crypto.randomUUID(), startsAt: "2099-01-01T10:00:00Z" }));
    expect(await rejection(owner.token, cmd(clubId, "season.delete", { seasonId: season!.id }))).toBe("season_has_matchdays");
  });

  it("solo owner y admin; fecha en formato AAAA-MM-DD; la de otro servidor no existe", async () => {
    const { clubId, owner } = await activeClub();
    const scorer = await addMember(clubId, "anotador", "scorer");
    const create = (startDate: string) => cmd(clubId, "season.create", { id: crypto.randomUUID(), name: "X", startDate });
    expect(await rejection(scorer.token, create("2099-01-01"))).toBe("forbidden");
    expect(await rejection(owner.token, create("01/01/2099"))).toBe("invalid_input");
    expect(await rejection(owner.token, create("2099-02-30"))).toBe("invalid_input");
    const other = await activeClub("raul", "Otro");
    const foreign = await env.DB.prepare("SELECT id FROM seasons WHERE club_id = ?").bind(other.clubId).first<{ id: string }>();
    expect(await rejection(owner.token, cmd(clubId, "season.delete", { seasonId: foreign!.id }))).toBe("not_found");
  });
});
```

En `backend/test/sync-push-limits.test.ts`, el ejemplo de tipo desconocido deja de ser `matchday.create`, que ahora existe. Cambia `cmd(clubId, "matchday.create", {})` por `cmd(clubId, "matchday.teleport", {})`.

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/commands-matchdays.test.ts test/commands-attendance.test.ts test/commands-reports.test.ts test/commands-seasons.test.ts`
Expected: FAIL. `matchday.create` vuelve `deferred` con `unknown_command`, así que `matchday()` falla en su `apply`.

- [ ] **Step 3: Implementar**

En `backend/src/http/errors.ts`, añade antes de `ownerCannotLeave`:

```ts
  matchdayClosed: () => new ApiError(409, "matchday_closed", "La jornada está cerrada: ya no acepta cambios"),
  matchdayNotPlayed: () => new ApiError(409, "matchday_not_played", "La jornada todavía no se jugó"),
  matchdayAlreadyPlayed: () =>
    new ApiError(409, "matchday_already_played", "La jornada ya se jugó: marca si jugaste o no"),
  notPresent: () => new ApiError(409, "not_present", "Solo pueden hacer esto los que jugaron esa jornada"),
  reportRejected: () =>
    new ApiError(409, "report_rejected", "El admin rechazó este reporte: ya no se puede cambiar"),
  noActiveSeason: () => new ApiError(409, "no_active_season", "No hay temporada activa: crea o activa una"),
  seasonClosed: () => new ApiError(409, "season_closed", "Esa temporada está cerrada"),
  seasonHasMatchdays: () =>
    new ApiError(409, "season_has_matchdays", "La temporada tiene jornadas: muévelas o bórralas antes"),
```

Reemplaza `backend/src/sync/changes.ts` por:

```ts
/** Entidades que viajan en el pull. */
export type SyncEntity = "club" | "member" | "season" | "matchday" | "attendance" | "report" | "confirmation" | "vote";

export type Touch = { entity: SyncEntity; key: string; op: "upsert" | "delete" };

/** Una fila de `changes`, para meterla en el mismo `batch` que la escritura. */
export function changeStatement(db: D1Database, clubId: string, touch: Touch, now: Date) {
  return db
    .prepare("INSERT INTO changes (club_id, entity, entity_key, op, at) VALUES (?, ?, ?, ?, ?)")
    .bind(clubId, touch.entity, touch.key, touch.op, now.toISOString());
}

export const upsert = (entity: SyncEntity, key: string): Touch => ({ entity, key, op: "upsert" });
export const remove = (entity: SyncEntity, key: string): Touch => ({ entity, key, op: "delete" });
```

Reemplaza `backend/src/sync/entities.ts` por:

```ts
import { DEFAULT_SETTINGS } from "../clubs/model";
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

export const ENTITIES: Record<SyncEntity, EntityDef> = {
  club: {
    table: "clubs",
    clubColumn: "id",
    keyColumn: "id",
    columns: "id, name, description, status, settings",
    toJson: (r) => ({
      id: r.id,
      name: r.name,
      description: r.description,
      status: r.status,
      settings: { ...DEFAULT_SETTINGS, ...JSON.parse(String(r.settings)) },
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
  vote: {
    table: "mvp_votes",
    clubColumn: "club_id",
    keyColumn: "id",
    columns: "id, matchday_id, voter_id, voted_for",
    toJson: (r) => ({ id: r.id, matchdayId: r.matchday_id, voterId: r.voter_id, votedFor: r.voted_for }),
  },
};

export const ENTITY_NAMES = Object.keys(ENTITIES) as SyncEntity[];

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
```

En `backend/src/sync/push.ts`, deja el comentario y la constante así:

```ts
/** Lo que puede costar un comando como mucho: membresía (2, si no está en caché), lecturas del handler (≤4, unir jornadas), batch y una relectura si choca (2). */
const MEMBERSHIP_QUERIES = 2;
const MAX_HANDLER_READS = 4;
```

Reemplaza `backend/src/commands/seasons.ts` por. `deleteSeason` comprueba antes que no haya jornadas:

```ts
import { z } from "zod";
import { canManageSeasons } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert, type Touch } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";

const name = z.string().trim().min(1, { error: "Escribe un nombre" }).max(40);
const startDate = z.iso.date({ error: "Fecha no válida (AAAA-MM-DD)" });
const seasonId = z.string().min(1).max(64);

type SeasonRow = { id: string; is_active: number; is_closed: number };

async function findSeason(ctx: CommandContext, id: string) {
  const row = await ctx.db
    .prepare("SELECT id, is_active, is_closed FROM seasons WHERE id = ? AND club_id = ?")
    .bind(id, ctx.club.id)
    .first<SeasonRow>();
  if (!row) throw errors.notFound();
  return row;
}

function assertCanManage(ctx: CommandContext) {
  if (!canManageSeasons(ctx.member.role)) throw errors.forbidden();
}

/** Desactiva la temporada activa (si hay otra) antes de activar `newActiveId`. */
async function deactivateCurrent(ctx: CommandContext, newActiveId: string) {
  const current = await ctx.db
    .prepare("SELECT id FROM seasons WHERE club_id = ? AND is_active = 1 AND id <> ?")
    .bind(ctx.club.id, newActiveId)
    .first<{ id: string }>();
  const statements = current
    ? [ctx.db.prepare("UPDATE seasons SET is_active = 0, updated_at = ? WHERE id = ?").bind(ctx.now.toISOString(), current.id)]
    : [];
  const touched: Touch[] = current ? [upsert("season", current.id)] : [];
  return { statements, touched };
}

export const createSeason = command(
  z.object({ id: z.uuid(), name, startDate, activate: z.boolean().default(false) }),
  async (ctx, p) => {
    assertCanManage(ctx);
    const off = p.activate ? await deactivateCurrent(ctx, p.id) : { statements: [], touched: [] };
    const at = ctx.now.toISOString();
    return {
      statements: [
        ...off.statements,
        ctx.db
          .prepare(
            "INSERT INTO seasons (id, club_id, name, start_date, is_active, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          )
          .bind(p.id, ctx.club.id, p.name, p.startDate, p.activate ? 1 : 0, at, at),
      ],
      touched: [...off.touched, upsert("season", p.id)],
    };
  },
);

export const updateSeason = command(
  z
    .object({ seasonId, name: name.optional(), startDate: startDate.optional() })
    .refine((p) => p.name !== undefined || p.startDate !== undefined, { error: "Nada que cambiar" }),
  async (ctx, p) => {
    assertCanManage(ctx);
    const s = await findSeason(ctx, p.seasonId);
    return {
      statements: [
        ctx.db
          .prepare(
            "UPDATE seasons SET name = COALESCE(?, name), start_date = COALESCE(?, start_date), updated_at = ? WHERE id = ?",
          )
          .bind(p.name ?? null, p.startDate ?? null, ctx.now.toISOString(), s.id),
      ],
      touched: [upsert("season", s.id)],
    };
  },
);

export const activateSeason = command(z.object({ seasonId }), async (ctx, p) => {
  assertCanManage(ctx);
  const s = await findSeason(ctx, p.seasonId);
  if (s.is_closed === 1) throw errors.invalidState("Una temporada cerrada no puede ser la activa");
  const off = await deactivateCurrent(ctx, s.id);
  return {
    statements: [
      ...off.statements,
      ctx.db.prepare("UPDATE seasons SET is_active = 1, updated_at = ? WHERE id = ?").bind(ctx.now.toISOString(), s.id),
    ],
    touched: [...off.touched, upsert("season", s.id)],
  };
});

/** Cerrar deja de ser la activa (una cerrada no puede serlo). Reabrir no la vuelve a activar. */
export const setSeasonClosed = command(z.object({ seasonId, closed: z.boolean() }), async (ctx, p) => {
  assertCanManage(ctx);
  const s = await findSeason(ctx, p.seasonId);
  return {
    statements: [
      ctx.db
        .prepare(
          `UPDATE seasons SET is_closed = ?, is_active = CASE WHEN ? = 1 THEN 0 ELSE is_active END, updated_at = ?
            WHERE id = ?`,
        )
        .bind(p.closed ? 1 : 0, p.closed ? 1 : 0, ctx.now.toISOString(), s.id),
    ],
    touched: [upsert("season", s.id)],
  };
});

/** Solo si no tiene jornadas (si no, primero hay que moverlas o borrarlas). */
export const deleteSeason = command(z.object({ seasonId }), async (ctx, p) => {
  assertCanManage(ctx);
  const s = await findSeason(ctx, p.seasonId);
  const used = await ctx.db.prepare("SELECT 1 FROM matchdays WHERE season_id = ? LIMIT 1").bind(s.id).first();
  if (used) throw errors.seasonHasMatchdays();
  return {
    statements: [ctx.db.prepare("DELETE FROM seasons WHERE id = ?").bind(s.id)],
    touched: [remove("season", s.id)],
    audit: [{ action: "season.delete", entity: "season", entityKey: s.id }],
  };
});
```

`backend/src/commands/pachanga.ts`:

```ts
import { z } from "zod";
import { errors } from "../http/errors";
import { isClosed, isPlayed, type MatchdayStatus } from "../rules/matchday";
import type { SyncEntity } from "../sync/changes";
import type { CommandContext } from "../sync/command";

/** Lo que los comandos necesitan saber de una jornada (una sola consulta, con su temporada). */
export type Matchday = {
  id: string;
  seasonId: string;
  startsAt: string;
  durationMinutes: number;
  status: MatchdayStatus;
  createdBy: string;
  seasonClosed: boolean;
};

export const matchdayId = z.string().min(1).max(64);
export const memberId = z.string().min(1).max(64);
export const goalsOrAssists = z.number().int().min(0).max(30);

export const key = (...parts: string[]) => parts.join(":");

export async function findMatchday(ctx: CommandContext, id: string): Promise<Matchday> {
  const row = await ctx.db
    .prepare(
      `SELECT md.id, md.season_id, md.starts_at, md.duration_minutes, md.status, md.created_by, s.is_closed
         FROM matchdays md JOIN seasons s ON s.id = md.season_id
        WHERE md.id = ? AND md.club_id = ?`,
    )
    .bind(id, ctx.club.id)
    .first<{
      id: string;
      season_id: string;
      starts_at: string;
      duration_minutes: number;
      status: MatchdayStatus;
      created_by: string;
      is_closed: number;
    }>();
  if (!row) throw errors.notFound();
  return {
    id: row.id,
    seasonId: row.season_id,
    startsAt: row.starts_at,
    durationMinutes: row.duration_minutes,
    status: row.status,
    createdBy: row.created_by,
    seasonClosed: row.is_closed === 1,
  };
}

/**
 * Cerrada = no acepta cambios de nadie (el staff la reabre para corregir). El plazo se mide con la
 * hora del teléfono (acotada): un reporte hecho a tiempo sin señal no se pierde. Un cierre a mano
 * se ve en el estado actual, así que gana siempre.
 */
export function assertOpen(ctx: CommandContext, md: Matchday) {
  if (isClosed(md, ctx.clientAt, ctx.club.settings.closeAfterHours)) throw errors.matchdayClosed();
}

/** "Ya se jugó" con la hora del servidor: si terminó de verdad, vale aunque el teléfono se adelantara. */
export function assertPlayed(ctx: CommandContext, md: Matchday) {
  if (!isPlayed(md, ctx.now)) throw errors.matchdayNotPlayed();
}

/** Miembros activos de este servidor (con o sin cuenta). Lanza 400 si alguno no lo es. */
export async function assertActiveMembers(ctx: CommandContext, ids: string[], field: string) {
  const unique = [...new Set(ids)];
  if (unique.length === 0) return;
  const { results } = await ctx.db
    .prepare(
      `SELECT id FROM members WHERE club_id = ? AND status = 'active' AND id IN (${unique.map(() => "?").join(", ")})`,
    )
    .bind(ctx.club.id, ...unique)
    .all<{ id: string }>();
  if (results.length !== unique.length) {
    throw errors.invalidInput({ [field]: ["Alguno no es miembro activo de este servidor"] });
  }
}

/**
 * Filas de `changes` para todo lo que cuelga de una jornada en `table`, calculadas en SQL (sin leer
 * las filas). Van en el batch antes de borrarlas o moverlas.
 */
export function childChanges(
  ctx: CommandContext,
  table: string,
  entity: SyncEntity,
  op: "upsert" | "delete",
  where: string,
  ...binds: unknown[]
) {
  return ctx.db
    .prepare(`INSERT INTO changes (club_id, entity, entity_key, op, at) SELECT club_id, ?, id, ?, ? FROM ${table} WHERE ${where}`)
    .bind(entity, op, ctx.now.toISOString(), ...binds);
}

/** Las tablas que cuelgan de una jornada, con su entidad de sync. */
export const CHILDREN: { table: string; entity: SyncEntity }[] = [
  { table: "report_confirmations", entity: "confirmation" },
  { table: "mvp_votes", entity: "vote" },
  { table: "reports", entity: "report" },
  { table: "attendance", entity: "attendance" },
];
```

`backend/src/commands/attendance.ts`:

```ts
import { z } from "zod";
import { canActForOthers } from "../authz";
import { errors } from "../http/errors";
import { acceptsIntent } from "../rules/matchday";
import { upsert } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertActiveMembers, assertOpen, assertPlayed, findMatchday, key, matchdayId, memberId } from "./pachanga";

/** Escribe `played` de un miembro conservando su intención. */
export function playedStatement(ctx: CommandContext, matchday: string, member: string, played: boolean) {
  return ctx.db
    .prepare(
      `INSERT INTO attendance (id, club_id, matchday_id, member_id, played, played_set_by, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET played = excluded.played, played_set_by = excluded.played_set_by, updated_at = excluded.updated_at`,
    )
    .bind(key(matchday, member), ctx.club.id, matchday, member, played ? 1 : 0, ctx.member.id, ctx.now.toISOString());
}

/** Voy / Quizás / No voy (o null para quitarla). Solo antes de que termine la jornada. */
export const setIntent = command(
  z.object({ matchdayId, intent: z.enum(["yes", "no", "maybe"]).nullable() }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    // La intención se juzga con la hora del teléfono: se marcó antes aunque llegue después.
    if (!acceptsIntent(md, ctx.clientAt)) throw errors.matchdayAlreadyPlayed();
    const id = key(md.id, ctx.member.id);
    return {
      statements: [
        ctx.db
          .prepare(
            `INSERT INTO attendance (id, club_id, matchday_id, member_id, intent, updated_at) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET intent = excluded.intent, updated_at = excluded.updated_at`,
          )
          .bind(id, ctx.club.id, md.id, ctx.member.id, p.intent, ctx.now.toISOString()),
      ],
      touched: [upsert("attendance", id)],
    };
  },
);

/** "Jugué" / "No fui". Solo cuando la jornada ya terminó. */
export const setPlayed = command(z.object({ matchdayId, played: z.boolean() }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  assertPlayed(ctx, md);
  return {
    statements: [playedStatement(ctx, md.id, ctx.member.id, p.played)],
    touched: [upsert("attendance", key(md.id, ctx.member.id))],
  };
});

/** Pasar lista: el staff marca quién jugó (con o sin cuenta). */
export const rollCall = command(
  z.object({
    matchdayId,
    entries: z
      .array(z.object({ memberId, played: z.boolean() }))
      .min(1)
      .max(90)
      .refine((e) => new Set(e.map((x) => x.memberId)).size === e.length, { error: "Hay jugadores repetidos" }),
  }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    assertPlayed(ctx, md);
    await assertActiveMembers(ctx, p.entries.map((e) => e.memberId), "entries");
    return {
      statements: p.entries.map((e) => playedStatement(ctx, md.id, e.memberId, e.played)),
      touched: p.entries.map((e) => upsert("attendance", key(md.id, e.memberId))),
    };
  },
);
```

`backend/src/commands/reports.ts`:

```ts
import { z } from "zod";
import { canActForOthers, canDecideReports } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { playedStatement } from "./attendance";
import { assertActiveMembers, assertOpen, assertPlayed, childChanges, findMatchday, goalsOrAssists, key, matchdayId, memberId } from "./pachanga";

const note = z.string().trim().max(200).nullable();

type ReportRow = { member_id: string; decision: "confirmed" | "rejected" | null };

async function findReport(ctx: CommandContext, matchday: string, member: string) {
  return ctx.db
    .prepare("SELECT member_id, decision FROM reports WHERE id = ?")
    .bind(key(matchday, member))
    .first<ReportRow>();
}

/** Quita las confirmaciones de un reporte (con sus `changes`): editar un reporte lo vuelve pendiente. */
function clearConfirmations(ctx: CommandContext, matchday: string, member: string) {
  return [
    childChanges(ctx, "report_confirmations", "confirmation", "delete", "matchday_id = ? AND member_id = ?", matchday, member),
    ctx.db.prepare("DELETE FROM report_confirmations WHERE matchday_id = ? AND member_id = ?").bind(matchday, member),
  ];
}

/** Escribe un reporte nuevo (o reemplaza el que había): sin decisión ni corrección. */
function writeReport(ctx: CommandContext, matchday: string, member: string, goals: number, assists: number, n: string | null) {
  return ctx.db
    .prepare(
      `INSERT INTO reports (id, club_id, matchday_id, member_id, goals, assists, note, loaded_by, decision, corrected_by, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
       ON CONFLICT(id) DO UPDATE SET goals = excluded.goals, assists = excluded.assists, note = excluded.note,
         loaded_by = excluded.loaded_by, decision = NULL, corrected_by = NULL, updated_at = excluded.updated_at`,
    )
    .bind(key(matchday, member), ctx.club.id, matchday, member, goals, assists, n, ctx.member.id, ctx.now.toISOString());
}

/**
 * Mi reporte de la jornada (crear o editar). Cuenta como "jugué". Editarlo lo vuelve pendiente; si el
 * admin lo rechazó, ya no se puede cambiar (rechazo definitivo).
 */
export const upsertReport = command(
  z.object({ matchdayId, goals: goalsOrAssists, assists: goalsOrAssists, note: note.optional() }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    assertPlayed(ctx, md);
    const existing = await findReport(ctx, md.id, ctx.member.id);
    if (existing?.decision === "rejected") throw errors.reportRejected();
    const id = key(md.id, ctx.member.id);
    return {
      statements: [
        ...clearConfirmations(ctx, md.id, ctx.member.id),
        writeReport(ctx, md.id, ctx.member.id, p.goals, p.assists, p.note ?? null),
        playedStatement(ctx, md.id, ctx.member.id, true),
      ],
      touched: [upsert("report", id), upsert("attendance", id)],
    };
  },
);

export const deleteReport = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const existing = await findReport(ctx, md.id, ctx.member.id);
  if (!existing) throw errors.notFound();
  if (existing.decision === "rejected") throw errors.reportRejected();
  const id = key(md.id, ctx.member.id);
  return {
    statements: [...clearConfirmations(ctx, md.id, ctx.member.id), ctx.db.prepare("DELETE FROM reports WHERE id = ?").bind(id)],
    touched: [remove("report", id)],
  };
});

/** El staff carga el reporte de otro (también de un jugador sin cuenta). Cuenta al momento. */
export const loadReportFor = command(
  z.object({ matchdayId, memberId, goals: goalsOrAssists, assists: goalsOrAssists, note: note.optional() }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    assertPlayed(ctx, md);
    await assertActiveMembers(ctx, [p.memberId], "memberId");
    const id = key(md.id, p.memberId);
    return {
      statements: [
        ...clearConfirmations(ctx, md.id, p.memberId),
        writeReport(ctx, md.id, p.memberId, p.goals, p.assists, p.note ?? null),
        playedStatement(ctx, md.id, p.memberId, true),
      ],
      touched: [upsert("report", id), upsert("attendance", id)],
      audit: [{ action: "report.loadFor", entity: "report", entityKey: id, summary: { goals: p.goals, assists: p.assists } }],
    };
  },
);

/** Un compañero que jugó confirma el reporte de otro. Confirmar dos veces no hace nada. */
export const confirmReport = command(z.object({ matchdayId, memberId }), async (ctx, p) => {
  if (p.memberId === ctx.member.id) throw errors.forbidden();
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const existing = await findReport(ctx, md.id, p.memberId);
  if (!existing) throw errors.notFound();
  if (existing.decision === "rejected") throw errors.reportRejected();
  const present = await ctx.db
    .prepare("SELECT 1 FROM attendance WHERE id = ? AND played = 1")
    .bind(key(md.id, ctx.member.id))
    .first();
  if (!present) throw errors.notPresent();
  const id = key(md.id, p.memberId, ctx.member.id);
  return {
    statements: [
      ctx.db
        .prepare(
          "INSERT OR IGNORE INTO report_confirmations (id, club_id, matchday_id, member_id, confirmer_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(id, ctx.club.id, md.id, p.memberId, ctx.member.id, ctx.now.toISOString()),
    ],
    touched: [upsert("confirmation", id)],
  };
});

export const unconfirmReport = command(z.object({ matchdayId, memberId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const id = key(md.id, p.memberId, ctx.member.id);
  return {
    statements: [ctx.db.prepare("DELETE FROM report_confirmations WHERE id = ?").bind(id)],
    touched: [remove("confirmation", id)],
  };
});

/** Owner o admin: confirmar, rechazar (definitivo para el autor) o quitar la decisión (null). */
export const decideReport = command(
  z.object({ matchdayId, memberId, decision: z.enum(["confirmed", "rejected"]).nullable() }),
  async (ctx, p) => {
    if (!canDecideReports(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (!(await findReport(ctx, md.id, p.memberId))) throw errors.notFound();
    const id = key(md.id, p.memberId);
    return {
      statements: [
        ctx.db.prepare("UPDATE reports SET decision = ?, updated_at = ? WHERE id = ?").bind(p.decision, ctx.now.toISOString(), id),
      ],
      touched: [upsert("report", id)],
      audit: [{ action: "report.decide", entity: "report", entityKey: id, summary: { decision: p.decision } }],
    };
  },
);

/** Owner o admin corrigen los números: queda confirmado y marcado como corregido. */
export const correctReport = command(
  z.object({ matchdayId, memberId, goals: goalsOrAssists, assists: goalsOrAssists }),
  async (ctx, p) => {
    if (!canDecideReports(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (!(await findReport(ctx, md.id, p.memberId))) throw errors.notFound();
    const id = key(md.id, p.memberId);
    return {
      statements: [
        ctx.db
          .prepare("UPDATE reports SET goals = ?, assists = ?, decision = 'confirmed', corrected_by = ?, updated_at = ? WHERE id = ?")
          .bind(p.goals, p.assists, ctx.member.id, ctx.now.toISOString(), id),
      ],
      touched: [upsert("report", id)],
      audit: [{ action: "report.correct", entity: "report", entityKey: id, summary: { goals: p.goals, assists: p.assists } }],
    };
  },
);

```

`backend/src/commands/votes.ts`:

```ts
import { z } from "zod";
import { errors } from "../http/errors";
import { remove, upsert } from "../sync/changes";
import { command } from "../sync/command";
import { assertOpen, assertPlayed, findMatchday, key, matchdayId, memberId } from "./pachanga";

/** Mi voto de MVP. Votan los que jugaron, por otro que jugó (con o sin cuenta). Cambiarlo reemplaza. */
export const castVote = command(z.object({ matchdayId, votedFor: memberId }), async (ctx, p) => {
  if (p.votedFor === ctx.member.id) throw errors.invalidInput({ votedFor: ["No puedes votarte a ti mismo"] });
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  assertPlayed(ctx, md);
  const { results } = await ctx.db
    .prepare("SELECT member_id FROM attendance WHERE matchday_id = ? AND played = 1 AND member_id IN (?, ?)")
    .bind(md.id, ctx.member.id, p.votedFor)
    .all<{ member_id: string }>();
  const present = new Set(results.map((r) => r.member_id));
  if (!present.has(ctx.member.id) || !present.has(p.votedFor)) throw errors.notPresent();
  const id = key(md.id, ctx.member.id);
  return {
    statements: [
      ctx.db
        .prepare(
          `INSERT INTO mvp_votes (id, club_id, matchday_id, voter_id, voted_for, updated_at) VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT(id) DO UPDATE SET voted_for = excluded.voted_for, updated_at = excluded.updated_at`,
        )
        .bind(id, ctx.club.id, md.id, ctx.member.id, p.votedFor, ctx.now.toISOString()),
    ],
    touched: [upsert("vote", id)],
  };
});

export const clearVote = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  assertOpen(ctx, md);
  const id = key(md.id, ctx.member.id);
  return {
    statements: [ctx.db.prepare("DELETE FROM mvp_votes WHERE id = ?").bind(id)],
    touched: [remove("vote", id)],
  };
});
```

`backend/src/commands/matchdays.ts`. La Task 3 añade `mergeMatchdays`:

```ts
import { z } from "zod";
import { canActForOthers, canCreateMatchday, canEditMatchday, canManageMatchday } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertActiveMembers, assertOpen, CHILDREN, childChanges, findMatchday, matchdayId, type Matchday } from "./pachanga";

const startsAt = z.iso.datetime({ offset: true }).transform((s) => new Date(s).toISOString());
const durationMinutes = z.number().int().min(30).max(600);
const place = z.string().trim().max(80).nullable();
const notes = z.string().trim().max(300).nullable();
const seasonId = z.string().min(1).max(64);

/** ¿Hay datos de alguien que no sea quien la creó? (asistencia, reportes o votos). */
async function hasOthersData(ctx: CommandContext, md: Matchday) {
  const row = await ctx.db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM attendance WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM reports WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM mvp_votes WHERE matchday_id = ?1 AND voter_id <> ?2) AS others`,
    )
    .bind(md.id, md.createdBy)
    .first<{ others: number }>();
  return row!.others === 1;
}

async function assertCanManage(ctx: CommandContext, md: Matchday) {
  const isCreator = md.createdBy === ctx.member.id;
  // La consulta solo hace falta para el player que la creó; el staff puede siempre.
  const others = ctx.member.role === "player" && isCreator ? await hasOthersData(ctx, md) : false;
  if (!canManageMatchday(ctx.member.role, { isCreator, hasOthersData: others })) throw errors.forbidden();
}

/** La temporada indicada (o la activa) tiene que existir en el servidor y no estar cerrada. */
async function resolveSeason(ctx: CommandContext, id: string | undefined) {
  const row = id
    ? await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE id = ? AND club_id = ?")
        .bind(id, ctx.club.id)
        .first<{ id: string; is_closed: number }>()
    : await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE club_id = ? AND is_active = 1")
        .bind(ctx.club.id)
        .first<{ id: string; is_closed: number }>();
  if (!row) throw id ? errors.notFound() : errors.noActiveSeason();
  if (row.is_closed === 1) throw errors.seasonClosed();
  return row.id;
}

/** Una jornada. El id lo pone la app; repetir cada semana = un comando por fecha. */
export const createMatchday = command(
  z.object({
    id: z.uuid(),
    startsAt,
    durationMinutes: durationMinutes.default(120),
    place: place.optional(),
    notes: notes.optional(),
    seasonId: seasonId.optional(),
  }),
  async (ctx, p) => {
    if (!canCreateMatchday(ctx.member.role, ctx.club.settings.matchdayCreators)) throw errors.forbidden();
    const season = await resolveSeason(ctx, p.seasonId);
    const at = ctx.now.toISOString();
    return {
      statements: [
        ctx.db
          .prepare(
            `INSERT INTO matchdays (id, club_id, season_id, starts_at, duration_minutes, place, notes, created_by, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(p.id, ctx.club.id, season, p.startsAt, p.durationMinutes, p.place ?? null, p.notes ?? null, ctx.member.id, at, at),
      ],
      touched: [upsert("matchday", p.id)],
    };
  },
);

/** Fecha, duración, lugar, notas o temporada. Lo que no venga se queda como está; `null` borra. */
export const updateMatchday = command(
  z
    .object({
      matchdayId,
      startsAt: startsAt.optional(),
      durationMinutes: durationMinutes.optional(),
      place: place.optional(),
      notes: notes.optional(),
      seasonId: seasonId.optional(),
    })
    .refine((p) => Object.keys(p).length > 1, { error: "Nada que cambiar" }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    if (!canEditMatchday(ctx.member.role, { isCreator: md.createdBy === ctx.member.id })) throw errors.forbidden();
    const season = p.seasonId === undefined ? md.seasonId : await resolveSeason(ctx, p.seasonId);
    return {
      statements: [
        ctx.db
          .prepare(
            `UPDATE matchdays SET starts_at = ?, duration_minutes = ?,
                    place = CASE WHEN ? THEN ? ELSE place END,
                    notes = CASE WHEN ? THEN ? ELSE notes END,
                    season_id = ?, updated_at = ?
              WHERE id = ?`,
          )
          .bind(
            p.startsAt ?? md.startsAt,
            p.durationMinutes ?? md.durationMinutes,
            p.place !== undefined ? 1 : 0,
            p.place ?? null,
            p.notes !== undefined ? 1 : 0,
            p.notes ?? null,
            season,
            ctx.now.toISOString(),
            md.id,
          ),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);

/** Cancelar, reactivar, cerrar a mano o reabrir. */
export const setMatchdayStatus = command(
  z.object({ matchdayId, status: z.enum(["scheduled", "cancelled", "closed", "reopened"]) }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    await assertCanManage(ctx, md);
    if (md.seasonClosed) throw errors.seasonClosed();
    return {
      statements: [
        ctx.db.prepare("UPDATE matchdays SET status = ?, updated_at = ? WHERE id = ?").bind(p.status, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
      audit: [{ action: "matchday.setStatus", entity: "matchday", entityKey: md.id, summary: { from: md.status, to: p.status } }],
    };
  },
);

/** Borra la jornada y todo lo que cuelga de ella (asistencia, reportes, confirmaciones, votos). */
export const deleteMatchday = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  await assertCanManage(ctx, md);
  const statements: D1PreparedStatement[] = [];
  for (const { table, entity } of CHILDREN) {
    statements.push(childChanges(ctx, table, entity, "delete", "matchday_id = ?", md.id));
    statements.push(ctx.db.prepare(`DELETE FROM ${table} WHERE matchday_id = ?`).bind(md.id));
  }
  statements.push(ctx.db.prepare("DELETE FROM matchdays WHERE id = ?").bind(md.id));
  return {
    statements,
    touched: [remove("matchday", md.id)],
    audit: [{ action: "matchday.delete", entity: "matchday", entityKey: md.id }],
  };
});

/** Equipos (opcional). `null` los quita. Solo miembros activos del servidor. */
export const saveTeams = command(
  z.object({
    matchdayId,
    teams: z.object({ a: z.array(z.string().min(1).max(64)).max(40), b: z.array(z.string().min(1).max(64)).max(40) }).nullable(),
  }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (p.teams) await assertActiveMembers(ctx, [...p.teams.a, ...p.teams.b], "teams");
    return {
      statements: [
        ctx.db
          .prepare("UPDATE matchdays SET teams = ?, updated_at = ? WHERE id = ?")
          .bind(p.teams ? JSON.stringify(p.teams) : null, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);
```

Reemplaza `backend/src/sync/handlers.ts` por:

```ts
import { transferOwnership, updateSettings } from "../commands/club";
import { ban, createGuest, leave, setRole, unban, updateMember } from "../commands/members";
import {
  activateSeason,
  createSeason,
  deleteSeason,
  setSeasonClosed,
  updateSeason,
} from "../commands/seasons";
import { rollCall, setIntent, setPlayed } from "../commands/attendance";
import {
  createMatchday,
  deleteMatchday,
  saveTeams,
  setMatchdayStatus,
  updateMatchday,
} from "../commands/matchdays";
import {
  confirmReport,
  correctReport,
  decideReport,
  deleteReport,
  loadReportFor,
  unconfirmReport,
  upsertReport,
} from "../commands/reports";
import { castVote, clearVote } from "../commands/votes";
import type { CommandHandler } from "./command";

/** Todos los tipos de comando que entiende el servidor (spec §5). */
export const HANDLERS: Record<string, CommandHandler | undefined> = {
  "member.createGuest": createGuest,
  "member.update": updateMember,
  "member.setRole": setRole,
  "member.ban": ban,
  "member.unban": unban,
  "member.leave": leave,
  "club.updateSettings": updateSettings,
  "club.transferOwnership": transferOwnership,
  "season.create": createSeason,
  "season.update": updateSeason,
  "season.activate": activateSeason,
  "season.setClosed": setSeasonClosed,
  "season.delete": deleteSeason,
  "matchday.create": createMatchday,
  "matchday.update": updateMatchday,
  "matchday.setStatus": setMatchdayStatus,
  "matchday.delete": deleteMatchday,
  "teams.save": saveTeams,
  "attendance.setIntent": setIntent,
  "attendance.setPlayed": setPlayed,
  "attendance.rollCall": rollCall,
  "report.upsert": upsertReport,
  "report.delete": deleteReport,
  "report.loadFor": loadReportFor,
  "report.confirm": confirmReport,
  "report.unconfirm": unconfirmReport,
  "report.decide": decideReport,
  "report.correct": correctReport,
  "vote.cast": castVote,
  "vote.clear": clearVote,
};
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (241 tests en 26 archivos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: comandos de la pachanga (jornadas, asistencia, reportes, confirmaciones, MVP y equipos)"
```

---

### Task 3: Unir jornadas duplicadas

**Files:**
- Modify: `backend/src/commands/matchdays.ts` (reemplazo completo), `backend/src/sync/handlers.ts` (reemplazo completo)
- Test: `backend/test/commands-merge.test.ts`

**Interfaces:**
- Consumes: todo lo de la Task 2.
- Produces: `matchday.merge { fromId, intoId }`.
  - Todo lo de `fromId` pasa a `intoId`.
  - Si una persona tiene datos en las dos, gana el más reciente por `updated_at`, y las confirmaciones siguen a su reporte.
  - `fromId` se borra, con `changes` de borrado para todo lo suyo.

- [ ] **Step 1: Escribir el test que falla**

`backend/test/commands-merge.test.ts`:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, auditActions } from "./fixtures";
import { count, matchday, played, row, squad } from "./pachanga-helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

/** Retoca updated_at para decidir quién es "más reciente" sin depender del reloj del test. */
async function touch(table: string, id: string, at: string) {
  await env.DB.prepare(`UPDATE ${table} SET updated_at = ? WHERE id = ?`).bind(at, id).run();
}

describe("matchday.merge (dos jornadas del mismo día creadas sin señal)", () => {
  it("todo pasa a la que se queda; si alguien tiene datos en las dos, gana el más reciente", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(raul.token, clubId);
    await played(clubId, into, raul.token, pepe.token);
    await played(clubId, from, pepe.token);
    // Raúl reportó en las dos: la de `from` es más nueva.
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: into, goals: 1, assists: 0 }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 3, assists: 1 }));
    await touch("reports", `${into}:${raul.memberId}`, "2026-01-01T00:00:00.000Z");
    // Pepe solo reportó en `from`.
    await apply(pepe.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 0, assists: 2 }));

    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    expect(await row("matchdays", from)).toBeNull();
    expect(await row("reports", `${into}:${raul.memberId}`)).toMatchObject({ goals: 3, assists: 1 });
    expect(await row("reports", `${into}:${pepe.memberId}`)).toMatchObject({ goals: 0, assists: 2 });
    expect(await count("reports", "matchday_id = ?", from)).toBe(0);
    expect(await count("attendance", "matchday_id = ?", from)).toBe(0);
    expect(await auditActions(clubId)).toContain("matchday.merge");
  });

  it("las confirmaciones siguen a su reporte: si gana el de `from`, se van las del otro", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe, scorer, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    await played(clubId, into, raul.token, pepe.token);
    await played(clubId, from, raul.token, scorer.token);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: into, goals: 1, assists: 0 }));
    await apply(pepe.token, cmd(clubId, "report.confirm", { matchdayId: into, memberId: raul.memberId }));
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 2, assists: 0 }));
    await apply(scorer.token, cmd(clubId, "report.confirm", { matchdayId: from, memberId: raul.memberId }));
    await touch("reports", `${into}:${raul.memberId}`, "2026-01-01T00:00:00.000Z");

    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    const { results } = await env.DB.prepare("SELECT id FROM report_confirmations").all<{ id: string }>();
    expect(results.map((r) => r.id)).toEqual([`${into}:${raul.memberId}:${scorer.memberId}`]);
  });

  it("el pull manda lo de `from` como borrado y lo nuevo de `into` como cambiado", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, admin } = await squad(clubId);
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    await apply(raul.token, cmd(clubId, "report.upsert", { matchdayId: from, goals: 1, assists: 0 }));
    const cursor = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    await apply(admin.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    const next = (await pullAll(owner.token, { [clubId]: cursor })).clubs[clubId]!;
    expect(next.deletes.matchday).toEqual([from]);
    expect(next.deletes.report).toEqual([`${from}:${raul.memberId}`]);
    expect(next.upserts.report).toMatchObject([{ id: `${into}:${raul.memberId}`, matchdayId: into, goals: 1 }]);
  });

  it("un player une sus propias duplicadas si nadie más cargó datos en la que se borra", async () => {
    const { clubId, owner } = await activeClub();
    const { raul, pepe } = await squad(clubId);
    const into = await matchday(raul.token, clubId);
    const from = await matchday(raul.token, clubId);
    await apply(raul.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }));
    const again = await matchday(raul.token, clubId);
    await played(clubId, again, pepe.token);
    expect(await rejection(raul.token, cmd(clubId, "matchday.merge", { fromId: again, intoId: into }))).toBe("forbidden");
    const ownersOne = await matchday(owner.token, clubId);
    expect(await rejection(raul.token, cmd(clubId, "matchday.merge", { fromId: ownersOne, intoId: into }))).toBe("forbidden");
  });

  it("no se une una consigo misma ni una cerrada", async () => {
    const { clubId, owner } = await activeClub();
    const into = await matchday(owner.token, clubId);
    const from = await matchday(owner.token, clubId);
    expect(await rejection(owner.token, cmd(clubId, "matchday.merge", { fromId: into, intoId: into }))).toBe("invalid_input");
    await apply(owner.token, cmd(clubId, "matchday.setStatus", { matchdayId: from, status: "closed" }));
    expect(await rejection(owner.token, cmd(clubId, "matchday.merge", { fromId: from, intoId: into }))).toBe("matchday_closed");
  });
});
```

- [ ] **Step 2: Ver que falla**

Run: `cd backend && npx vitest run test/commands-merge.test.ts`
Expected: FAIL. `matchday.merge` vuelve `deferred` con `unknown_command`.

- [ ] **Step 3: Implementar**

Reemplaza `backend/src/commands/matchdays.ts` por:

```ts
import { z } from "zod";
import { canActForOthers, canCreateMatchday, canEditMatchday, canManageMatchday } from "../authz";
import { errors } from "../http/errors";
import { remove, upsert, type Touch } from "../sync/changes";
import { command, type CommandContext } from "../sync/command";
import { assertActiveMembers, assertOpen, CHILDREN, childChanges, findMatchday, key, matchdayId, type Matchday } from "./pachanga";

const startsAt = z.iso.datetime({ offset: true }).transform((s) => new Date(s).toISOString());
const durationMinutes = z.number().int().min(30).max(600);
const place = z.string().trim().max(80).nullable();
const notes = z.string().trim().max(300).nullable();
const seasonId = z.string().min(1).max(64);

/** ¿Hay datos de alguien que no sea quien la creó? (asistencia, reportes o votos). */
async function hasOthersData(ctx: CommandContext, md: Matchday) {
  const row = await ctx.db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM attendance WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM reports WHERE matchday_id = ?1 AND member_id <> ?2)
           OR EXISTS (SELECT 1 FROM mvp_votes WHERE matchday_id = ?1 AND voter_id <> ?2) AS others`,
    )
    .bind(md.id, md.createdBy)
    .first<{ others: number }>();
  return row!.others === 1;
}

async function assertCanManage(ctx: CommandContext, md: Matchday) {
  const isCreator = md.createdBy === ctx.member.id;
  // La consulta solo hace falta para el player que la creó; el staff puede siempre.
  const others = ctx.member.role === "player" && isCreator ? await hasOthersData(ctx, md) : false;
  if (!canManageMatchday(ctx.member.role, { isCreator, hasOthersData: others })) throw errors.forbidden();
}

/** La temporada indicada (o la activa) tiene que existir en el servidor y no estar cerrada. */
async function resolveSeason(ctx: CommandContext, id: string | undefined) {
  const row = id
    ? await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE id = ? AND club_id = ?")
        .bind(id, ctx.club.id)
        .first<{ id: string; is_closed: number }>()
    : await ctx.db
        .prepare("SELECT id, is_closed FROM seasons WHERE club_id = ? AND is_active = 1")
        .bind(ctx.club.id)
        .first<{ id: string; is_closed: number }>();
  if (!row) throw id ? errors.notFound() : errors.noActiveSeason();
  if (row.is_closed === 1) throw errors.seasonClosed();
  return row.id;
}

/** Una jornada. El id lo pone la app; repetir cada semana = un comando por fecha. */
export const createMatchday = command(
  z.object({
    id: z.uuid(),
    startsAt,
    durationMinutes: durationMinutes.default(120),
    place: place.optional(),
    notes: notes.optional(),
    seasonId: seasonId.optional(),
  }),
  async (ctx, p) => {
    if (!canCreateMatchday(ctx.member.role, ctx.club.settings.matchdayCreators)) throw errors.forbidden();
    const season = await resolveSeason(ctx, p.seasonId);
    const at = ctx.now.toISOString();
    return {
      statements: [
        ctx.db
          .prepare(
            `INSERT INTO matchdays (id, club_id, season_id, starts_at, duration_minutes, place, notes, created_by, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(p.id, ctx.club.id, season, p.startsAt, p.durationMinutes, p.place ?? null, p.notes ?? null, ctx.member.id, at, at),
      ],
      touched: [upsert("matchday", p.id)],
    };
  },
);

/** Fecha, duración, lugar, notas o temporada. Lo que no venga se queda como está; `null` borra. */
export const updateMatchday = command(
  z
    .object({
      matchdayId,
      startsAt: startsAt.optional(),
      durationMinutes: durationMinutes.optional(),
      place: place.optional(),
      notes: notes.optional(),
      seasonId: seasonId.optional(),
    })
    .refine((p) => Object.keys(p).length > 1, { error: "Nada que cambiar" }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    if (!canEditMatchday(ctx.member.role, { isCreator: md.createdBy === ctx.member.id })) throw errors.forbidden();
    const season = p.seasonId === undefined ? md.seasonId : await resolveSeason(ctx, p.seasonId);
    return {
      statements: [
        ctx.db
          .prepare(
            `UPDATE matchdays SET starts_at = ?, duration_minutes = ?,
                    place = CASE WHEN ? THEN ? ELSE place END,
                    notes = CASE WHEN ? THEN ? ELSE notes END,
                    season_id = ?, updated_at = ?
              WHERE id = ?`,
          )
          .bind(
            p.startsAt ?? md.startsAt,
            p.durationMinutes ?? md.durationMinutes,
            p.place !== undefined ? 1 : 0,
            p.place ?? null,
            p.notes !== undefined ? 1 : 0,
            p.notes ?? null,
            season,
            ctx.now.toISOString(),
            md.id,
          ),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);

/** Cancelar, reactivar, cerrar a mano o reabrir. */
export const setMatchdayStatus = command(
  z.object({ matchdayId, status: z.enum(["scheduled", "cancelled", "closed", "reopened"]) }),
  async (ctx, p) => {
    const md = await findMatchday(ctx, p.matchdayId);
    await assertCanManage(ctx, md);
    if (md.seasonClosed) throw errors.seasonClosed();
    return {
      statements: [
        ctx.db.prepare("UPDATE matchdays SET status = ?, updated_at = ? WHERE id = ?").bind(p.status, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
      audit: [{ action: "matchday.setStatus", entity: "matchday", entityKey: md.id, summary: { from: md.status, to: p.status } }],
    };
  },
);

/** Borra la jornada y todo lo que cuelga de ella (asistencia, reportes, confirmaciones, votos). */
export const deleteMatchday = command(z.object({ matchdayId }), async (ctx, p) => {
  const md = await findMatchday(ctx, p.matchdayId);
  await assertCanManage(ctx, md);
  const statements: D1PreparedStatement[] = [];
  for (const { table, entity } of CHILDREN) {
    statements.push(childChanges(ctx, table, entity, "delete", "matchday_id = ?", md.id));
    statements.push(ctx.db.prepare(`DELETE FROM ${table} WHERE matchday_id = ?`).bind(md.id));
  }
  statements.push(ctx.db.prepare("DELETE FROM matchdays WHERE id = ?").bind(md.id));
  return {
    statements,
    touched: [remove("matchday", md.id)],
    audit: [{ action: "matchday.delete", entity: "matchday", entityKey: md.id }],
  };
});

/** Equipos (opcional). `null` los quita. Solo miembros activos del servidor. */
export const saveTeams = command(
  z.object({
    matchdayId,
    teams: z.object({ a: z.array(z.string().min(1).max(64)).max(40), b: z.array(z.string().min(1).max(64)).max(40) }).nullable(),
  }),
  async (ctx, p) => {
    if (!canActForOthers(ctx.member.role)) throw errors.forbidden();
    const md = await findMatchday(ctx, p.matchdayId);
    assertOpen(ctx, md);
    if (p.teams) await assertActiveMembers(ctx, [...p.teams.a, ...p.teams.b], "teams");
    return {
      statements: [
        ctx.db
          .prepare("UPDATE matchdays SET teams = ?, updated_at = ? WHERE id = ?")
          .bind(p.teams ? JSON.stringify(p.teams) : null, ctx.now.toISOString(), md.id),
      ],
      touched: [upsert("matchday", md.id)],
    };
  },
);

type ChildRow = { t: string; id: string; member_id: string; confirmer_id: string | null; updated_at: string; data: string };

/**
 * Une dos jornadas duplicadas (dos personas la crearon sin señal). Todo lo de `fromId` pasa a
 * `intoId`; si una persona tiene datos en las dos, se queda el más reciente (y las confirmaciones
 * siguen a su reporte). `fromId` se borra.
 */
export const mergeMatchdays = command(
  z.object({ fromId: matchdayId, intoId: matchdayId }).refine((p) => p.fromId !== p.intoId, { error: "Son la misma jornada" }),
  async (ctx, p) => {
    const from = await findMatchday(ctx, p.fromId);
    const into = await findMatchday(ctx, p.intoId);
    await assertCanManage(ctx, from);
    if (!canEditMatchday(ctx.member.role, { isCreator: into.createdBy === ctx.member.id })) throw errors.forbidden();
    assertOpen(ctx, from);
    assertOpen(ctx, into);

    const { results } = await ctx.db
      .prepare(
        `SELECT 'attendance' AS t, id, member_id, NULL AS confirmer_id, updated_at,
                json_object('intent', intent, 'played', played, 'played_set_by', played_set_by) AS data
           FROM attendance WHERE matchday_id IN (?1, ?2)
         UNION ALL
         SELECT 'reports', id, member_id, NULL, updated_at,
                json_object('goals', goals, 'assists', assists, 'note', note, 'loaded_by', loaded_by,
                            'decision', decision, 'corrected_by', corrected_by)
           FROM reports WHERE matchday_id IN (?1, ?2)
         UNION ALL
         SELECT 'report_confirmations', id, member_id, confirmer_id, created_at, '{}'
           FROM report_confirmations WHERE matchday_id IN (?1, ?2)
         UNION ALL
         SELECT 'mvp_votes', id, voter_id, NULL, updated_at, json_object('voted_for', voted_for)
           FROM mvp_votes WHERE matchday_id IN (?1, ?2)`,
      )
      .bind(from.id, into.id)
      .all<ChildRow>();

    const isFrom = (r: ChildRow) => r.id.startsWith(`${from.id}:`);
    const statements: D1PreparedStatement[] = [];
    const touched: Touch[] = [];
    const entityOf: Record<string, Touch["entity"]> = {
      attendance: "attendance",
      reports: "report",
      report_confirmations: "confirmation",
      mvp_votes: "vote",
    };

    // Ganador por persona en asistencia, reportes y votos: el más reciente.
    const reportFromWins = new Set<string>();
    for (const table of ["attendance", "reports", "mvp_votes"]) {
      const byMember = new Map<string, { from?: ChildRow; into?: ChildRow }>();
      for (const r of results.filter((x) => x.t === table)) {
        const slot = byMember.get(r.member_id) ?? {};
        slot[isFrom(r) ? "from" : "into"] = r;
        byMember.set(r.member_id, slot);
      }
      for (const [member, { from: f, into: i }] of byMember) {
        if (!f) continue;
        if (!i || f.updated_at > i.updated_at) {
          if (table === "reports") reportFromWins.add(member);
          statements.push(copyInto(ctx, table, f, into.id, member));
          touched.push(upsert(entityOf[table]!, key(into.id, member)));
        }
      }
    }

    // Confirmaciones: si ganó el reporte de `fromId`, se quedan las suyas y se van las de `intoId`.
    for (const r of results.filter((x) => x.t === "report_confirmations")) {
      const wins = reportFromWins.has(r.member_id);
      if (isFrom(r) && wins) {
        const id = key(into.id, r.member_id, r.confirmer_id!);
        statements.push(
          ctx.db
            .prepare(
              "INSERT OR REPLACE INTO report_confirmations (id, club_id, matchday_id, member_id, confirmer_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(id, ctx.club.id, into.id, r.member_id, r.confirmer_id, r.updated_at),
        );
        touched.push(upsert("confirmation", id));
      } else if (!isFrom(r) && wins && !results.some((x) => x.t === "report_confirmations" && isFrom(x) && x.member_id === r.member_id && x.confirmer_id === r.confirmer_id)) {
        statements.push(ctx.db.prepare("DELETE FROM report_confirmations WHERE id = ?").bind(r.id));
        touched.push(remove("confirmation", r.id));
      }
    }

    // Todo lo de `fromId` desaparece, y `fromId` también.
    for (const { table, entity } of CHILDREN) {
      statements.push(childChanges(ctx, table, entity, "delete", "matchday_id = ?", from.id));
      statements.push(ctx.db.prepare(`DELETE FROM ${table} WHERE matchday_id = ?`).bind(from.id));
    }
    statements.push(ctx.db.prepare("DELETE FROM matchdays WHERE id = ?").bind(from.id));
    touched.push(remove("matchday", from.id));

    return {
      statements,
      touched,
      audit: [{ action: "matchday.merge", entity: "matchday", entityKey: into.id, summary: { from: from.id } }],
    };
  },
);

/** Copia la fila ganadora de `fromId` a `intoId` (reemplazando la que hubiera). */
function copyInto(ctx: CommandContext, table: string, row: ChildRow, intoId: string, member: string) {
  const d = JSON.parse(row.data) as Record<string, unknown>;
  const id = key(intoId, member);
  if (table === "attendance") {
    return ctx.db
      .prepare(
        `INSERT OR REPLACE INTO attendance (id, club_id, matchday_id, member_id, intent, played, played_set_by, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(id, ctx.club.id, intoId, member, d.intent ?? null, d.played ?? null, d.played_set_by ?? null, row.updated_at);
  }
  if (table === "reports") {
    return ctx.db
      .prepare(
        `INSERT OR REPLACE INTO reports (id, club_id, matchday_id, member_id, goals, assists, note, loaded_by, decision, corrected_by, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(id, ctx.club.id, intoId, member, d.goals, d.assists, d.note ?? null, d.loaded_by, d.decision ?? null, d.corrected_by ?? null, row.updated_at);
  }
  return ctx.db
    .prepare("INSERT OR REPLACE INTO mvp_votes (id, club_id, matchday_id, voter_id, voted_for, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(id, ctx.club.id, intoId, member, d.voted_for, row.updated_at);
}
```

Reemplaza `backend/src/sync/handlers.ts` por:

```ts
import { transferOwnership, updateSettings } from "../commands/club";
import { ban, createGuest, leave, setRole, unban, updateMember } from "../commands/members";
import {
  activateSeason,
  createSeason,
  deleteSeason,
  setSeasonClosed,
  updateSeason,
} from "../commands/seasons";
import { rollCall, setIntent, setPlayed } from "../commands/attendance";
import {
  createMatchday,
  deleteMatchday,
  mergeMatchdays,
  saveTeams,
  setMatchdayStatus,
  updateMatchday,
} from "../commands/matchdays";
import {
  confirmReport,
  correctReport,
  decideReport,
  deleteReport,
  loadReportFor,
  unconfirmReport,
  upsertReport,
} from "../commands/reports";
import { castVote, clearVote } from "../commands/votes";
import type { CommandHandler } from "./command";

/** Todos los tipos de comando que entiende el servidor (spec §5). */
export const HANDLERS: Record<string, CommandHandler | undefined> = {
  "member.createGuest": createGuest,
  "member.update": updateMember,
  "member.setRole": setRole,
  "member.ban": ban,
  "member.unban": unban,
  "member.leave": leave,
  "club.updateSettings": updateSettings,
  "club.transferOwnership": transferOwnership,
  "season.create": createSeason,
  "season.update": updateSeason,
  "season.activate": activateSeason,
  "season.setClosed": setSeasonClosed,
  "season.delete": deleteSeason,
  "matchday.create": createMatchday,
  "matchday.update": updateMatchday,
  "matchday.setStatus": setMatchdayStatus,
  "matchday.delete": deleteMatchday,
  "matchday.merge": mergeMatchdays,
  "teams.save": saveTeams,
  "attendance.setIntent": setIntent,
  "attendance.setPlayed": setPlayed,
  "attendance.rollCall": rollCall,
  "report.upsert": upsertReport,
  "report.delete": deleteReport,
  "report.loadFor": loadReportFor,
  "report.confirm": confirmReport,
  "report.unconfirm": unconfirmReport,
  "report.decide": decideReport,
  "report.correct": correctReport,
  "vote.cast": castVote,
  "vote.clear": clearVote,
};
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (246 tests en 27 archivos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: unir jornadas duplicadas creadas sin señal"
```

---

### Task 4: Desplegar a staging y README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Desplegar**

```bash
cd backend && npm run deploy:staging > deploy.log 2>&1; grep -E "0004|Deployed|Version ID|rror" deploy.log; rm deploy.log
```

Expected: aparece `0004_pachanga.sql` con `✅` y después `Deployed furbo-api-staging`.

- [ ] **Step 2: Prueba de humo en staging**

Monta un servidor de prueba de punta a punta:
1. Registra un dueño y un superadmin.
2. Marca al superadmin con `npx wrangler d1 execute DB --remote --env staging --command "UPDATE users SET is_superadmin = 1 WHERE id = '<id>'"`.
3. Solicita el servidor y apruébalo.
4. Con el token del dueño, haz `POST /sync/push` con tres comandos:
   - `matchday.create`, con `startsAt` de hace 3 h;
   - `attendance.setPlayed { played: true }`;
   - `report.upsert { goals: 2, assists: 1 }`.
5. Haz `POST /sync/pull` con `{"cursors":{}}`.

Expected:
- Los tres comandos dan `applied`.
- En el pull, `upserts.matchday`, `upserts.attendance` y `upserts.report` tienen una fila cada uno, y el reporte trae `goals: 2`.

Al terminar, borra con `wrangler d1 execute` los datos de prueba: todas las filas con ese `club_id`, en este orden:
1. `report_confirmations`, `mvp_votes`, `reports` y `attendance`;
2. `matchdays`, `changes`, `applied_commands`, `audit_log`, `invites`, `seasons` y `members`;
3. `clubs`.

Después borra las `sessions` y los `users` de prueba.

- [ ] **Step 3: README**

En `README.md`, después del bloque "Sincronización (PR3a)", añade:

````markdown
- Pachanga (PR3b):
  - Comandos `matchday.*`, `attendance.*`, `report.*`, `vote.*` y `teams.save`.
  - Una jornada cerrada (temporada cerrada, cancelada, cerrada a mano o pasado el plazo sin reabrir) no
    acepta cambios de nadie.
  - El plazo cuenta con la hora del teléfono, acotada, para no perder lo hecho sin señal.
  - Las reglas puras viven en `backend/src/rules/matchday.ts`, y sus casos en
    `shared-fixtures/matchday-rules.json`, que también ejecutará la app.
````

- [ ] **Step 4: Comprobación final**

```bash
cd backend && npm run typecheck && npm test && cd .. && git status --short
```

Expected: `typecheck` limpio y `246 passed`. `git status` muestra solo `README.md`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "README: la pachanga sobre la sincronización"
```
