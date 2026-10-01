# PR2 · Servidores, invitaciones y superadmin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que cualquiera pueda solicitar un servidor, que el superadmin lo apruebe, y que el staff invite gente (también a reclamar un perfil sin cuenta) y genere códigos de recuperación. Todo con permisos por rol y registro de auditoría.

**Architecture:** Este PR amplía el Worker del PR1:
- **Migración 0002:** tablas `clubs`, `members`, `invites` y `audit_log`.
- **`src/authz.ts`:** la matriz de permisos del spec §4, como funciones puras.
- **Endpoints REST con conexión**, cada uno en su módulo:
  - `clubs/` para solicitar un servidor y las acciones del staff,
  - `invites/` para la vista previa, aceptar y la página `/i/<código>`,
  - `superadmin/` para el panel.

Todo cambio va en un `db.batch` junto con su fila de auditoría.

**Tech Stack:** el mismo del PR1: TypeScript 7, Hono 4, zod 4, Wrangler 4, Vitest 4 + `@cloudflare/vitest-pool-workers`, D1.

**Spec:** `docs/superpowers/specs/2026-10-01-servidores-backend-propio-design.md` (§2 "Servidores y miembros", §3 recuperación y borrado de cuenta, §4 completo, §9, §12 punto 2).

## Alcance de este PR

Entra:
- Solicitar un servidor (máximo 3 pendientes o activos por persona) y `GET /me` con `clubs` y `clubRequests`.
- Panel del superadmin:
  - servidores: listar, buscar, ver detalle, aprobar, rechazar con motivo, suspender, reactivar y transferir el dueño;
  - usuarios: buscar, suspender, reactivar y generar códigos de recuperación;
  - métricas.
- Invitaciones:
  - el staff las crea, lista y revoca;
  - cualquiera ve la vista previa y la página `/i/<código>`;
  - aceptar sirve para entrar, para volver tras haberse ido y para reclamar un perfil sin cuenta.
- Códigos de recuperación generados por el owner o un admin.
- `DELETE /me` ampliado: el dueño tiene que transferir antes; los perfiles quedan como "Jugador eliminado".
- La matriz completa de permisos en `authz.ts`.

Queda para PRs siguientes (no implementar aquí):
- **PR3, comandos de sync:** `member.createGuest`, `update`, `setRole`, `ban`, `unban`, `leave`, `club.updateSettings` y la transferencia de propiedad hecha por el propio owner. Hasta entonces los tests crean miembros y jugadores sin cuenta directamente en D1 (helpers `addMember` y `addGuest`).
- **PR3:** la temporada inicial al aprobar un servidor (la tabla `seasons` llega con el PR3, que la crea también para los servidores ya aprobados), la lectura de datos de cualquier servidor por el superadmin vía pull, y la métrica de "comandos por día".
- **PR6:** los push de "nueva solicitud" y "servidor aprobado/rechazado", y el enlace de descarga del APK en la página de invitación.

## Global Constraints

- Todo lo de las Global Constraints del PR1 (`docs/superpowers/plans/2026-10-01-pr1-backend-base.md`) sigue valiendo:
  - npm ≥ 11, las versiones exactas y `compatibility_date` `"2026-08-15"`;
  - mensajes en español, de tú, y la forma de error `{ error: { code, message, details } }`;
  - fechas ISO UTC y commits sin ninguna atribución a IA.
- El texto visible dice "servidor"; en el código y en la base de datos se llama `club`.
- Quien no es miembro activo de un servidor recibe **404** en cualquier recurso de ese servidor, no 403, para no confirmar que existe. Quien es miembro pero no tiene permiso recibe **403** `forbidden`.
- Un servidor `suspended` es de solo lectura. Cambiar algo en él da **403** `club_suspended`.
- Códigos de invitación y de recuperación:
  - 8 caracteres del alfabeto `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`;
  - se muestran como `XXXX-XXXX` y se aceptan en minúsculas, con espacios o con guiones.
- Las invitaciones duran 7 días por defecto (entre 1 y 30) y tienen 1 uso por defecto (entre 1 y 100). Si son para reclamar un perfil, siempre 1 uso y rol `player`.
- Se auditan: `club.request`, `club.approve`, `club.reject`, `club.suspend`, `club.reactivate`, `club.transfer`, `invite.create`, `invite.revoke`, `invite.accept`, `recovery.issue`, `user.suspend` y `user.unsuspend`.
- Rama `feature/servidores`, creada desde `feature/backend-base`. Ya existe y contiene este plan. Mientras el PR1 no esté fusionado, el PR va contra `feature/backend-base`.

## Review Focus

1. **XSS en la página de invitación.** El nombre y la descripción del servidor los escribe cualquiera que solicite uno, y `/i/<código>` los muestra en HTML. Tienen que salir escapados. Test: Task 7.
2. **Aislamiento entre servidores.** El admin del servidor A no puede invitar, revocar, generar códigos ni apuntar a perfiles del servidor B: 404 o 400, nunca éxito. Tests: Tasks 4, 6 y 8.
3. **Aceptar dos veces por mala conexión.** El reintento devuelve 409 `already_member`, y el uso de la invitación cuenta una sola vez. Test: Task 7.
4. **Gente que ya no está.** Un admin que se fue o al que expulsaron conserva su token, pero no actúa en el servidor (404). Un expulsado no vuelve con una invitación. Tests: Tasks 6 y 7.
5. **Borrar la cuenta siendo dueño o miembro.** Si es dueño, 409 con un mensaje claro y la cuenta sigue. Si es miembro, sus estadísticas se quedan en el servidor como "Jugador eliminado". Test: Task 9.

---

### Task 1: Esquema de servidores, miembros, invitaciones y auditoría

**Files:**
- Create: `backend/migrations/0002_servidores.sql`
- Modify: `backend/test/setup.ts`, para vaciar las tablas en orden inverso de creación (por las claves foráneas)
- Test: `backend/test/schema.test.ts`

**Interfaces:**
- Produces: las tablas `clubs`, `members`, `invites` y `audit_log` tal como las usan las tareas siguientes. Columnas clave:
  - `clubs.status` ∈ `pending`, `active`, `rejected`, `suspended`;
  - `members.role` ∈ `owner`, `admin`, `scorer`, `player`, `guest`;
  - `members.status` ∈ `active`, `left`, `banned`;
  - `CHECK ((role = 'guest') = (user_id IS NULL))`;
  - índice único parcial `(club_id, user_id)`.

- [ ] **Step 1: Escribir el test que falla**

`backend/test/schema.test.ts`:

```ts
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";

const at = new Date().toISOString();

async function insertMember(id: string, userId: string | null, role: string) {
  await env.DB.prepare(
    "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, 'c1', ?, ?, 'X', ?, ?)",
  )
    .bind(id, userId, role, at, at)
    .run();
}

describe("esquema de servidores y miembros", () => {
  beforeEach(async () => {
    await env.DB.prepare(
      "INSERT INTO clubs (id, name, status, owner_user_id, settings, created_at, updated_at) VALUES ('c1', 'Club', 'active', 'u1', '{}', ?, ?)",
    )
      .bind(at, at)
      .run();
  });

  it("sin cuenta implica guest, y guest implica sin cuenta", async () => {
    await insertMember("m1", null, "guest");
    await expect(insertMember("m2", "u2", "guest")).rejects.toThrow(/CHECK constraint failed/);
    await expect(insertMember("m3", null, "player")).rejects.toThrow(/CHECK constraint failed/);
  });

  it("un usuario tiene como mucho un perfil por servidor; perfiles sin cuenta, los que hagan falta", async () => {
    await insertMember("m1", "u2", "player");
    await expect(insertMember("m2", "u2", "admin")).rejects.toThrow(/UNIQUE constraint failed/);
    await insertMember("m3", null, "guest");
    await insertMember("m4", null, "guest");
  });

  it("los roles y estados fuera de la lista se rechazan", async () => {
    await expect(insertMember("m1", "u2", "superjefe")).rejects.toThrow(/CHECK constraint failed/);
    await expect(
      env.DB.prepare("UPDATE clubs SET status = 'borrado' WHERE id = 'c1'").run(),
    ).rejects.toThrow(/CHECK constraint failed/);
  });
});
```

- [ ] **Step 2: Ver que falla**

Run: `cd backend && npx vitest run test/schema.test.ts`
Expected: FAIL con `no such table: clubs`.

- [ ] **Step 3: Implementar**

`backend/migrations/0002_servidores.sql`:

```sql
-- Servidores (en el código, `clubs`), miembros, invitaciones y registro de auditoría.

CREATE TABLE clubs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'rejected', 'suspended')),
  owner_user_id TEXT NOT NULL,
  request_note TEXT NOT NULL DEFAULT '',
  review_note TEXT,
  reviewed_by TEXT,
  reviewed_at TEXT,
  settings TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX clubs_owner ON clubs (owner_user_id);
CREATE INDEX clubs_status ON clubs (status);

-- La identidad que acumula estadísticas dentro de un servidor. Sin cuenta = `guest` con
-- `user_id` NULL; reclamar el perfil es rellenar `user_id` y pasar a `player`.
CREATE TABLE members (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  user_id TEXT,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'scorer', 'player', 'guest')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'left', 'banned')),
  display_name TEXT NOT NULL,
  nickname TEXT,
  created_by TEXT,
  claimed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK ((role = 'guest') = (user_id IS NULL))
);
CREATE UNIQUE INDEX members_club_user ON members (club_id, user_id) WHERE user_id IS NOT NULL;
CREATE INDEX members_user ON members (user_id);
CREATE INDEX members_club ON members (club_id);

CREATE TABLE invites (
  code TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs (id),
  role TEXT NOT NULL CHECK (role IN ('player', 'scorer', 'admin')),
  target_member_id TEXT REFERENCES members (id),
  max_uses INTEGER NOT NULL CHECK (max_uses BETWEEN 1 AND 100),
  uses INTEGER NOT NULL DEFAULT 0,
  expires_at TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE INDEX invites_club ON invites (club_id);

CREATE TABLE audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  club_id TEXT,
  actor_user_id TEXT NOT NULL,
  action TEXT NOT NULL,
  entity TEXT NOT NULL,
  entity_key TEXT NOT NULL,
  summary TEXT NOT NULL DEFAULT '{}',
  at TEXT NOT NULL
);
CREATE INDEX audit_club ON audit_log (club_id, id);
```

Reemplaza `backend/test/setup.ts` por (cambian el comentario y el `ORDER BY rowid DESC`):

```ts
import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach } from "vitest";

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

// vitest-pool-workers 0.22 aísla la base por archivo de test, pero no entre tests del mismo
// archivo: se vacía antes de cada uno. En orden inverso de creación, para que las tablas hijas
// (con claves foráneas) se vacíen antes que sus padres.
beforeEach(async () => {
  const { results } = await env.DB.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations' ORDER BY rowid DESC",
  ).all<{ name: string }>();
  if (results.length === 0) return;
  await env.DB.batch(results.map((t) => env.DB.prepare(`DELETE FROM "${t.name}"`)));
});
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend/migrations/0002_servidores.sql backend/test/setup.ts backend/test/schema.test.ts
git commit -m "Backend: tablas de servidores, miembros, invitaciones y auditoría"
```

---

### Task 2: Matriz de permisos (`authz.ts`)

**Files:**
- Create: `backend/src/authz.ts`
- Test: `backend/test/authz.test.ts`

**Interfaces:**
- Produces, en `src/authz.ts`:
  - Tipos: `Role`, `InvitableRole` y `MatchdayCreators`.
  - Comprobaciones por rol: `isStaff(role)`, `isAdmin(role)`, `canManageClub(actor)`, `canManageInvites(actor)`, `canManageSeasons(actor)`, `canActForOthers(actor)`, `canDecideReports(actor)` y `canActForSelf(actor)`.
  - Comprobaciones sobre otro miembro: `canInviteAs(actor, invited)`, `canIssueRecoveryCode(actor, target)`, `canSetRole(actor, target, newRole)` y `canBan(actor, target)`.
  - Jornadas: `canCreateMatchday(actor, creators)`, `canEditMatchday(actor, { isCreator })` y `canManageMatchday(actor, { isCreator, hasOthersData })`.
  - Todas devuelven `boolean`. Las de jornadas, roles y expulsiones las consume el PR3.

- [ ] **Step 1: Escribir el test que falla**

`backend/test/authz.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  canActForOthers,
  canActForSelf,
  canBan,
  canCreateMatchday,
  canDecideReports,
  canEditMatchday,
  canInviteAs,
  canIssueRecoveryCode,
  canManageClub,
  canManageInvites,
  canManageMatchday,
  canManageSeasons,
  canSetRole,
  type Role,
} from "../src/authz";

const ROLES: Role[] = ["owner", "admin", "scorer", "player", "guest"];
/** Quién tiene el permiso, en el orden de ROLES. */
const who = (f: (r: Role) => boolean) => ROLES.filter(f);

describe("matriz de permisos (spec §4)", () => {
  it("ajustes y transferir: solo owner", () => expect(who(canManageClub)).toEqual(["owner"]));
  it("ver y revocar invitaciones: owner y admin", () => expect(who(canManageInvites)).toEqual(["owner", "admin"]));
  it("temporadas: owner y admin", () => expect(who(canManageSeasons)).toEqual(["owner", "admin"]));
  it("decidir reportes: owner y admin", () => expect(who(canDecideReports)).toEqual(["owner", "admin"]));
  it("pasar lista, cargar por otros, sin cuenta, equipos: staff", () =>
    expect(who(canActForOthers)).toEqual(["owner", "admin", "scorer"]));
  it("acciones propias: todos los que tienen cuenta", () =>
    expect(who(canActForSelf)).toEqual(["owner", "admin", "scorer", "player"]));

  it("invitar: owner con cualquier rol; admin solo player o scorer", () => {
    expect(who((r) => canInviteAs(r, "admin"))).toEqual(["owner"]);
    expect(who((r) => canInviteAs(r, "scorer"))).toEqual(["owner", "admin"]);
    expect(who((r) => canInviteAs(r, "player"))).toEqual(["owner", "admin"]);
  });

  it("códigos de recuperación: owner para todos menos sí mismo; admin para scorer y player", () => {
    expect(who((r) => canIssueRecoveryCode(r, "admin"))).toEqual(["owner"]);
    expect(who((r) => canIssueRecoveryCode(r, "player"))).toEqual(["owner", "admin"]);
    expect(who((r) => canIssueRecoveryCode(r, "owner"))).toEqual([]);
    expect(who((r) => canIssueRecoveryCode(r, "guest"))).toEqual([]);
  });

  it("roles: el owner nombra y quita admins; un admin solo mueve entre scorer y player", () => {
    expect(canSetRole("owner", "player", "admin")).toBe(true);
    expect(canSetRole("owner", "admin", "player")).toBe(true);
    expect(canSetRole("admin", "player", "scorer")).toBe(true);
    expect(canSetRole("admin", "player", "admin")).toBe(false);
    expect(canSetRole("admin", "admin", "player")).toBe(false);
    expect(canSetRole("scorer", "player", "scorer")).toBe(false);
  });

  it("nadie se vuelve owner cambiando el rol, ni se le cambia el rol a un sin cuenta", () => {
    for (const actor of ROLES) {
      expect(canSetRole(actor, "admin", "owner")).toBe(false);
      expect(canSetRole(actor, "owner", "admin")).toBe(false);
      expect(canSetRole(actor, "guest", "player")).toBe(false);
    }
  });

  it("expulsar: owner a cualquiera menos al owner; admin a scorer, player o sin cuenta", () => {
    expect(who((r) => canBan(r, "admin"))).toEqual(["owner"]);
    expect(who((r) => canBan(r, "guest"))).toEqual(["owner", "admin"]);
    expect(who((r) => canBan(r, "owner"))).toEqual([]);
  });

  it("crear jornadas: staff siempre; player solo si el servidor deja a cualquier miembro", () => {
    expect(who((r) => canCreateMatchday(r, "members"))).toEqual(["owner", "admin", "scorer", "player"]);
    expect(who((r) => canCreateMatchday(r, "staff"))).toEqual(["owner", "admin", "scorer"]);
  });

  it("editar jornadas: staff, o el player que la creó", () => {
    expect(canEditMatchday("player", { isCreator: true })).toBe(true);
    expect(canEditMatchday("player", { isCreator: false })).toBe(false);
    expect(canEditMatchday("scorer", { isCreator: false })).toBe(true);
  });

  it("cancelar o borrar jornadas: el player creador solo si nadie más cargó datos", () => {
    expect(canManageMatchday("player", { isCreator: true, hasOthersData: false })).toBe(true);
    expect(canManageMatchday("player", { isCreator: true, hasOthersData: true })).toBe(false);
    expect(canManageMatchday("admin", { isCreator: false, hasOthersData: true })).toBe(true);
    expect(canManageMatchday("guest", { isCreator: true, hasOthersData: false })).toBe(false);
  });
});
```

- [ ] **Step 2: Ver que falla**

Run: `cd backend && npx vitest run test/authz.test.ts`
Expected: FAIL, no se puede resolver `../src/authz`.

- [ ] **Step 3: Implementar**

`backend/src/authz.ts`:

```ts
/**
 * Quién puede hacer qué dentro de un servidor (spec §4). Funciones puras: el único sitio donde se
 * decide un permiso. Los endpoints y, desde el PR3, los comandos de sync preguntan aquí.
 */

export type Role = "owner" | "admin" | "scorer" | "player" | "guest";
export type InvitableRole = "player" | "scorer" | "admin";
export type MatchdayCreators = "members" | "staff";

const RANK: Record<Role, number> = { guest: 0, player: 1, scorer: 2, admin: 3, owner: 4 };

/** owner, admin o scorer. */
export const isStaff = (role: Role) => RANK[role] >= RANK.scorer;
/** owner o admin. */
export const isAdmin = (role: Role) => RANK[role] >= RANK.admin;

/** Ajustes del servidor y transferir la propiedad: solo el owner. */
export const canManageClub = (actor: Role) => actor === "owner";

/** El owner invita con cualquier rol; un admin, solo como player o scorer. */
export function canInviteAs(actor: Role, invited: InvitableRole) {
  if (actor === "owner") return true;
  return actor === "admin" && invited !== "admin";
}

/** Ver y revocar invitaciones. */
export const canManageInvites = (actor: Role) => isAdmin(actor);

/** El owner, para cualquier miembro con cuenta; un admin, solo para scorer o player. */
export function canIssueRecoveryCode(actor: Role, target: Role) {
  if (target === "guest") return false;
  if (actor === "owner") return target !== "owner";
  return actor === "admin" && (target === "scorer" || target === "player");
}

/**
 * Cambiar el rol de alguien. El owner nombra o quita admins; un admin solo mueve entre scorer y
 * player. Nadie se convierte en owner por aquí (eso es transferir), y a los sin cuenta no se les
 * cambia el rol (primero tienen que reclamar el perfil).
 */
export function canSetRole(actor: Role, target: Role, newRole: Role) {
  if (target === "owner" || newRole === "owner" || target === "guest" || newRole === "guest") return false;
  if (actor === "owner") return true;
  if (actor !== "admin") return false;
  const lower = (r: Role) => r === "scorer" || r === "player";
  return lower(target) && lower(newRole);
}

/** Expulsar: el owner a cualquiera menos a sí mismo; un admin, a scorer, player o sin cuenta. */
export function canBan(actor: Role, target: Role) {
  if (target === "owner") return false;
  if (actor === "owner") return true;
  return actor === "admin" && RANK[target] <= RANK.scorer;
}

export const canManageSeasons = (actor: Role) => isAdmin(actor);

export function canCreateMatchday(actor: Role, creators: MatchdayCreators) {
  if (isStaff(actor)) return true;
  return actor === "player" && creators === "members";
}

export function canEditMatchday(actor: Role, ctx: { isCreator: boolean }) {
  return isStaff(actor) || (actor === "player" && ctx.isCreator);
}

/** Cancelar, cerrar, reabrir, borrar o unir jornadas. */
export function canManageMatchday(actor: Role, ctx: { isCreator: boolean; hasOthersData: boolean }) {
  return isStaff(actor) || (actor === "player" && ctx.isCreator && !ctx.hasOthersData);
}

/** Pasar lista, cargar estadísticas de cualquiera, crear jugadores sin cuenta, guardar equipos. */
export const canActForOthers = (actor: Role) => isStaff(actor);

/** Confirmar, rechazar o corregir reportes. */
export const canDecideReports = (actor: Role) => isAdmin(actor);

/** Asistencia propia, reporte propio, confirmar otros, votar MVP. Todos los que tienen cuenta. */
export const canActForSelf = (actor: Role) => actor !== "guest";
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run test/authz.test.ts && npx tsc -p .`
Expected: PASS (14 tests), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend/src/authz.ts backend/test/authz.test.ts
git commit -m "Backend: matriz de permisos por rol dentro de un servidor"
```

---

### Task 3: Solicitar un servidor y `GET /me` con servidores

**Files:**
- Create:
  - `backend/src/audit.ts`
  - `backend/src/clubs/model.ts`, `backend/src/clubs/schemas.ts`, `backend/src/clubs/routes.ts`
  - `backend/test/fixtures.ts`, `backend/test/clubs.test.ts`
- Modify:
  - `backend/src/http/errors.ts`, `backend/src/index.ts`, `backend/src/me/routes.ts`
  - `backend/test/me.test.ts`

**Interfaces:**
- Consumes:
  - `requireAuth` y `readJson` (PR1);
  - tipos `Role` y `MatchdayCreators` (Task 2).
- Produces:
  - `src/audit.ts`: `auditStatement(db, { clubId, actorUserId, action, entity, entityKey, summary? }, now)`, que devuelve una `D1PreparedStatement`.
  - `src/clubs/model.ts`:
    - tipos `ClubStatus`, `MemberStatus`, `ClubSettings`, `ClubRecord` y `MemberRecord`;
    - `DEFAULT_SETTINGS`;
    - `findClub(db, clubId)`, `findMember(db, clubId, memberId)` y `findMemberByUser(db, clubId, userId)`;
    - `requireMembership(db, clubId, userId) → { club, member }`, que lanza 404;
    - `assertWritable(club)`, que lanza 403 `club_suspended`.
  - `errors.*` nuevos: `forbidden`, `clubSuspended`, `invalidState(message)`, `tooManyClubs`, `alreadyMember`, `bannedFromClub`, `inviteInvalid` y `ownerMustTransfer`.
  - `src/clubs/routes.ts`: `clubRoutes`, montada en `/clubs`.
  - `test/fixtures.ts`: `superadmin(username?)`, `requestClub(token, name?, extra?)` y `auditActions(clubId | null)`.
  - `GET /me` → `{ user, clubs: [{ id, name, status, memberId, role }], clubRequests: [{ id, name, status, reviewNote, createdAt }] }`.

- [ ] **Step 1: Escribir los tests que fallan**

`backend/test/fixtures.ts`. La Task 4 lo amplía:

```ts
import { env } from "cloudflare:workers";
import { expect } from "vitest";
import { api, register } from "./helpers";

/** Registra un usuario y lo marca como superadmin (en producción se hace con `wrangler d1 execute`). */
export async function superadmin(username = "superadmin") {
  const reg = await register(username, "secreto123", "Súper");
  await env.DB.prepare("UPDATE users SET is_superadmin = 1 WHERE id = ?").bind(reg.user.id).run();
  return reg;
}

/** Pide un servidor con la API y devuelve su id. */
export async function requestClub(token: string, name = "Pachanga del sábado", extra: Record<string, unknown> = {}) {
  const res = await api("/clubs", { token, body: { name, ...extra } });
  expect(res.status).toBe(201);
  return res.body.club.id as string;
}

export async function auditActions(clubId: string | null) {
  const { results } = await env.DB.prepare(
    "SELECT action FROM audit_log WHERE club_id IS ? ORDER BY id",
  )
    .bind(clubId)
    .all<{ action: string }>();
  return results.map((r) => r.action);
}
```

`backend/test/clubs.test.ts`. La Task 4 le añade el `describe` de `GET /me con servidores`:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { auditActions, requestClub } from "./fixtures";
import { api, register } from "./helpers";

describe("POST /clubs (solicitar servidor)", () => {
  it("queda pendiente, con los ajustes por defecto, y aparece en /me como solicitud", async () => {
    const { token } = await register("kevin");
    const res = await api("/clubs", {
      token,
      body: { name: "  Pachanga del sábado ", description: "Cancha de 23", requestNote: "Somos 20" },
    });
    expect(res.status).toBe(201);
    expect(res.body.club).toMatchObject({ name: "Pachanga del sábado", status: "pending" });

    const row = await env.DB.prepare("SELECT settings FROM clubs WHERE id = ?").bind(res.body.club.id).first<{ settings: string }>();
    expect(JSON.parse(row!.settings)).toEqual({
      matchdayCreators: "members",
      reportValidation: "confirm",
      confirmationsNeeded: 2,
      closeAfterHours: 72,
      timezone: "America/Havana",
    });

    const me = await api("/me", { token });
    expect(me.body.clubs).toEqual([]);
    expect(me.body.clubRequests).toMatchObject([{ id: res.body.club.id, name: "Pachanga del sábado", status: "pending", reviewNote: null }]);
    expect(await auditActions(res.body.club.id)).toEqual(["club.request"]);
  });

  it("exige sesión y un nombre de 3 a 40 caracteres", async () => {
    expect((await api("/clubs", { body: { name: "Pachanga" } })).status).toBe(401);
    const { token } = await register("kevin");
    const res = await api("/clubs", { token, body: { name: "ab" } });
    expect(res.status).toBe(400);
    expect(res.body.error.details.name).toEqual(["Mínimo 3 caracteres"]);
  });

  it("como mucho 3 servidores pendientes o activos por persona; los rechazados no cuentan", async () => {
    const { token, user } = await register("kevin");
    for (const n of ["Uno", "Dos", "Tres"]) await requestClub(token, `Servidor ${n}`);
    const fourth = await api("/clubs", { token, body: { name: "Servidor Cuatro" } });
    expect(fourth.status).toBe(409);
    expect(fourth.body.error.code).toBe("too_many_clubs");

    await env.DB.prepare("UPDATE clubs SET status = 'rejected' WHERE owner_user_id = ? AND name = 'Servidor Uno'").bind(user.id).run();
    expect((await api("/clubs", { token, body: { name: "Servidor Cuatro" } })).status).toBe(201);
  });
});
```

En `backend/test/me.test.ts`, reemplaza el test `"GET devuelve el usuario y, por ahora, ningún servidor"` por:

```ts
  it("GET devuelve el usuario, sin servidores ni solicitudes al principio", async () => {
    const { token, user } = await register();
    const res = await api("/me", { token });
    expect(res.body).toEqual({ user, clubs: [], clubRequests: [] });
  });
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/clubs.test.ts test/me.test.ts`
Expected: FAIL. `POST /clubs` da 404 y `GET /me` no trae `clubRequests`.

- [ ] **Step 3: Implementar**

En `backend/src/http/errors.ts`, añade al final del objeto `errors` (después de `notFound`):

```ts
  forbidden: () => new ApiError(403, "forbidden", "No tienes permiso para hacer esto"),
  clubSuspended: () =>
    new ApiError(403, "club_suspended", "Este servidor está suspendido: solo se puede consultar"),
  invalidState: (message: string) => new ApiError(409, "invalid_state", message),
  tooManyClubs: () =>
    new ApiError(409, "too_many_clubs", "Ya tienes 3 servidores activos o pendientes de aprobación"),
  alreadyMember: () => new ApiError(409, "already_member", "Ya tienes un perfil en este servidor"),
  bannedFromClub: () => new ApiError(403, "banned_from_club", "No puedes volver a entrar en este servidor"),
  inviteInvalid: () =>
    new ApiError(404, "invite_invalid", "La invitación no existe, caducó o ya se usó"),
  ownerMustTransfer: () =>
    new ApiError(409, "owner_must_transfer", "Eres dueño de un servidor: transfiérelo antes de borrar tu cuenta"),
```

`backend/src/audit.ts`:

```ts
export type AuditEntry = {
  clubId: string | null;
  actorUserId: string;
  action: string;
  entity: string;
  entityKey: string;
  summary?: Record<string, unknown>;
};

/** Una fila del registro de auditoría, para meterla en el mismo `batch` que el cambio. */
export function auditStatement(db: D1Database, entry: AuditEntry, now: Date) {
  return db
    .prepare(
      "INSERT INTO audit_log (club_id, actor_user_id, action, entity, entity_key, summary, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(
      entry.clubId,
      entry.actorUserId,
      entry.action,
      entry.entity,
      entry.entityKey,
      JSON.stringify(entry.summary ?? {}),
      now.toISOString(),
    );
}
```

`backend/src/clubs/model.ts`:

```ts
import type { MatchdayCreators, Role } from "../authz";
import { errors } from "../http/errors";

export type ClubStatus = "pending" | "active" | "rejected" | "suspended";
export type MemberStatus = "active" | "left" | "banned";

export type ClubSettings = {
  matchdayCreators: MatchdayCreators;
  reportValidation: "confirm" | "trust";
  confirmationsNeeded: number;
  closeAfterHours: number;
  timezone: string;
};

export const DEFAULT_SETTINGS: ClubSettings = {
  matchdayCreators: "members",
  reportValidation: "confirm",
  confirmationsNeeded: 2,
  closeAfterHours: 72,
  timezone: "America/Havana",
};

export type ClubRecord = {
  id: string;
  name: string;
  description: string;
  status: ClubStatus;
  ownerUserId: string;
  settings: ClubSettings;
};

export type MemberRecord = {
  id: string;
  clubId: string;
  userId: string | null;
  role: Role;
  status: MemberStatus;
  displayName: string;
};

type ClubRow = {
  id: string;
  name: string;
  description: string;
  status: ClubStatus;
  owner_user_id: string;
  settings: string;
};

type MemberRow = {
  id: string;
  club_id: string;
  user_id: string | null;
  role: Role;
  status: MemberStatus;
  display_name: string;
};

const clubFromRow = (r: ClubRow): ClubRecord => ({
  id: r.id,
  name: r.name,
  description: r.description,
  status: r.status,
  ownerUserId: r.owner_user_id,
  settings: { ...DEFAULT_SETTINGS, ...(JSON.parse(r.settings) as Partial<ClubSettings>) },
});

const memberFromRow = (r: MemberRow): MemberRecord => ({
  id: r.id,
  clubId: r.club_id,
  userId: r.user_id,
  role: r.role,
  status: r.status,
  displayName: r.display_name,
});

export async function findClub(db: D1Database, clubId: string) {
  const row = await db
    .prepare("SELECT id, name, description, status, owner_user_id, settings FROM clubs WHERE id = ?")
    .bind(clubId)
    .first<ClubRow>();
  return row ? clubFromRow(row) : null;
}

const MEMBER_COLUMNS = "id, club_id, user_id, role, status, display_name";

export async function findMember(db: D1Database, clubId: string, memberId: string) {
  const row = await db
    .prepare(`SELECT ${MEMBER_COLUMNS} FROM members WHERE club_id = ? AND id = ?`)
    .bind(clubId, memberId)
    .first<MemberRow>();
  return row ? memberFromRow(row) : null;
}

export async function findMemberByUser(db: D1Database, clubId: string, userId: string) {
  const row = await db
    .prepare(`SELECT ${MEMBER_COLUMNS} FROM members WHERE club_id = ? AND user_id = ?`)
    .bind(clubId, userId)
    .first<MemberRow>();
  return row ? memberFromRow(row) : null;
}

/**
 * El usuario tiene que ser miembro activo de un servidor activo o suspendido. Si no, 404: a
 * quien no es miembro no se le confirma ni que el servidor existe.
 */
export async function requireMembership(db: D1Database, clubId: string, userId: string) {
  const club = await findClub(db, clubId);
  if (!club || (club.status !== "active" && club.status !== "suspended")) throw errors.notFound();
  const member = await findMemberByUser(db, clubId, userId);
  if (!member || member.status !== "active") throw errors.notFound();
  return { club, member };
}

/** Para cambiar algo: además, el servidor no puede estar suspendido. */
export function assertWritable(club: ClubRecord) {
  if (club.status === "suspended") throw errors.clubSuspended();
}
```

`backend/src/clubs/schemas.ts`. La Task 6 le añade `createInviteSchema`:

```ts
import { z } from "zod";

export const clubRequestSchema = z.object({
  name: z.string().trim().min(3, { error: "Mínimo 3 caracteres" }).max(40, { error: "Máximo 40 caracteres" }),
  description: z.string().trim().max(200).default(""),
  requestNote: z.string().trim().max(300).default(""),
});
```

`backend/src/clubs/routes.ts`. Las Tasks 6 y 8 le añaden rutas:

```ts
import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { DEFAULT_SETTINGS } from "./model";
import { clubRequestSchema } from "./schemas";

const MAX_OWNED_CLUBS = 3;

export const clubRoutes = new Hono<AppEnv>();

clubRoutes.use(requireAuth);

/** Solicitar un servidor. Queda `pending` hasta que el superadmin lo apruebe. */
clubRoutes.post("/", async (c) => {
  const body = await readJson(c, clubRequestSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;

  const owned = await db
    .prepare("SELECT COUNT(*) AS n FROM clubs WHERE owner_user_id = ? AND status IN ('pending', 'active')")
    .bind(userId)
    .first<{ n: number }>();
  if (owned!.n >= MAX_OWNED_CLUBS) throw errors.tooManyClubs();

  const id = crypto.randomUUID();
  const at = now.toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO clubs (id, name, description, status, owner_user_id, request_note, settings, created_at, updated_at)
         VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)`,
      )
      .bind(id, body.name, body.description, userId, body.requestNote, JSON.stringify(DEFAULT_SETTINGS), at, at),
    auditStatement(db, { clubId: id, actorUserId: userId, action: "club.request", entity: "club", entityKey: id }, now),
  ]);
  return c.json({ club: { id, name: body.name, status: "pending" } }, 201);
});

```

En `backend/src/index.ts`, añade el import y monta la ruta después de `/me`:

```ts
import { clubRoutes } from "./clubs/routes";
```

```ts
app.route("/clubs", clubRoutes);
```

Reemplaza `backend/src/me/routes.ts` por. Cambia el `GET`; el `DELETE` sigue igual hasta la Task 9:

```ts
import { Hono } from "hono";
import { verifyPassword } from "../auth/crypto";
import { requireAuth } from "../auth/middleware";
import { assertNotLocked, authLimits, recordAttempt } from "../auth/rate-limit";
import { confirmPasswordSchema } from "../auth/schemas";
import { deleteUserSessionsStatement } from "../auth/sessions";
import { findUserById } from "../auth/users";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";

export const meRoutes = new Hono<AppEnv>();

meRoutes.use(requireAuth);

/** El usuario, los servidores donde es miembro activo y sus solicitudes pendientes o rechazadas. */
meRoutes.get("/", async (c) => {
  const db = c.env.DB;
  const userId = c.var.auth.user.id;
  const clubs = await db
    .prepare(
      `SELECT c.id, c.name, c.status, m.id AS member_id, m.role
         FROM members m JOIN clubs c ON c.id = m.club_id
        WHERE m.user_id = ? AND m.status = 'active' AND c.status IN ('active', 'suspended')
        ORDER BY c.name`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; member_id: string; role: string }>();
  const requests = await db
    .prepare(
      `SELECT id, name, status, review_note, created_at FROM clubs
        WHERE owner_user_id = ? AND status IN ('pending', 'rejected') ORDER BY created_at DESC`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; review_note: string | null; created_at: string }>();
  return c.json({
    user: c.var.auth.user,
    clubs: clubs.results.map((r) => ({ id: r.id, name: r.name, status: r.status, memberId: r.member_id, role: r.role })),
    clubRequests: requests.results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      reviewNote: r.review_note,
      createdAt: r.created_at,
    })),
  });
});

meRoutes.delete("/", async (c) => {
  const body = await readJson(c, confirmPasswordSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const rateLimits = authLimits.login(c.var.auth.user.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = (await findUserById(db, userId))!;
  if (!(await verifyPassword(body.password, user.passwordHash))) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  await db.batch([
    deleteUserSessionsStatement(db, userId),
    db.prepare("DELETE FROM recovery_codes WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ]);
  return c.body(null, 204);
});
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: solicitar un servidor y ver mis servidores y solicitudes en /me"
```

---

### Task 4: Superadmin · servidores

**Files:**
- Create: `backend/src/superadmin/routes.ts`, `backend/test/superadmin.test.ts`
- Modify: `backend/src/index.ts`, `backend/test/fixtures.ts`, `backend/test/clubs.test.ts`

**Interfaces:**
- Consumes:
  - `findClub`, `findMember` y `ClubStatus` (Task 3);
  - `auditStatement` (Task 3);
  - `findUserById` (PR1);
  - `errors.forbidden` y `errors.invalidState` (Task 3).
- Produces:
  - `superadminRoutes`, montada en `/admin` y protegida con `requireAuth` y `requireSuperadmin` (403 si no lo es).
  - Endpoints:
    - `GET /admin/clubs?status=&q=` → `{ clubs: [{ id, name, status, requestNote, createdAt, ownerUsername, members }] }`
    - `GET /admin/clubs/:id` → `{ club, owner, membersByRole }`
    - `POST /admin/clubs/:id/approve`, `/reject { note }`, `/suspend { note }` y `/reactivate` → `{ club: { id, status } }`
    - `POST /admin/clubs/:id/transfer { memberId }` → `{ club: { id, ownerUserId } }`
  - En `test/fixtures.ts`: `activeClub(ownerUsername?, name?) → { clubId, owner, admin }`, `addMember(clubId, username, role) → Registered & { memberId }`, `addGuest(clubId, displayName?) → memberId` y `ownerMemberId(clubId)`.

- [ ] **Step 1: Escribir los tests que fallan**

Reemplaza `backend/test/fixtures.ts` por la versión completa:

```ts
import { env } from "cloudflare:workers";
import { expect } from "vitest";
import type { Role } from "../src/authz";
import { api, register, type Registered } from "./helpers";

/** Registra un usuario y lo marca como superadmin (en producción se hace con `wrangler d1 execute`). */
export async function superadmin(username = "superadmin") {
  const reg = await register(username, "secreto123", "Súper");
  await env.DB.prepare("UPDATE users SET is_superadmin = 1 WHERE id = ?").bind(reg.user.id).run();
  return reg;
}

/** Pide un servidor con la API y devuelve su id. */
export async function requestClub(token: string, name = "Pachanga del sábado", extra: Record<string, unknown> = {}) {
  const res = await api("/clubs", { token, body: { name, ...extra } });
  expect(res.status).toBe(201);
  return res.body.club.id as string;
}

export type ActiveClub = { clubId: string; owner: Registered; admin: Registered };

/** Un servidor aprobado de punta a punta por la API: dueño + superadmin. */
export async function activeClub(ownerUsername = "dueno", name = "Pachanga del sábado"): Promise<ActiveClub> {
  const owner = await register(ownerUsername, "secreto123", "Dueño");
  const admin = await superadmin(`super.${ownerUsername}`);
  const clubId = await requestClub(owner.token, name);
  const res = await api(`/admin/clubs/${clubId}/approve`, { method: "POST", token: admin.token });
  expect(res.status).toBe(200);
  return { clubId, owner, admin };
}

/** Mete a un usuario nuevo como miembro con `role`, directo en la base (sin invitación). */
export async function addMember(clubId: string, username: string, role: Exclude<Role, "guest">) {
  const reg = await register(username, "secreto123", username);
  const memberId = crypto.randomUUID();
  const at = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(memberId, clubId, reg.user.id, role, username, at, at)
    .run();
  return { ...reg, memberId };
}

/** Un jugador sin cuenta (en el PR3 los creará el comando `member.createGuest`). */
export async function addGuest(clubId: string, displayName = "Yoandry") {
  const memberId = crypto.randomUUID();
  const at = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, NULL, 'guest', ?, ?, ?)",
  )
    .bind(memberId, clubId, displayName, at, at)
    .run();
  return memberId;
}

export async function ownerMemberId(clubId: string) {
  const row = await env.DB.prepare("SELECT id FROM members WHERE club_id = ? AND role = 'owner'")
    .bind(clubId)
    .first<{ id: string }>();
  return row!.id;
}

export async function auditActions(clubId: string | null) {
  const { results } = await env.DB.prepare(
    "SELECT action FROM audit_log WHERE club_id IS ? ORDER BY id",
  )
    .bind(clubId)
    .all<{ action: string }>();
  return results.map((r) => r.action);
}
```

`backend/test/superadmin.test.ts`. La Task 5 le añade el `describe` de usuarios y métricas:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, ownerMemberId, requestClub, superadmin } from "./fixtures";
import { api, register } from "./helpers";

const post = (path: string, token: string, body?: unknown) => api(path, { method: "POST", token, body });

describe("panel del superadmin: acceso", () => {
  it("un usuario normal recibe 403 en todo /admin", async () => {
    const { token } = await register("kevin");
    for (const path of ["/admin/clubs", "/admin/users", "/admin/metrics"]) {
      const res = await api(path, { token });
      expect(res.status, path).toBe(403);
      expect(res.body.error.code).toBe("forbidden");
    }
  });
});

describe("panel del superadmin: servidores", () => {
  it("lista las solicitudes pendientes con el dueño y la nota", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const id = await requestClub(owner.token, "Pachanga", { requestNote: "Somos 20 en Centro Habana" });
    const res = await api("/admin/clubs?status=pending", { token: admin.token });
    expect(res.body.clubs).toMatchObject([
      { id, name: "Pachanga", status: "pending", ownerUsername: "kevin", requestNote: "Somos 20 en Centro Habana", members: 0 },
    ]);
    expect((await api("/admin/clubs?status=active", { token: admin.token })).body.clubs).toEqual([]);
    expect((await api("/admin/clubs?status=raro", { token: admin.token })).status).toBe(400);
  });

  it("busca por nombre o por usuario del dueño, sin que % o _ hagan de comodín", async () => {
    const admin = await superadmin();
    const a = await register("kevin");
    const b = await register("raul");
    await requestClub(a.token, "Fútbol 100%");
    await requestClub(b.token, "Los del barrio");
    const search = async (q: string) =>
      (await api(`/admin/clubs?q=${encodeURIComponent(q)}`, { token: admin.token })).body.clubs.map((c: { name: string }) => c.name);
    expect(await search("barrio")).toEqual(["Los del barrio"]);
    expect(await search("RAUL")).toEqual(["Los del barrio"]);
    expect(await search("100%")).toEqual(["Fútbol 100%"]);
    expect(await search("%")).toEqual(["Fútbol 100%"]);
  });

  it("aprobar: pasa a activo, el solicitante queda como owner y se audita", async () => {
    const { clubId, owner } = await activeClub("kevin");
    const member = await env.DB.prepare("SELECT user_id, role, display_name FROM members WHERE club_id = ?")
      .bind(clubId)
      .first<{ user_id: string; role: string; display_name: string }>();
    expect(member).toEqual({ user_id: owner.user.id, role: "owner", display_name: "Dueño" });
    expect(await auditActions(clubId)).toEqual(["club.request", "club.approve"]);
  });

  it("solo se aprueba o rechaza lo pendiente: 409 si ya está activo", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const res = await post(`/admin/clubs/${clubId}/approve`, admin.token);
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("invalid_state");
    expect((await post(`/admin/clubs/${clubId}/reject`, admin.token, {})).status).toBe(409);
    expect((await post("/admin/clubs/no-existe/approve", admin.token)).status).toBe(404);
  });

  it("rechazar con motivo: el solicitante lo ve en /me", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const id = await requestClub(owner.token);
    const res = await post(`/admin/clubs/${id}/reject`, admin.token, { note: "Nombre ofensivo" });
    expect(res.body.club.status).toBe("rejected");
    const me = await api("/me", { token: owner.token });
    expect(me.body.clubRequests).toMatchObject([{ id, status: "rejected", reviewNote: "Nombre ofensivo" }]);
  });

  it("suspender y reactivar; el detalle muestra dueño y miembros por rol", async () => {
    const { clubId, admin } = await activeClub("kevin");
    await addMember(clubId, "raul", "player");
    await addGuest(clubId);
    expect((await post(`/admin/clubs/${clubId}/suspend`, admin.token, { note: "Spam" })).body.club.status).toBe("suspended");
    const detail = await api(`/admin/clubs/${clubId}`, { token: admin.token });
    expect(detail.body).toMatchObject({
      club: { status: "suspended" },
      owner: { username: "kevin" },
      membersByRole: { owner: 1, player: 1, guest: 1 },
    });
    expect((await post(`/admin/clubs/${clubId}/reactivate`, admin.token)).body.club.status).toBe("active");
    expect(await auditActions(clubId)).toEqual(["club.request", "club.approve", "club.suspend", "club.reactivate"]);
  });

  it("transferir: el elegido pasa a owner y el anterior a admin", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const oldOwnerMember = await ownerMemberId(clubId);
    const raul = await addMember(clubId, "raul", "player");
    const res = await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: raul.memberId });
    expect(res.status).toBe(200);
    const roles = await env.DB.prepare("SELECT id, role FROM members WHERE club_id = ? ORDER BY role").bind(clubId).all();
    expect(roles.results).toEqual(
      expect.arrayContaining([
        { id: oldOwnerMember, role: "admin" },
        { id: raul.memberId, role: "owner" },
      ]),
    );
    const club = await env.DB.prepare("SELECT owner_user_id FROM clubs WHERE id = ?").bind(clubId).first<{ owner_user_id: string }>();
    expect(club!.owner_user_id).toBe(raul.user.id);
  });

  it("no se transfiere a un jugador sin cuenta ni a alguien de otro servidor", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const guest = await addGuest(clubId);
    const other = await activeClub("raul", "Otro servidor");
    const outsider = await addMember(other.clubId, "pepe", "player");
    expect((await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: guest })).status).toBe(400);
    expect((await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: outsider.memberId })).status).toBe(400);
  });
});
```

Reemplaza `backend/test/clubs.test.ts` por la versión completa:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, auditActions, requestClub } from "./fixtures";
import { api, register } from "./helpers";

describe("POST /clubs (solicitar servidor)", () => {
  it("queda pendiente, con los ajustes por defecto, y aparece en /me como solicitud", async () => {
    const { token } = await register("kevin");
    const res = await api("/clubs", {
      token,
      body: { name: "  Pachanga del sábado ", description: "Cancha de 23", requestNote: "Somos 20" },
    });
    expect(res.status).toBe(201);
    expect(res.body.club).toMatchObject({ name: "Pachanga del sábado", status: "pending" });

    const row = await env.DB.prepare("SELECT settings FROM clubs WHERE id = ?").bind(res.body.club.id).first<{ settings: string }>();
    expect(JSON.parse(row!.settings)).toEqual({
      matchdayCreators: "members",
      reportValidation: "confirm",
      confirmationsNeeded: 2,
      closeAfterHours: 72,
      timezone: "America/Havana",
    });

    const me = await api("/me", { token });
    expect(me.body.clubs).toEqual([]);
    expect(me.body.clubRequests).toMatchObject([{ id: res.body.club.id, name: "Pachanga del sábado", status: "pending", reviewNote: null }]);
    expect(await auditActions(res.body.club.id)).toEqual(["club.request"]);
  });

  it("exige sesión y un nombre de 3 a 40 caracteres", async () => {
    expect((await api("/clubs", { body: { name: "Pachanga" } })).status).toBe(401);
    const { token } = await register("kevin");
    const res = await api("/clubs", { token, body: { name: "ab" } });
    expect(res.status).toBe(400);
    expect(res.body.error.details.name).toEqual(["Mínimo 3 caracteres"]);
  });

  it("como mucho 3 servidores pendientes o activos por persona; los rechazados no cuentan", async () => {
    const { token, user } = await register("kevin");
    for (const n of ["Uno", "Dos", "Tres"]) await requestClub(token, `Servidor ${n}`);
    const fourth = await api("/clubs", { token, body: { name: "Servidor Cuatro" } });
    expect(fourth.status).toBe(409);
    expect(fourth.body.error.code).toBe("too_many_clubs");

    await env.DB.prepare("UPDATE clubs SET status = 'rejected' WHERE owner_user_id = ? AND name = 'Servidor Uno'").bind(user.id).run();
    expect((await api("/clubs", { token, body: { name: "Servidor Cuatro" } })).status).toBe(201);
  });
});

describe("GET /me con servidores", () => {
  it("al aprobarse, el servidor sale en clubs con el rol owner y desaparece de las solicitudes", async () => {
    const { clubId, owner } = await activeClub("kevin");
    const me = await api("/me", { token: owner.token });
    expect(me.body.clubs).toMatchObject([{ id: clubId, name: "Pachanga del sábado", status: "active", role: "owner" }]);
    expect(me.body.clubs[0].memberId).toEqual(expect.any(String));
    expect(me.body.clubRequests).toEqual([]);
  });

  it("no lista servidores de los que se fue ni de los que lo expulsaron", async () => {
    const { clubId, owner } = await activeClub("kevin");
    await env.DB.prepare("UPDATE members SET status = 'left' WHERE club_id = ?").bind(clubId).run();
    expect((await api("/me", { token: owner.token })).body.clubs).toEqual([]);
  });
});
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/superadmin.test.ts test/clubs.test.ts`
Expected: FAIL. `/admin/...` da 404, y `activeClub` falla en su `expect(res.status).toBe(200)`.

- [ ] **Step 3: Implementar**

`backend/src/superadmin/routes.ts`. La Task 5 le añade usuarios y métricas:

```ts
import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import { z } from "zod";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { findUserById } from "../auth/users";
import { findClub, findMember, type ClubStatus } from "../clubs/model";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import type { AppEnv } from "../types";

const requireSuperadmin = createMiddleware<AppEnv>(async (c, next) => {
  if (!c.var.auth.user.isSuperadmin) throw errors.forbidden();
  await next();
});

export const superadminRoutes = new Hono<AppEnv>();

superadminRoutes.use(requireAuth, requireSuperadmin);

const noteSchema = z.object({ note: z.string().trim().max(300).default("") });
const transferSchema = z.object({ memberId: z.string().min(1).max(64) });

/** `?q=` busca en nombre o nombre de usuario del dueño; `\`, `%` y `_` se buscan literalmente. */
function likePattern(q: string) {
  return `%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`;
}

superadminRoutes.get("/clubs", async (c) => {
  const status = z.enum(["pending", "active", "rejected", "suspended"]).optional().safeParse(c.req.query("status"));
  if (!status.success) throw errors.invalidInput({ status: ["Estado no válido"] });
  const q = (c.req.query("q") ?? "").trim().toLowerCase();
  const { results } = await c.env.DB.prepare(
    `SELECT c.id, c.name, c.status, c.request_note, c.created_at, u.username AS owner_username,
            (SELECT COUNT(*) FROM members m WHERE m.club_id = c.id AND m.status = 'active') AS members
       FROM clubs c LEFT JOIN users u ON u.id = c.owner_user_id
      WHERE (?1 IS NULL OR c.status = ?1)
        AND (?2 = '' OR lower(c.name) LIKE ?3 ESCAPE '\\' OR u.username LIKE ?3 ESCAPE '\\')
      ORDER BY c.created_at DESC LIMIT 100`,
  )
    .bind(status.data ?? null, q, likePattern(q))
    .all<{ id: string; name: string; status: ClubStatus; request_note: string; created_at: string; owner_username: string | null; members: number }>();
  return c.json({
    clubs: results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      requestNote: r.request_note,
      createdAt: r.created_at,
      ownerUsername: r.owner_username,
      members: r.members,
    })),
  });
});

superadminRoutes.get("/clubs/:id", async (c) => {
  const club = await findClub(c.env.DB, c.req.param("id"));
  if (!club) throw errors.notFound();
  const { results } = await c.env.DB.prepare(
    "SELECT role, COUNT(*) AS n FROM members WHERE club_id = ? AND status = 'active' GROUP BY role",
  )
    .bind(club.id)
    .all<{ role: string; n: number }>();
  const owner = await findUserById(c.env.DB, club.ownerUserId);
  return c.json({
    club: { id: club.id, name: club.name, description: club.description, status: club.status, settings: club.settings },
    owner: owner ? { id: owner.id, username: owner.username, displayName: owner.displayName } : null,
    membersByRole: Object.fromEntries(results.map((r) => [r.role, r.n])),
  });
});

/** El club, si su estado es uno de `from`; si no, 404 o 409. */
async function loadClubIn(db: D1Database, id: string, from: ClubStatus[]) {
  const club = await findClub(db, id);
  if (!club) throw errors.notFound();
  if (!from.includes(club.status)) throw errors.invalidState(`El servidor está ${club.status}`);
  return club;
}

superadminRoutes.post("/clubs/:id/approve", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const actor = c.var.auth.user.id;
  const club = await loadClubIn(db, c.req.param("id"), ["pending"]);
  const owner = await findUserById(db, club.ownerUserId);
  if (!owner) throw errors.invalidState("El solicitante ya no tiene cuenta");
  await db.batch([
    db
      .prepare("UPDATE clubs SET status = 'active', reviewed_by = ?, reviewed_at = ?, updated_at = ? WHERE id = ?")
      .bind(actor, at, at, club.id),
    db
      .prepare(
        `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
         VALUES (?, ?, ?, 'owner', ?, ?, ?, ?)`,
      )
      .bind(crypto.randomUUID(), club.id, owner.id, owner.displayName, actor, at, at),
    auditStatement(db, { clubId: club.id, actorUserId: actor, action: "club.approve", entity: "club", entityKey: club.id }, now),
  ]);
  return c.json({ club: { id: club.id, status: "active" } });
});

superadminRoutes.post("/clubs/:id/reject", async (c) => {
  const { note } = await readJson(c, noteSchema);
  return c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["pending"], "rejected", "club.reject", note));
});

superadminRoutes.post("/clubs/:id/suspend", async (c) => {
  const { note } = await readJson(c, noteSchema);
  return c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["active"], "suspended", "club.suspend", note));
});

superadminRoutes.post("/clubs/:id/reactivate", async (c) =>
  c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["suspended"], "active", "club.reactivate", null)),
);

async function setClubStatus(
  db: D1Database,
  actor: string,
  id: string,
  from: ClubStatus[],
  to: ClubStatus,
  action: string,
  note: string | null,
) {
  const now = new Date();
  const at = now.toISOString();
  const club = await loadClubIn(db, id, from);
  await db.batch([
    db
      .prepare(
        "UPDATE clubs SET status = ?, review_note = COALESCE(?, review_note), reviewed_by = ?, reviewed_at = ?, updated_at = ? WHERE id = ?",
      )
      .bind(to, note, actor, at, at, club.id),
    auditStatement(db, { clubId: club.id, actorUserId: actor, action, entity: "club", entityKey: club.id, summary: note ? { note } : {} }, now),
  ]);
  return { club: { id: club.id, status: to } };
}

/** El dueño actual pasa a admin y el miembro elegido (con cuenta) pasa a dueño. */
superadminRoutes.post("/clubs/:id/transfer", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const actor = c.var.auth.user.id;
  const { memberId } = await readJson(c, transferSchema);
  const club = await loadClubIn(db, c.req.param("id"), ["active", "suspended"]);
  const target = await findMember(db, club.id, memberId);
  if (!target || target.status !== "active" || !target.userId) {
    throw errors.invalidInput({ memberId: ["Tiene que ser un miembro activo con cuenta"] });
  }
  if (target.role === "owner") throw errors.invalidState("Ese miembro ya es el dueño");
  await db.batch([
    db
      .prepare("UPDATE members SET role = 'admin', updated_at = ? WHERE club_id = ? AND role = 'owner'")
      .bind(at, club.id),
    db.prepare("UPDATE members SET role = 'owner', updated_at = ? WHERE id = ?").bind(at, target.id),
    db.prepare("UPDATE clubs SET owner_user_id = ?, updated_at = ? WHERE id = ?").bind(target.userId, at, club.id),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: actor, action: "club.transfer", entity: "club", entityKey: club.id, summary: { from: club.ownerUserId, to: target.userId } },
      now,
    ),
  ]);
  return c.json({ club: { id: club.id, ownerUserId: target.userId } });
});
```

En `backend/src/index.ts`, añade el import y monta la ruta después de `/clubs`:

```ts
import { superadminRoutes } from "./superadmin/routes";
```

```ts
app.route("/admin", superadminRoutes);
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: panel del superadmin para aprobar, rechazar, suspender y transferir servidores"
```

---

### Task 5: Superadmin · usuarios, códigos de recuperación y métricas

**Files:**
- Create: `backend/src/auth/recovery.ts`
- Modify: `backend/src/superadmin/routes.ts` (reemplazo completo), `backend/test/superadmin.test.ts` (reemplazo completo)

**Interfaces:**
- Consumes:
  - `randomCode`, `normalizeCode` y `sha256Hex` (PR1);
  - la tabla `recovery_codes` (PR1);
  - `auditStatement` (Task 3).
- Produces:
  - `src/auth/recovery.ts`: `issueRecoveryCode(db, userId, createdBy, now) → Promise<{ code: "XXXX-XXXX", expiresAt, statements }>`. Las `statements` anulan los códigos anteriores sin usar e insertan el nuevo.
  - Endpoints:
    - `GET /admin/users?q=` → `{ users: [{ id, username, displayName, status, isSuperadmin, createdAt, lastSeenAt }] }`
    - `POST /admin/users/:id/suspend` y `/unsuspend` → `{ user: { id, status } }`
    - `POST /admin/users/:id/recovery-code` → 201 `{ code, expiresAt }`
    - `GET /admin/metrics` → `{ users: { total, active7d, active30d }, clubs: { pending, active, rejected, suspended } }`

- [ ] **Step 1: Escribir los tests que fallan**

Reemplaza `backend/test/superadmin.test.ts` por la versión completa:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, ownerMemberId, requestClub, superadmin } from "./fixtures";
import { api, login, register } from "./helpers";

const post = (path: string, token: string, body?: unknown) => api(path, { method: "POST", token, body });

describe("panel del superadmin: acceso", () => {
  it("un usuario normal recibe 403 en todo /admin", async () => {
    const { token } = await register("kevin");
    for (const path of ["/admin/clubs", "/admin/users", "/admin/metrics"]) {
      const res = await api(path, { token });
      expect(res.status, path).toBe(403);
      expect(res.body.error.code).toBe("forbidden");
    }
  });
});

describe("panel del superadmin: servidores", () => {
  it("lista las solicitudes pendientes con el dueño y la nota", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const id = await requestClub(owner.token, "Pachanga", { requestNote: "Somos 20 en Centro Habana" });
    const res = await api("/admin/clubs?status=pending", { token: admin.token });
    expect(res.body.clubs).toMatchObject([
      { id, name: "Pachanga", status: "pending", ownerUsername: "kevin", requestNote: "Somos 20 en Centro Habana", members: 0 },
    ]);
    expect((await api("/admin/clubs?status=active", { token: admin.token })).body.clubs).toEqual([]);
    expect((await api("/admin/clubs?status=raro", { token: admin.token })).status).toBe(400);
  });

  it("busca por nombre o por usuario del dueño, sin que % o _ hagan de comodín", async () => {
    const admin = await superadmin();
    const a = await register("kevin");
    const b = await register("raul");
    await requestClub(a.token, "Fútbol 100%");
    await requestClub(b.token, "Los del barrio");
    const search = async (q: string) =>
      (await api(`/admin/clubs?q=${encodeURIComponent(q)}`, { token: admin.token })).body.clubs.map((c: { name: string }) => c.name);
    expect(await search("barrio")).toEqual(["Los del barrio"]);
    expect(await search("RAUL")).toEqual(["Los del barrio"]);
    expect(await search("100%")).toEqual(["Fútbol 100%"]);
    expect(await search("%")).toEqual(["Fútbol 100%"]);
  });

  it("aprobar: pasa a activo, el solicitante queda como owner y se audita", async () => {
    const { clubId, owner } = await activeClub("kevin");
    const member = await env.DB.prepare("SELECT user_id, role, display_name FROM members WHERE club_id = ?")
      .bind(clubId)
      .first<{ user_id: string; role: string; display_name: string }>();
    expect(member).toEqual({ user_id: owner.user.id, role: "owner", display_name: "Dueño" });
    expect(await auditActions(clubId)).toEqual(["club.request", "club.approve"]);
  });

  it("solo se aprueba o rechaza lo pendiente: 409 si ya está activo", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const res = await post(`/admin/clubs/${clubId}/approve`, admin.token);
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("invalid_state");
    expect((await post(`/admin/clubs/${clubId}/reject`, admin.token, {})).status).toBe(409);
    expect((await post("/admin/clubs/no-existe/approve", admin.token)).status).toBe(404);
  });

  it("rechazar con motivo: el solicitante lo ve en /me", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const id = await requestClub(owner.token);
    const res = await post(`/admin/clubs/${id}/reject`, admin.token, { note: "Nombre ofensivo" });
    expect(res.body.club.status).toBe("rejected");
    const me = await api("/me", { token: owner.token });
    expect(me.body.clubRequests).toMatchObject([{ id, status: "rejected", reviewNote: "Nombre ofensivo" }]);
  });

  it("suspender y reactivar; el detalle muestra dueño y miembros por rol", async () => {
    const { clubId, admin } = await activeClub("kevin");
    await addMember(clubId, "raul", "player");
    await addGuest(clubId);
    expect((await post(`/admin/clubs/${clubId}/suspend`, admin.token, { note: "Spam" })).body.club.status).toBe("suspended");
    const detail = await api(`/admin/clubs/${clubId}`, { token: admin.token });
    expect(detail.body).toMatchObject({
      club: { status: "suspended" },
      owner: { username: "kevin" },
      membersByRole: { owner: 1, player: 1, guest: 1 },
    });
    expect((await post(`/admin/clubs/${clubId}/reactivate`, admin.token)).body.club.status).toBe("active");
    expect(await auditActions(clubId)).toEqual(["club.request", "club.approve", "club.suspend", "club.reactivate"]);
  });

  it("transferir: el elegido pasa a owner y el anterior a admin", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const oldOwnerMember = await ownerMemberId(clubId);
    const raul = await addMember(clubId, "raul", "player");
    const res = await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: raul.memberId });
    expect(res.status).toBe(200);
    const roles = await env.DB.prepare("SELECT id, role FROM members WHERE club_id = ? ORDER BY role").bind(clubId).all();
    expect(roles.results).toEqual(
      expect.arrayContaining([
        { id: oldOwnerMember, role: "admin" },
        { id: raul.memberId, role: "owner" },
      ]),
    );
    const club = await env.DB.prepare("SELECT owner_user_id FROM clubs WHERE id = ?").bind(clubId).first<{ owner_user_id: string }>();
    expect(club!.owner_user_id).toBe(raul.user.id);
  });

  it("no se transfiere a un jugador sin cuenta ni a alguien de otro servidor", async () => {
    const { clubId, admin } = await activeClub("kevin");
    const guest = await addGuest(clubId);
    const other = await activeClub("raul", "Otro servidor");
    const outsider = await addMember(other.clubId, "pepe", "player");
    expect((await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: guest })).status).toBe(400);
    expect((await post(`/admin/clubs/${clubId}/transfer`, admin.token, { memberId: outsider.memberId })).status).toBe(400);
  });
});

describe("panel del superadmin: usuarios y métricas", () => {
  it("busca usuarios por nombre y muestra la última conexión", async () => {
    const admin = await superadmin();
    await register("kevin");
    await register("kevin.cc");
    await register("raul");
    const res = await api("/admin/users?q=kev", { token: admin.token });
    expect(res.body.users.map((u: { username: string }) => u.username)).toEqual(["kevin", "kevin.cc"]);
    expect(res.body.users[0].lastSeenAt).toEqual(expect.any(String));
  });

  it("suspender corta sus sesiones y el login; reactivar lo devuelve", async () => {
    const admin = await superadmin();
    const kevin = await register("kevin", "secreto123");
    expect((await post(`/admin/users/${kevin.user.id}/suspend`, admin.token)).status).toBe(200);
    expect((await api("/me", { token: kevin.token })).status).toBe(403);
    expect((await login("kevin", "secreto123")).status).toBe(403);
    await post(`/admin/users/${kevin.user.id}/unsuspend`, admin.token);
    expect((await login("kevin", "secreto123")).status).toBe(200);
    expect(await auditActions(null)).toEqual(["user.suspend", "user.unsuspend"]);
  });

  it("no puede suspenderse a sí mismo ni a otro superadmin", async () => {
    const admin = await superadmin();
    const other = await superadmin("otro.super");
    expect((await post(`/admin/users/${admin.user.id}/suspend`, admin.token)).status).toBe(403);
    expect((await post(`/admin/users/${other.user.id}/suspend`, admin.token)).status).toBe(403);
  });

  it("genera un código de recuperación que sirve para entrar", async () => {
    const admin = await superadmin();
    const kevin = await register("kevin", "secreto123");
    const res = await post(`/admin/users/${kevin.user.id}/recovery-code`, admin.token);
    expect(res.status).toBe(201);
    expect(res.body.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const recover = await api("/auth/recover", { body: { username: "kevin", code: res.body.code, newPassword: "nueva-clave" } });
    expect(recover.status).toBe(200);
  });

  it("métricas: usuarios y servidores por estado", async () => {
    const { admin } = await activeClub("kevin");
    const raul = await register("raul");
    await requestClub(raul.token, "Pendiente");
    const res = await api("/admin/metrics", { token: admin.token });
    expect(res.body).toEqual({
      users: { total: 3, active7d: 3, active30d: 3 },
      clubs: { pending: 1, active: 1, rejected: 0, suspended: 0 },
    });
  });
});
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/superadmin.test.ts`
Expected: FAIL. Los 5 tests de "usuarios y métricas" dan 404.

- [ ] **Step 3: Implementar**

`backend/src/auth/recovery.ts`:

```ts
import { normalizeCode, randomCode, sha256Hex } from "./crypto";

const CODE_HOURS = 24;

/**
 * Prepara un código de recuperación nuevo para `userId`. Anula los anteriores sin usar, para que
 * solo valga el último que se le pasó por WhatsApp. El código en claro solo se devuelve aquí.
 */
export async function issueRecoveryCode(db: D1Database, userId: string, createdBy: string, now: Date) {
  const code = randomCode();
  const expiresAt = new Date(now.getTime() + CODE_HOURS * 60 * 60 * 1000).toISOString();
  const statements = [
    db
      .prepare("UPDATE recovery_codes SET used_at = ? WHERE user_id = ? AND used_at IS NULL")
      .bind(now.toISOString(), userId),
    db
      .prepare(
        "INSERT INTO recovery_codes (id, user_id, code_hash, created_by, expires_at) VALUES (?, ?, ?, ?, ?)",
      )
      .bind(crypto.randomUUID(), userId, await sha256Hex(normalizeCode(code)), createdBy, expiresAt),
  ];
  return { code: `${code.slice(0, 4)}-${code.slice(4)}`, expiresAt, statements };
}
```

Reemplaza `backend/src/superadmin/routes.ts` por la versión completa:

```ts
import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import { z } from "zod";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { issueRecoveryCode } from "../auth/recovery";
import { findUserById } from "../auth/users";
import { findClub, findMember, type ClubStatus } from "../clubs/model";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import type { AppEnv } from "../types";

const requireSuperadmin = createMiddleware<AppEnv>(async (c, next) => {
  if (!c.var.auth.user.isSuperadmin) throw errors.forbidden();
  await next();
});

export const superadminRoutes = new Hono<AppEnv>();

superadminRoutes.use(requireAuth, requireSuperadmin);

const noteSchema = z.object({ note: z.string().trim().max(300).default("") });
const transferSchema = z.object({ memberId: z.string().min(1).max(64) });
const DAY_MS = 24 * 60 * 60 * 1000;

/** `?q=` busca en nombre o nombre de usuario del dueño; `\`, `%` y `_` se buscan literalmente. */
function likePattern(q: string) {
  return `%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`;
}

superadminRoutes.get("/clubs", async (c) => {
  const status = z.enum(["pending", "active", "rejected", "suspended"]).optional().safeParse(c.req.query("status"));
  if (!status.success) throw errors.invalidInput({ status: ["Estado no válido"] });
  const q = (c.req.query("q") ?? "").trim().toLowerCase();
  const { results } = await c.env.DB.prepare(
    `SELECT c.id, c.name, c.status, c.request_note, c.created_at, u.username AS owner_username,
            (SELECT COUNT(*) FROM members m WHERE m.club_id = c.id AND m.status = 'active') AS members
       FROM clubs c LEFT JOIN users u ON u.id = c.owner_user_id
      WHERE (?1 IS NULL OR c.status = ?1)
        AND (?2 = '' OR lower(c.name) LIKE ?3 ESCAPE '\\' OR u.username LIKE ?3 ESCAPE '\\')
      ORDER BY c.created_at DESC LIMIT 100`,
  )
    .bind(status.data ?? null, q, likePattern(q))
    .all<{ id: string; name: string; status: ClubStatus; request_note: string; created_at: string; owner_username: string | null; members: number }>();
  return c.json({
    clubs: results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      requestNote: r.request_note,
      createdAt: r.created_at,
      ownerUsername: r.owner_username,
      members: r.members,
    })),
  });
});

superadminRoutes.get("/clubs/:id", async (c) => {
  const club = await findClub(c.env.DB, c.req.param("id"));
  if (!club) throw errors.notFound();
  const { results } = await c.env.DB.prepare(
    "SELECT role, COUNT(*) AS n FROM members WHERE club_id = ? AND status = 'active' GROUP BY role",
  )
    .bind(club.id)
    .all<{ role: string; n: number }>();
  const owner = await findUserById(c.env.DB, club.ownerUserId);
  return c.json({
    club: { id: club.id, name: club.name, description: club.description, status: club.status, settings: club.settings },
    owner: owner ? { id: owner.id, username: owner.username, displayName: owner.displayName } : null,
    membersByRole: Object.fromEntries(results.map((r) => [r.role, r.n])),
  });
});

/** El club, si su estado es uno de `from`; si no, 404 o 409. */
async function loadClubIn(db: D1Database, id: string, from: ClubStatus[]) {
  const club = await findClub(db, id);
  if (!club) throw errors.notFound();
  if (!from.includes(club.status)) throw errors.invalidState(`El servidor está ${club.status}`);
  return club;
}

superadminRoutes.post("/clubs/:id/approve", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const actor = c.var.auth.user.id;
  const club = await loadClubIn(db, c.req.param("id"), ["pending"]);
  const owner = await findUserById(db, club.ownerUserId);
  if (!owner) throw errors.invalidState("El solicitante ya no tiene cuenta");
  await db.batch([
    db
      .prepare("UPDATE clubs SET status = 'active', reviewed_by = ?, reviewed_at = ?, updated_at = ? WHERE id = ?")
      .bind(actor, at, at, club.id),
    db
      .prepare(
        `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
         VALUES (?, ?, ?, 'owner', ?, ?, ?, ?)`,
      )
      .bind(crypto.randomUUID(), club.id, owner.id, owner.displayName, actor, at, at),
    auditStatement(db, { clubId: club.id, actorUserId: actor, action: "club.approve", entity: "club", entityKey: club.id }, now),
  ]);
  return c.json({ club: { id: club.id, status: "active" } });
});

superadminRoutes.post("/clubs/:id/reject", async (c) => {
  const { note } = await readJson(c, noteSchema);
  return c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["pending"], "rejected", "club.reject", note));
});

superadminRoutes.post("/clubs/:id/suspend", async (c) => {
  const { note } = await readJson(c, noteSchema);
  return c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["active"], "suspended", "club.suspend", note));
});

superadminRoutes.post("/clubs/:id/reactivate", async (c) =>
  c.json(await setClubStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), ["suspended"], "active", "club.reactivate", null)),
);

async function setClubStatus(
  db: D1Database,
  actor: string,
  id: string,
  from: ClubStatus[],
  to: ClubStatus,
  action: string,
  note: string | null,
) {
  const now = new Date();
  const at = now.toISOString();
  const club = await loadClubIn(db, id, from);
  await db.batch([
    db
      .prepare(
        "UPDATE clubs SET status = ?, review_note = COALESCE(?, review_note), reviewed_by = ?, reviewed_at = ?, updated_at = ? WHERE id = ?",
      )
      .bind(to, note, actor, at, at, club.id),
    auditStatement(db, { clubId: club.id, actorUserId: actor, action, entity: "club", entityKey: club.id, summary: note ? { note } : {} }, now),
  ]);
  return { club: { id: club.id, status: to } };
}

/** El dueño actual pasa a admin y el miembro elegido (con cuenta) pasa a dueño. */
superadminRoutes.post("/clubs/:id/transfer", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const at = now.toISOString();
  const actor = c.var.auth.user.id;
  const { memberId } = await readJson(c, transferSchema);
  const club = await loadClubIn(db, c.req.param("id"), ["active", "suspended"]);
  const target = await findMember(db, club.id, memberId);
  if (!target || target.status !== "active" || !target.userId) {
    throw errors.invalidInput({ memberId: ["Tiene que ser un miembro activo con cuenta"] });
  }
  if (target.role === "owner") throw errors.invalidState("Ese miembro ya es el dueño");
  await db.batch([
    db
      .prepare("UPDATE members SET role = 'admin', updated_at = ? WHERE club_id = ? AND role = 'owner'")
      .bind(at, club.id),
    db.prepare("UPDATE members SET role = 'owner', updated_at = ? WHERE id = ?").bind(at, target.id),
    db.prepare("UPDATE clubs SET owner_user_id = ?, updated_at = ? WHERE id = ?").bind(target.userId, at, club.id),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: actor, action: "club.transfer", entity: "club", entityKey: club.id, summary: { from: club.ownerUserId, to: target.userId } },
      now,
    ),
  ]);
  return c.json({ club: { id: club.id, ownerUserId: target.userId } });
});

superadminRoutes.get("/users", async (c) => {
  const q = (c.req.query("q") ?? "").trim().toLowerCase();
  const { results } = await c.env.DB.prepare(
    `SELECT u.id, u.username, u.display_name, u.status, u.is_superadmin, u.created_at,
            (SELECT MAX(s.last_seen_at) FROM sessions s WHERE s.user_id = u.id) AS last_seen_at
       FROM users u
      WHERE ?1 = '' OR u.username LIKE ?2 ESCAPE '\\'
      ORDER BY u.username LIMIT 50`,
  )
    .bind(q, likePattern(q))
    .all<{ id: string; username: string; display_name: string; status: string; is_superadmin: number; created_at: string; last_seen_at: string | null }>();
  return c.json({
    users: results.map((r) => ({
      id: r.id,
      username: r.username,
      displayName: r.display_name,
      status: r.status,
      isSuperadmin: r.is_superadmin === 1,
      createdAt: r.created_at,
      lastSeenAt: r.last_seen_at,
    })),
  });
});

async function loadOtherUser(db: D1Database, actorId: string, id: string) {
  const user = await findUserById(db, id);
  if (!user) throw errors.notFound();
  if (user.id === actorId || user.isSuperadmin) throw errors.forbidden();
  return user;
}

superadminRoutes.post("/users/:id/suspend", async (c) =>
  c.json(await setUserStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), "suspended")),
);
superadminRoutes.post("/users/:id/unsuspend", async (c) =>
  c.json(await setUserStatus(c.env.DB, c.var.auth.user.id, c.req.param("id"), "active")),
);

async function setUserStatus(
  db: D1Database,
  actor: string,
  id: string,
  status: "active" | "suspended",
) {
  const now = new Date();
  const user = await loadOtherUser(db, actor, id);
  await db.batch([
    db.prepare("UPDATE users SET status = ?, updated_at = ? WHERE id = ?").bind(status, now.toISOString(), user.id),
    auditStatement(
      db,
      { clubId: null, actorUserId: actor, action: status === "suspended" ? "user.suspend" : "user.unsuspend", entity: "user", entityKey: user.id },
      now,
    ),
  ]);
  return { user: { id: user.id, status } };
}

superadminRoutes.post("/users/:id/recovery-code", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const actor = c.var.auth.user.id;
  const user = await findUserById(db, c.req.param("id"));
  if (!user) throw errors.notFound();
  if (user.id === actor) throw errors.forbidden();
  const issued = await issueRecoveryCode(db, user.id, actor, now);
  await db.batch([
    ...issued.statements,
    auditStatement(db, { clubId: null, actorUserId: actor, action: "recovery.issue", entity: "user", entityKey: user.id }, now),
  ]);
  return c.json({ code: issued.code, expiresAt: issued.expiresAt }, 201);
});

superadminRoutes.get("/metrics", async (c) => {
  const now = Date.now();
  const since = (days: number) => new Date(now - days * DAY_MS).toISOString();
  const users = await c.env.DB.prepare(
    `SELECT COUNT(*) AS total,
            (SELECT COUNT(DISTINCT user_id) FROM sessions WHERE last_seen_at > ?1) AS active7d,
            (SELECT COUNT(DISTINCT user_id) FROM sessions WHERE last_seen_at > ?2) AS active30d
       FROM users`,
  )
    .bind(since(7), since(30))
    .first<{ total: number; active7d: number; active30d: number }>();
  const { results } = await c.env.DB.prepare("SELECT status, COUNT(*) AS n FROM clubs GROUP BY status").all<{
    status: ClubStatus;
    n: number;
  }>();
  const clubs = { pending: 0, active: 0, rejected: 0, suspended: 0 };
  for (const r of results) clubs[r.status] = r.n;
  return c.json({ users, clubs });
});
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: superadmin busca y suspende usuarios, genera códigos de recuperación y ve métricas"
```

---

### Task 6: Invitaciones del staff (crear, listar, revocar)

**Files:**
- Create: `backend/src/invites/model.ts`, `backend/test/invites.test.ts`
- Modify: `backend/src/clubs/schemas.ts` (reemplazo completo), `backend/src/clubs/routes.ts` (reemplazo completo)

**Interfaces:**
- Consumes:
  - `requireMembership`, `assertWritable` y `findMember` (Task 3);
  - `canInviteAs` y `canManageInvites` (Task 2);
  - `randomCode` y `normalizeCode` (PR1).
- Produces:
  - `src/invites/model.ts`: tipo `InviteRecord`; `findInvite(db, rawCode)` (normaliza el código), `isUsable(invite, now)` y `formatCode(code)`.
  - Endpoints:
    - `POST /clubs/:clubId/invites { role?, maxUses?, expiresInDays?, targetMemberId? }` → 201 `{ invite: { code, role, maxUses, uses, expiresAt, targetMemberId } }`
    - `GET /clubs/:clubId/invites` → `{ invites: [...] }`
    - `POST /clubs/:clubId/invites/:code/revoke` → 204

- [ ] **Step 1: Escribir los tests que fallan**

`backend/test/invites.test.ts`. La Task 7 lo reemplaza por la versión completa:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions } from "./fixtures";
import { api } from "./helpers";

async function invite(clubId: string, token: string, body: Record<string, unknown> = {}) {
  return api(`/clubs/${clubId}/invites`, { token, body });
}


describe("crear invitaciones", () => {
  it("el owner crea una con código XXXX-XXXX, 1 uso y 7 días por defecto", async () => {
    const { clubId, owner } = await activeClub();
    const res = await invite(clubId, owner.token);
    expect(res.status).toBe(201);
    expect(res.body.invite).toMatchObject({ role: "player", maxUses: 1, uses: 0, targetMemberId: null });
    expect(res.body.invite.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const days = (Date.parse(res.body.invite.expiresAt) - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(6.9);
    expect(days).toBeLessThanOrEqual(7);
    expect(await auditActions(clubId)).toContain("invite.create");
  });

  it("un admin invita como player o scorer, pero no como admin", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "raul", "admin");
    expect((await invite(clubId, admin.token, { role: "scorer", maxUses: 20 })).status).toBe(201);
    const res = await invite(clubId, admin.token, { role: "admin" });
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("forbidden");
  });

  it("un player o un scorer no puede invitar", async () => {
    const { clubId } = await activeClub();
    for (const role of ["player", "scorer"] as const) {
      const m = await addMember(clubId, `m.${role}`, role);
      expect((await invite(clubId, m.token)).status, role).toBe(403);
    }
  });

  it("quien no es miembro recibe 404, aunque sea admin de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const res = await invite(a.clubId, b.owner.token);
    expect(res.status).toBe(404);
  });

  it("un admin que se fue o al que expulsaron ya no actúa en el servidor: 404", async () => {
    const { clubId } = await activeClub();
    const gone = await addMember(clubId, "seFue", "admin");
    const banned = await addMember(clubId, "baneado", "admin");
    await env.DB.prepare("UPDATE members SET status = 'left' WHERE id = ?").bind(gone.memberId).run();
    await env.DB.prepare("UPDATE members SET status = 'banned' WHERE id = ?").bind(banned.memberId).run();
    expect((await invite(clubId, gone.token)).status).toBe(404);
    expect((await invite(clubId, banned.token)).status).toBe(404);
  });

  it("valida usos (1–100) y días (1–30)", async () => {
    const { clubId, owner } = await activeClub();
    expect((await invite(clubId, owner.token, { maxUses: 0 })).status).toBe(400);
    expect((await invite(clubId, owner.token, { maxUses: 101 })).status).toBe(400);
    expect((await invite(clubId, owner.token, { expiresInDays: 31 })).status).toBe(400);
  });

  it("para reclamar un perfil sin cuenta: fuerza player y 1 uso; el perfil tiene que ser de este servidor", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId);
    const res = await invite(clubId, owner.token, { targetMemberId: guest, role: "admin", maxUses: 50 });
    expect(res.body.invite).toMatchObject({ role: "player", maxUses: 1, targetMemberId: guest });

    const other = await activeClub("raul", "Otro");
    const foreignGuest = await addGuest(other.clubId);
    expect((await invite(clubId, owner.token, { targetMemberId: foreignGuest })).status).toBe(400);
  });

  it("en un servidor suspendido no se crean invitaciones", async () => {
    const { clubId, owner } = await activeClub();
    await env.DB.prepare("UPDATE clubs SET status = 'suspended' WHERE id = ?").bind(clubId).run();
    const res = await invite(clubId, owner.token);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("club_suspended");
  });
});

describe("listar y revocar", () => {
  it("lista solo las que aún sirven; revocar la saca de la lista", async () => {
    const { clubId, owner } = await activeClub();
    const a = (await invite(clubId, owner.token)).body.invite.code;
    const b = (await invite(clubId, owner.token)).body.invite.code;
    expect((await api(`/clubs/${clubId}/invites/${a}/revoke`, { method: "POST", token: owner.token })).status).toBe(204);
    const list = await api(`/clubs/${clubId}/invites`, { token: owner.token });
    expect(list.body.invites.map((i: { code: string }) => i.code)).toEqual([b]);
    expect(await auditActions(clubId)).toContain("invite.revoke");
  });

  it("un player no ve ni revoca invitaciones", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    const raul = await addMember(clubId, "raul", "player");
    expect((await api(`/clubs/${clubId}/invites`, { token: raul.token })).status).toBe(403);
    expect((await api(`/clubs/${clubId}/invites/${code}/revoke`, { method: "POST", token: raul.token })).status).toBe(403);
  });

  it("no se puede revocar una invitación de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const code = (await invite(b.clubId, b.owner.token)).body.invite.code;
    expect((await api(`/clubs/${a.clubId}/invites/${code}/revoke`, { method: "POST", token: a.owner.token })).status).toBe(404);
    const list = await api(`/clubs/${b.clubId}/invites`, { token: b.owner.token });
    expect(list.body.invites.map((i: { code: string }) => i.code)).toEqual([code]);
  });
});
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/invites.test.ts`
Expected: FAIL. `POST /clubs/:id/invites` da 404.

- [ ] **Step 3: Implementar**

`backend/src/invites/model.ts`:

```ts
import type { InvitableRole } from "../authz";
import { normalizeCode } from "../auth/crypto";
import type { ClubStatus } from "../clubs/model";

export type InviteRecord = {
  code: string;
  clubId: string;
  role: InvitableRole;
  targetMemberId: string | null;
  maxUses: number;
  uses: number;
  expiresAt: string;
  revokedAt: string | null;
  club: { name: string; description: string; status: ClubStatus };
};

type InviteRow = {
  code: string;
  club_id: string;
  role: InvitableRole;
  target_member_id: string | null;
  max_uses: number;
  uses: number;
  expires_at: string;
  revoked_at: string | null;
  club_name: string;
  club_description: string;
  club_status: ClubStatus;
};

/** Busca la invitación tal como la escriba la gente (minúsculas, guiones, espacios). */
export async function findInvite(db: D1Database, rawCode: string) {
  const row = await db
    .prepare(
      `SELECT i.code, i.club_id, i.role, i.target_member_id, i.max_uses, i.uses, i.expires_at, i.revoked_at,
              c.name AS club_name, c.description AS club_description, c.status AS club_status
         FROM invites i JOIN clubs c ON c.id = i.club_id
        WHERE i.code = ?`,
    )
    .bind(normalizeCode(rawCode))
    .first<InviteRow>();
  if (!row) return null;
  return {
    code: row.code,
    clubId: row.club_id,
    role: row.role,
    targetMemberId: row.target_member_id,
    maxUses: row.max_uses,
    uses: row.uses,
    expiresAt: row.expires_at,
    revokedAt: row.revoked_at,
    club: { name: row.club_name, description: row.club_description, status: row.club_status },
  } satisfies InviteRecord;
}

/** Sirve si no está revocada ni caducada, le quedan usos y el servidor está activo. */
export function isUsable(invite: InviteRecord, now: Date) {
  return (
    invite.revokedAt === null &&
    invite.expiresAt > now.toISOString() &&
    invite.uses < invite.maxUses &&
    invite.club.status === "active"
  );
}

export function formatCode(code: string) {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}
```

Reemplaza `backend/src/clubs/schemas.ts` por:

```ts
import { z } from "zod";

export const clubRequestSchema = z.object({
  name: z.string().trim().min(3, { error: "Mínimo 3 caracteres" }).max(40, { error: "Máximo 40 caracteres" }),
  description: z.string().trim().max(200).default(""),
  requestNote: z.string().trim().max(300).default(""),
});

export const createInviteSchema = z.object({
  role: z.enum(["player", "scorer", "admin"]).default("player"),
  maxUses: z.number().int().min(1).max(100).default(1),
  expiresInDays: z.number().int().min(1).max(30).default(7),
  /** Para que un jugador sin cuenta reclame su perfil. Fuerza `role = player` y `maxUses = 1`. */
  targetMemberId: z.string().min(1).max(64).optional(),
});
```

Reemplaza `backend/src/clubs/routes.ts` por. La Task 8 le añade una ruta más:

```ts
import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { randomCode } from "../auth/crypto";
import { canInviteAs, canManageInvites } from "../authz";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import { findInvite, formatCode } from "../invites/model";
import type { AppEnv } from "../types";
import { assertWritable, DEFAULT_SETTINGS, findMember, requireMembership } from "./model";
import { clubRequestSchema, createInviteSchema } from "./schemas";

const MAX_OWNED_CLUBS = 3;
const DAY_MS = 24 * 60 * 60 * 1000;

export const clubRoutes = new Hono<AppEnv>();

clubRoutes.use(requireAuth);

/** Solicitar un servidor. Queda `pending` hasta que el superadmin lo apruebe. */
clubRoutes.post("/", async (c) => {
  const body = await readJson(c, clubRequestSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;

  const owned = await db
    .prepare("SELECT COUNT(*) AS n FROM clubs WHERE owner_user_id = ? AND status IN ('pending', 'active')")
    .bind(userId)
    .first<{ n: number }>();
  if (owned!.n >= MAX_OWNED_CLUBS) throw errors.tooManyClubs();

  const id = crypto.randomUUID();
  const at = now.toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO clubs (id, name, description, status, owner_user_id, request_note, settings, created_at, updated_at)
         VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)`,
      )
      .bind(id, body.name, body.description, userId, body.requestNote, JSON.stringify(DEFAULT_SETTINGS), at, at),
    auditStatement(db, { clubId: id, actorUserId: userId, action: "club.request", entity: "club", entityKey: id }, now),
  ]);
  return c.json({ club: { id, name: body.name, status: "pending" } }, 201);
});

clubRoutes.post("/:clubId/invites", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  assertWritable(club);
  const body = await readJson(c, createInviteSchema);

  let { role, maxUses } = body;
  if (body.targetMemberId) {
    const target = await findMember(db, club.id, body.targetMemberId);
    if (!target || target.role !== "guest" || target.status !== "active") {
      throw errors.invalidInput({ targetMemberId: ["Ese jugador sin cuenta no existe en este servidor"] });
    }
    role = "player";
    maxUses = 1;
  }
  if (!canInviteAs(member.role, role)) throw errors.forbidden();

  const code = randomCode();
  const expiresAt = new Date(now.getTime() + body.expiresInDays * DAY_MS).toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO invites (code, club_id, role, target_member_id, max_uses, expires_at, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(code, club.id, role, body.targetMemberId ?? null, maxUses, expiresAt, userId, now.toISOString()),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: userId, action: "invite.create", entity: "invite", entityKey: code, summary: { role, maxUses } },
      now,
    ),
  ]);
  return c.json(
    { invite: { code: formatCode(code), role, maxUses, uses: 0, expiresAt, targetMemberId: body.targetMemberId ?? null } },
    201,
  );
});

clubRoutes.get("/:clubId/invites", async (c) => {
  const db = c.env.DB;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), c.var.auth.user.id);
  if (!canManageInvites(member.role)) throw errors.forbidden();
  const { results } = await db
    .prepare(
      `SELECT code, role, target_member_id, max_uses, uses, expires_at FROM invites
        WHERE club_id = ? AND revoked_at IS NULL AND expires_at > ? AND uses < max_uses
        ORDER BY created_at DESC`,
    )
    .bind(club.id, new Date().toISOString())
    .all<{ code: string; role: string; target_member_id: string | null; max_uses: number; uses: number; expires_at: string }>();
  return c.json({
    invites: results.map((r) => ({
      code: formatCode(r.code),
      role: r.role,
      maxUses: r.max_uses,
      uses: r.uses,
      expiresAt: r.expires_at,
      targetMemberId: r.target_member_id,
    })),
  });
});

clubRoutes.post("/:clubId/invites/:code/revoke", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  if (!canManageInvites(member.role)) throw errors.forbidden();
  const invite = await findInvite(db, c.req.param("code"));
  if (!invite || invite.clubId !== club.id) throw errors.notFound();
  await db.batch([
    db.prepare("UPDATE invites SET revoked_at = ? WHERE code = ?").bind(now.toISOString(), invite.code),
    auditStatement(db, { clubId: club.id, actorUserId: userId, action: "invite.revoke", entity: "invite", entityKey: invite.code }, now),
  ]);
  return c.body(null, 204);
});
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: el staff crea, lista y revoca invitaciones"
```

---

### Task 7: Ver y aceptar invitaciones, y la página `/i/<código>`

**Files:**
- Create: `backend/src/invites/page.ts`, `backend/src/invites/routes.ts`
- Modify: `backend/src/index.ts`, `backend/test/invites.test.ts` (reemplazo completo)

**Interfaces:**
- Consumes:
  - `findInvite`, `isUsable` y `formatCode` (Task 6);
  - `findMember` y `findMemberByUser` (Task 3);
  - `auditStatement` (Task 3);
  - `errors.inviteInvalid`, `errors.alreadyMember` y `errors.bannedFromClub` (Task 3).
- Produces:
  - `inviteRoutes`, montada en `/invites`:
    - `GET /invites/:code` → `{ club: { id, name, description }, role, claim: { displayName } | null, expiresAt }`
    - `POST /invites/:code/accept` (con sesión) → 201 `{ club: { id, name }, member: { id, role, displayName } }`
  - `invitePageRoutes`, montada en `/i`: `GET /i/:code` → HTML (200 si la invitación sirve, 404 si no).
  - `escapeHtml(value)` en `src/invites/page.ts`.

- [ ] **Step 1: Escribir los tests que fallan**

Reemplaza `backend/test/invites.test.ts` por la versión completa:

```ts
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, superadmin } from "./fixtures";
import { api, register } from "./helpers";

async function invite(clubId: string, token: string, body: Record<string, unknown> = {}) {
  return api(`/clubs/${clubId}/invites`, { token, body });
}

const accept = (code: string, token: string) => api(`/invites/${code}/accept`, { method: "POST", token });

describe("crear invitaciones", () => {
  it("el owner crea una con código XXXX-XXXX, 1 uso y 7 días por defecto", async () => {
    const { clubId, owner } = await activeClub();
    const res = await invite(clubId, owner.token);
    expect(res.status).toBe(201);
    expect(res.body.invite).toMatchObject({ role: "player", maxUses: 1, uses: 0, targetMemberId: null });
    expect(res.body.invite.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const days = (Date.parse(res.body.invite.expiresAt) - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(6.9);
    expect(days).toBeLessThanOrEqual(7);
    expect(await auditActions(clubId)).toContain("invite.create");
  });

  it("un admin invita como player o scorer, pero no como admin", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "raul", "admin");
    expect((await invite(clubId, admin.token, { role: "scorer", maxUses: 20 })).status).toBe(201);
    const res = await invite(clubId, admin.token, { role: "admin" });
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("forbidden");
  });

  it("un player o un scorer no puede invitar", async () => {
    const { clubId } = await activeClub();
    for (const role of ["player", "scorer"] as const) {
      const m = await addMember(clubId, `m.${role}`, role);
      expect((await invite(clubId, m.token)).status, role).toBe(403);
    }
  });

  it("quien no es miembro recibe 404, aunque sea admin de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const res = await invite(a.clubId, b.owner.token);
    expect(res.status).toBe(404);
  });

  it("un admin que se fue o al que expulsaron ya no actúa en el servidor: 404", async () => {
    const { clubId } = await activeClub();
    const gone = await addMember(clubId, "seFue", "admin");
    const banned = await addMember(clubId, "baneado", "admin");
    await env.DB.prepare("UPDATE members SET status = 'left' WHERE id = ?").bind(gone.memberId).run();
    await env.DB.prepare("UPDATE members SET status = 'banned' WHERE id = ?").bind(banned.memberId).run();
    expect((await invite(clubId, gone.token)).status).toBe(404);
    expect((await invite(clubId, banned.token)).status).toBe(404);
  });

  it("valida usos (1–100) y días (1–30)", async () => {
    const { clubId, owner } = await activeClub();
    expect((await invite(clubId, owner.token, { maxUses: 0 })).status).toBe(400);
    expect((await invite(clubId, owner.token, { maxUses: 101 })).status).toBe(400);
    expect((await invite(clubId, owner.token, { expiresInDays: 31 })).status).toBe(400);
  });

  it("para reclamar un perfil sin cuenta: fuerza player y 1 uso; el perfil tiene que ser de este servidor", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId);
    const res = await invite(clubId, owner.token, { targetMemberId: guest, role: "admin", maxUses: 50 });
    expect(res.body.invite).toMatchObject({ role: "player", maxUses: 1, targetMemberId: guest });

    const other = await activeClub("raul", "Otro");
    const foreignGuest = await addGuest(other.clubId);
    expect((await invite(clubId, owner.token, { targetMemberId: foreignGuest })).status).toBe(400);
  });

  it("en un servidor suspendido no se crean invitaciones", async () => {
    const { clubId, owner } = await activeClub();
    await env.DB.prepare("UPDATE clubs SET status = 'suspended' WHERE id = ?").bind(clubId).run();
    const res = await invite(clubId, owner.token);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("club_suspended");
  });
});

describe("listar y revocar", () => {
  it("lista solo las que aún sirven; revocar la saca de la lista", async () => {
    const { clubId, owner } = await activeClub();
    const a = (await invite(clubId, owner.token)).body.invite.code;
    const b = (await invite(clubId, owner.token)).body.invite.code;
    expect((await api(`/clubs/${clubId}/invites/${a}/revoke`, { method: "POST", token: owner.token })).status).toBe(204);
    const list = await api(`/clubs/${clubId}/invites`, { token: owner.token });
    expect(list.body.invites.map((i: { code: string }) => i.code)).toEqual([b]);
    expect(await auditActions(clubId)).toContain("invite.revoke");
  });

  it("un player no ve ni revoca invitaciones", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    const raul = await addMember(clubId, "raul", "player");
    expect((await api(`/clubs/${clubId}/invites`, { token: raul.token })).status).toBe(403);
    expect((await api(`/clubs/${clubId}/invites/${code}/revoke`, { method: "POST", token: raul.token })).status).toBe(403);
  });

  it("no se puede revocar una invitación de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const code = (await invite(b.clubId, b.owner.token)).body.invite.code;
    expect((await api(`/clubs/${a.clubId}/invites/${code}/revoke`, { method: "POST", token: a.owner.token })).status).toBe(404);
    const list = await api(`/clubs/${b.clubId}/invites`, { token: b.owner.token });
    expect(list.body.invites.map((i: { code: string }) => i.code)).toEqual([code]);
  });
});

describe("ver y aceptar", () => {
  it("la vista previa no pide sesión y acepta el código en minúsculas y sin guion", async () => {
    const { clubId, owner } = await activeClub();
    const code: string = (await invite(clubId, owner.token)).body.invite.code;
    const res = await api(`/invites/${code.toLowerCase().replace("-", "")}`);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ club: { id: clubId, name: "Pachanga del sábado" }, role: "player", claim: null });
  });

  it("aceptar crea el miembro con el rol de la invitación y el servidor sale en /me", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token, { role: "scorer" })).body.invite.code;
    const raul = await register("raul", "secreto123", "Raúl");
    const res = await accept(code, raul.token);
    expect(res.status).toBe(201);
    expect(res.body.member).toMatchObject({ role: "scorer", displayName: "Raúl" });
    const me = await api("/me", { token: raul.token });
    expect(me.body.clubs).toMatchObject([{ id: clubId, role: "scorer" }]);
    expect(await auditActions(clubId)).toContain("invite.accept");
  });

  it("aceptar dos veces (reintento con mala conexión): 409 y el uso cuenta una sola vez", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token, { maxUses: 5 })).body.invite.code;
    const raul = await register("raul");
    expect((await accept(code, raul.token)).status).toBe(201);
    const again = await accept(code, raul.token);
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe("already_member");
    expect((await api(`/clubs/${clubId}/invites`, { token: owner.token })).body.invites[0].uses).toBe(1);
  });

  it("cuando se agotan los usos deja de valer", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token, { maxUses: 1 })).body.invite.code;
    expect((await accept(code, (await register("raul")).token)).status).toBe(201);
    const late = await accept(code, (await register("pepe")).token);
    expect(late.status).toBe(404);
    expect(late.body.error.code).toBe("invite_invalid");
  });

  it("revocada: ni se ve ni se acepta", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    await api(`/clubs/${clubId}/invites/${code}/revoke`, { method: "POST", token: owner.token });
    expect((await api(`/invites/${code}`)).status).toBe(404);
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
  });

  it("caducada: no vale", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    await env.DB.prepare("UPDATE invites SET expires_at = ?").bind(new Date(Date.now() - 1000).toISOString()).run();
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
  });

  it("un expulsado no vuelve a entrar; uno que se fue vuelve con su mismo perfil", async () => {
    const { clubId, owner } = await activeClub();
    const banned = await addMember(clubId, "baneado", "player");
    const gone = await addMember(clubId, "seFue", "player");
    await env.DB.prepare("UPDATE members SET status = 'banned' WHERE id = ?").bind(banned.memberId).run();
    await env.DB.prepare("UPDATE members SET status = 'left' WHERE id = ?").bind(gone.memberId).run();
    const code = (await invite(clubId, owner.token, { maxUses: 5 })).body.invite.code;

    const b = await accept(code, banned.token);
    expect(b.status).toBe(403);
    expect(b.body.error.code).toBe("banned_from_club");
    const g = await accept(code, gone.token);
    expect(g.status).toBe(201);
    expect(g.body.member.id).toBe(gone.memberId);
  });

  it("reclamar un perfil sin cuenta: se queda con ese perfil (y su historial)", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId, "Yoandry, el primo de Raúl");
    const code = (await invite(clubId, owner.token, { targetMemberId: guest })).body.invite.code;
    expect((await api(`/invites/${code}`)).body.claim).toEqual({ displayName: "Yoandry, el primo de Raúl" });

    const yoandry = await register("yoandry");
    const res = await accept(code, yoandry.token);
    expect(res.status).toBe(201);
    expect(res.body.member).toEqual({ id: guest, role: "player", displayName: "Yoandry, el primo de Raúl" });
    const row = await env.DB.prepare("SELECT user_id, role, claimed_at FROM members WHERE id = ?").bind(guest).first<{
      user_id: string;
      role: string;
      claimed_at: string;
    }>();
    expect(row).toMatchObject({ user_id: yoandry.user.id, role: "player" });
    expect(row!.claimed_at).toEqual(expect.any(String));
  });

  it("quien ya es miembro no puede reclamar además un perfil sin cuenta", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const guest = await addGuest(clubId);
    const code = (await invite(clubId, owner.token, { targetMemberId: guest })).body.invite.code;
    expect((await accept(code, raul.token)).status).toBe(409);
    const row = await env.DB.prepare("SELECT user_id FROM members WHERE id = ?").bind(guest).first<{ user_id: string | null }>();
    expect(row!.user_id).toBeNull();
  });

  it("si el perfil sin cuenta ya no está disponible, falla sin gastar el uso", async () => {
    const { clubId, owner } = await activeClub();
    const guest = await addGuest(clubId);
    const code = (await invite(clubId, owner.token, { targetMemberId: guest })).body.invite.code;
    await env.DB.prepare("UPDATE members SET status = 'banned' WHERE id = ?").bind(guest).run();
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
    const row = await env.DB.prepare("SELECT uses FROM invites").first<{ uses: number }>();
    expect(row!.uses).toBe(0);
  });

  it("aceptar exige sesión; un servidor suspendido no admite gente nueva", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await invite(clubId, owner.token)).body.invite.code;
    expect((await api(`/invites/${code}/accept`, { method: "POST" })).status).toBe(401);
    await env.DB.prepare("UPDATE clubs SET status = 'suspended' WHERE id = ?").bind(clubId).run();
    expect((await accept(code, (await register("raul")).token)).status).toBe(404);
  });
});

describe("página /i/<código>", () => {
  async function page(path: string) {
    const res = await exports.default.fetch(`https://api.test${path}`);
    return { status: res.status, headers: res.headers, html: await res.text() };
  }

  it("muestra el servidor, el código y el enlace a la app", async () => {
    const { clubId, owner } = await activeClub();
    const code: string = (await invite(clubId, owner.token)).body.invite.code;
    const res = await page(`/i/${code}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.html).toContain("Pachanga del sábado");
    expect(res.html).toContain(code);
    expect(res.html).toContain(`elfurbo://invite/${code.replace("-", "")}`);
  });

  it("escapa el nombre y la descripción del servidor (los escribe cualquiera)", async () => {
    const owner = await register("kevin");
    const admin = await superadmin();
    const res = await api("/clubs", {
      token: owner.token,
      body: { name: `<script>alert(1)</script>`, description: `"><img src=x onerror=alert(2)>` },
    });
    await api(`/admin/clubs/${res.body.club.id}/approve`, { method: "POST", token: admin.token });
    const code = (await invite(res.body.club.id, owner.token)).body.invite.code;
    const html = (await page(`/i/${code}`)).html;
    expect(html).not.toContain("<script>alert");
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
  });

  it("si no vale, da 404 con un mensaje claro", async () => {
    const res = await page("/i/NOEXISTE");
    expect(res.status).toBe(404);
    expect(res.html).toContain("Invitación no válida");
  });
});
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/invites.test.ts`
Expected: FAIL. `/invites/...` e `/i/...` dan 404 en JSON. Los tests de crear, listar y revocar siguen pasando.

- [ ] **Step 3: Implementar**

`backend/src/invites/page.ts`:

```ts
import { formatCode, type InviteRecord } from "./model";

/** El nombre y la descripción los escribe cualquiera que pida un servidor: siempre escapados. */
export function escapeHtml(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const STYLE = `body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0f5132;color:#fff;
font-family:system-ui,sans-serif;text-align:center;padding:16px;box-sizing:border-box}
main{max-width:420px}h1{font-size:1.6rem;margin:.2em 0}p{line-height:1.5;opacity:.92}
.code{font-size:2rem;letter-spacing:.15em;font-weight:700;background:#fff;color:#0f5132;
border-radius:12px;padding:.4em .6em;display:inline-block;margin:.4em 0}
a.button{display:inline-block;margin-top:1em;background:#ffc107;color:#000;font-weight:700;
padding:.8em 1.4em;border-radius:999px;text-decoration:none}`;

function layout(body: string) {
  return `<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>El Furbo · Invitación</title><style>${STYLE}</style></head>
<body><main>${body}</main></body></html>`;
}

export function invitePage(invite: InviteRecord | null) {
  if (!invite) {
    return layout(`<h1>⚽ Invitación no válida</h1>
<p>Esta invitación no existe, caducó o ya se usó. Pídele una nueva a quien te la mandó.</p>`);
  }
  const code = formatCode(invite.code);
  const description = invite.club.description ? `<p>${escapeHtml(invite.club.description)}</p>` : "";
  return layout(`<p>Te invitaron a</p><h1>⚽ ${escapeHtml(invite.club.name)}</h1>${description}
<p>Tu código de invitación:</p><div class="code">${code}</div>
<p><a class="button" href="elfurbo://invite/${invite.code}">Abrir en El Furbo</a></p>
<p>¿No tienes la app? Pídele el APK a quien te invitó, instálala, entra y escribe el código en
"Tengo un código de invitación".</p>`);
}
```

`backend/src/invites/routes.ts`:

```ts
import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { findMember, findMemberByUser } from "../clubs/model";
import { errors } from "../http/errors";
import type { AppEnv } from "../types";
import { findInvite, isUsable, type InviteRecord } from "./model";
import { invitePage } from "./page";

export const inviteRoutes = new Hono<AppEnv>();

/** Lo que ve la app antes de aceptar: a qué servidor entra y con qué perfil. Sin sesión. */
inviteRoutes.get("/:code", async (c) => {
  const db = c.env.DB;
  const invite = await findInvite(db, c.req.param("code"));
  if (!invite || !isUsable(invite, new Date())) throw errors.inviteInvalid();
  const target = invite.targetMemberId ? await findMember(db, invite.clubId, invite.targetMemberId) : null;
  return c.json({
    club: { id: invite.clubId, name: invite.club.name, description: invite.club.description },
    role: invite.role,
    claim: target ? { displayName: target.displayName } : null,
    expiresAt: invite.expiresAt,
  });
});

inviteRoutes.post("/:code/accept", requireAuth, async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const user = c.var.auth.user;
  const invite = await findInvite(db, c.req.param("code"));
  if (!invite || !isUsable(invite, now)) throw errors.inviteInvalid();

  const existing = await findMemberByUser(db, invite.clubId, user.id);
  if (existing?.status === "banned") throw errors.bannedFromClub();
  // Reclamar un perfil exige no tener ya otro en el servidor (aunque se haya ido).
  if (existing?.status === "active" || (existing && invite.targetMemberId)) throw errors.alreadyMember();

  await claimUse(db, invite, now);
  try {
    const member = await joinClub(db, invite, user, existing?.id ?? null, now);
    await auditStatement(
      db,
      { clubId: invite.clubId, actorUserId: user.id, action: "invite.accept", entity: "member", entityKey: member.id, summary: { invite: invite.code } },
      now,
    ).run();
    return c.json({ club: { id: invite.clubId, name: invite.club.name }, member }, 201);
  } catch (e) {
    // Si no se pudo entrar, el uso no cuenta.
    await db.prepare("UPDATE invites SET uses = uses - 1 WHERE code = ?").bind(invite.code).run();
    throw e;
  }
});

/** Gasta un uso de forma atómica: dos personas no pueden llevarse el último a la vez. */
async function claimUse(db: D1Database, invite: InviteRecord, now: Date) {
  const claimed = await db
    .prepare(
      `UPDATE invites SET uses = uses + 1
        WHERE code = ? AND revoked_at IS NULL AND uses < max_uses AND expires_at > ?
        RETURNING uses`,
    )
    .bind(invite.code, now.toISOString())
    .first();
  if (!claimed) throw errors.inviteInvalid();
}

async function joinClub(
  db: D1Database,
  invite: InviteRecord,
  user: { id: string; displayName: string },
  leftMemberId: string | null,
  now: Date,
) {
  const at = now.toISOString();

  if (invite.targetMemberId) {
    const claimed = await db
      .prepare(
        `UPDATE members SET user_id = ?, role = 'player', claimed_at = ?, updated_at = ?
          WHERE id = ? AND club_id = ? AND user_id IS NULL AND status = 'active'
          RETURNING id, role, display_name`,
      )
      .bind(user.id, at, at, invite.targetMemberId, invite.clubId)
      .first<{ id: string; role: string; display_name: string }>();
    if (!claimed) throw errors.inviteInvalid();
    return { id: claimed.id, role: claimed.role, displayName: claimed.display_name };
  }

  if (leftMemberId) {
    // Vuelve alguien que se había ido: mismo perfil, con sus estadísticas.
    const back = await db
      .prepare("UPDATE members SET status = 'active', role = ?, updated_at = ? WHERE id = ? RETURNING id, role, display_name")
      .bind(invite.role, at, leftMemberId)
      .first<{ id: string; role: string; display_name: string }>();
    return { id: back!.id, role: back!.role, displayName: back!.display_name };
  }

  const id = crypto.randomUUID();
  try {
    await db
      .prepare(
        `INSERT INTO members (id, club_id, user_id, role, display_name, created_by, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(id, invite.clubId, user.id, invite.role, user.displayName, user.id, at, at)
      .run();
  } catch (e) {
    // Dos aceptaciones simultáneas del mismo usuario: gana la primera.
    if (String(e).includes("UNIQUE constraint failed")) throw errors.alreadyMember();
    throw e;
  }
  return { id, role: invite.role, displayName: user.displayName };
}

/** Página para el enlace que se comparte por WhatsApp: `/i/<CODE>`. */
export const invitePageRoutes = new Hono<AppEnv>();

invitePageRoutes.get("/:code", async (c) => {
  const invite = await findInvite(c.env.DB, c.req.param("code"));
  const usable = invite !== null && isUsable(invite, new Date());
  c.header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'");
  c.header("Referrer-Policy", "no-referrer");
  c.header("X-Robots-Tag", "noindex");
  return c.html(invitePage(usable ? invite : null), usable ? 200 : 404);
});
```

Reemplaza `backend/src/index.ts` por:

```ts
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { authRoutes } from "./auth/routes";
import { clubRoutes } from "./clubs/routes";
import { errorResponse, errors, handleError } from "./http/errors";
import { invitePageRoutes, inviteRoutes } from "./invites/routes";
import { meRoutes } from "./me/routes";
import { superadminRoutes } from "./superadmin/routes";
import type { AppEnv } from "./types";

const app = new Hono<AppEnv>();

app.use(bodyLimit({ maxSize: 64 * 1024, onError: (c) => errorResponse(c, errors.payloadTooLarge()) }));

app.get("/health", (c) => c.json({ ok: true, environment: c.env.ENVIRONMENT }));
app.route("/auth", authRoutes);
app.route("/me", meRoutes);
app.route("/clubs", clubRoutes);
app.route("/invites", inviteRoutes);
app.route("/i", invitePageRoutes);
app.route("/admin", superadminRoutes);

app.notFound((c) => errorResponse(c, errors.notFound()));
app.onError(handleError);

export default app;
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: aceptar invitaciones (entrar, volver o reclamar un perfil) y página /i/<código>"
```

---

### Task 8: Códigos de recuperación desde el servidor

**Files:**
- Modify: `backend/src/clubs/routes.ts` (reemplazo completo)
- Test: `backend/test/recovery-codes.test.ts`

**Interfaces:**
- Consumes:
  - `issueRecoveryCode` (Task 5);
  - `canIssueRecoveryCode` (Task 2);
  - `requireMembership` y `findMember` (Task 3).
- Produces: `POST /clubs/:clubId/members/:memberId/recovery-code` → 201 `{ code, expiresAt }`.

- [ ] **Step 1: Escribir el test que falla**

`backend/test/recovery-codes.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { activeClub, addGuest, addMember, auditActions, ownerMemberId } from "./fixtures";
import { api, login } from "./helpers";

const issue = (clubId: string, memberId: string, token: string) =>
  api(`/clubs/${clubId}/members/${memberId}/recovery-code`, { method: "POST", token });

describe("códigos de recuperación desde el servidor", () => {
  it("el owner genera uno para un jugador; con él se cambia la contraseña", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const res = await issue(clubId, raul.memberId, owner.token);
    expect(res.status).toBe(201);
    expect(res.body.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const recover = await api("/auth/recover", { body: { username: "raul", code: res.body.code, newPassword: "nueva-clave" } });
    expect(recover.status).toBe(200);
    expect((await login("raul", "nueva-clave")).status).toBe(200);
    expect(await auditActions(clubId)).toContain("recovery.issue");
  });

  it("solo vale el último código generado", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const first = (await issue(clubId, raul.memberId, owner.token)).body.code;
    await issue(clubId, raul.memberId, owner.token);
    const res = await api("/auth/recover", { body: { username: "raul", code: first, newPassword: "nueva-clave" } });
    expect(res.status).toBe(400);
  });

  it("un admin puede para scorer y player, pero no para otro admin ni para el owner", async () => {
    const { clubId } = await activeClub();
    const admin = await addMember(clubId, "admin1", "admin");
    const otherAdmin = await addMember(clubId, "admin2", "admin");
    const scorer = await addMember(clubId, "anotador", "scorer");
    expect((await issue(clubId, scorer.memberId, admin.token)).status).toBe(201);
    expect((await issue(clubId, otherAdmin.memberId, admin.token)).status).toBe(403);
    expect((await issue(clubId, await ownerMemberId(clubId), admin.token)).status).toBe(403);
  });

  it("un player no puede; ni para sí mismo, ni para un sin cuenta", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    const pepe = await addMember(clubId, "pepe", "player");
    const guest = await addGuest(clubId);
    expect((await issue(clubId, pepe.memberId, raul.token)).status).toBe(403);
    expect((await issue(clubId, await ownerMemberId(clubId), owner.token)).status).toBe(403);
    expect((await issue(clubId, guest, owner.token)).status).toBe(403);
  });

  it("no sirve para miembros de otro servidor", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const pepe = await addMember(b.clubId, "pepe", "player");
    expect((await issue(a.clubId, pepe.memberId, a.owner.token)).status).toBe(404);
    expect((await issue(b.clubId, pepe.memberId, a.owner.token)).status).toBe(404);
  });
});
```

- [ ] **Step 2: Ver que falla**

Run: `cd backend && npx vitest run test/recovery-codes.test.ts`
Expected: FAIL. La ruta da 404, así que los tests que esperan 201 o 403 fallan (los que esperan 404 pasan ya).

- [ ] **Step 3: Implementar**

Reemplaza `backend/src/clubs/routes.ts` por la versión completa:

```ts
import { Hono } from "hono";
import { auditStatement } from "../audit";
import { requireAuth } from "../auth/middleware";
import { randomCode } from "../auth/crypto";
import { issueRecoveryCode } from "../auth/recovery";
import { canInviteAs, canIssueRecoveryCode, canManageInvites } from "../authz";
import { errors } from "../http/errors";
import { readJson } from "../http/validate";
import { findInvite, formatCode } from "../invites/model";
import type { AppEnv } from "../types";
import { assertWritable, DEFAULT_SETTINGS, findMember, requireMembership } from "./model";
import { clubRequestSchema, createInviteSchema } from "./schemas";

const MAX_OWNED_CLUBS = 3;
const DAY_MS = 24 * 60 * 60 * 1000;

export const clubRoutes = new Hono<AppEnv>();

clubRoutes.use(requireAuth);

/** Solicitar un servidor. Queda `pending` hasta que el superadmin lo apruebe. */
clubRoutes.post("/", async (c) => {
  const body = await readJson(c, clubRequestSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;

  const owned = await db
    .prepare("SELECT COUNT(*) AS n FROM clubs WHERE owner_user_id = ? AND status IN ('pending', 'active')")
    .bind(userId)
    .first<{ n: number }>();
  if (owned!.n >= MAX_OWNED_CLUBS) throw errors.tooManyClubs();

  const id = crypto.randomUUID();
  const at = now.toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO clubs (id, name, description, status, owner_user_id, request_note, settings, created_at, updated_at)
         VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)`,
      )
      .bind(id, body.name, body.description, userId, body.requestNote, JSON.stringify(DEFAULT_SETTINGS), at, at),
    auditStatement(db, { clubId: id, actorUserId: userId, action: "club.request", entity: "club", entityKey: id }, now),
  ]);
  return c.json({ club: { id, name: body.name, status: "pending" } }, 201);
});

clubRoutes.post("/:clubId/invites", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  assertWritable(club);
  const body = await readJson(c, createInviteSchema);

  let { role, maxUses } = body;
  if (body.targetMemberId) {
    const target = await findMember(db, club.id, body.targetMemberId);
    if (!target || target.role !== "guest" || target.status !== "active") {
      throw errors.invalidInput({ targetMemberId: ["Ese jugador sin cuenta no existe en este servidor"] });
    }
    role = "player";
    maxUses = 1;
  }
  if (!canInviteAs(member.role, role)) throw errors.forbidden();

  const code = randomCode();
  const expiresAt = new Date(now.getTime() + body.expiresInDays * DAY_MS).toISOString();
  await db.batch([
    db
      .prepare(
        `INSERT INTO invites (code, club_id, role, target_member_id, max_uses, expires_at, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(code, club.id, role, body.targetMemberId ?? null, maxUses, expiresAt, userId, now.toISOString()),
    auditStatement(
      db,
      { clubId: club.id, actorUserId: userId, action: "invite.create", entity: "invite", entityKey: code, summary: { role, maxUses } },
      now,
    ),
  ]);
  return c.json(
    { invite: { code: formatCode(code), role, maxUses, uses: 0, expiresAt, targetMemberId: body.targetMemberId ?? null } },
    201,
  );
});

clubRoutes.get("/:clubId/invites", async (c) => {
  const db = c.env.DB;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), c.var.auth.user.id);
  if (!canManageInvites(member.role)) throw errors.forbidden();
  const { results } = await db
    .prepare(
      `SELECT code, role, target_member_id, max_uses, uses, expires_at FROM invites
        WHERE club_id = ? AND revoked_at IS NULL AND expires_at > ? AND uses < max_uses
        ORDER BY created_at DESC`,
    )
    .bind(club.id, new Date().toISOString())
    .all<{ code: string; role: string; target_member_id: string | null; max_uses: number; uses: number; expires_at: string }>();
  return c.json({
    invites: results.map((r) => ({
      code: formatCode(r.code),
      role: r.role,
      maxUses: r.max_uses,
      uses: r.uses,
      expiresAt: r.expires_at,
      targetMemberId: r.target_member_id,
    })),
  });
});

clubRoutes.post("/:clubId/invites/:code/revoke", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  if (!canManageInvites(member.role)) throw errors.forbidden();
  const invite = await findInvite(db, c.req.param("code"));
  if (!invite || invite.clubId !== club.id) throw errors.notFound();
  await db.batch([
    db.prepare("UPDATE invites SET revoked_at = ? WHERE code = ?").bind(now.toISOString(), invite.code),
    auditStatement(db, { clubId: club.id, actorUserId: userId, action: "invite.revoke", entity: "invite", entityKey: invite.code }, now),
  ]);
  return c.body(null, 204);
});

/** Código de recuperación para un miembro que olvidó la contraseña. Se muestra una sola vez. */
clubRoutes.post("/:clubId/members/:memberId/recovery-code", async (c) => {
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const { club, member } = await requireMembership(db, c.req.param("clubId"), userId);
  const target = await findMember(db, club.id, c.req.param("memberId"));
  if (!target || target.status !== "active") throw errors.notFound();
  if (target.id === member.id || !target.userId || !canIssueRecoveryCode(member.role, target.role)) {
    throw errors.forbidden();
  }
  const issued = await issueRecoveryCode(db, target.userId, userId, now);
  await db.batch([
    ...issued.statements,
    auditStatement(db, { clubId: club.id, actorUserId: userId, action: "recovery.issue", entity: "member", entityKey: target.id }, now),
  ]);
  return c.json({ code: issued.code, expiresAt: issued.expiresAt }, 201);
});
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: el owner o un admin generan códigos de recuperación para sus jugadores"
```

---

### Task 9: Borrar la cuenta con servidores

**Files:**
- Modify: `backend/src/me/routes.ts` (reemplazo completo), `backend/test/me.test.ts` (reemplazo completo)

**Interfaces:**
- Consumes: `errors.ownerMustTransfer` (Task 3); las tablas `clubs` y `members` (Task 1).
- Produces: `DELETE /me` da 409 `owner_must_transfer` si es dueño de un servidor activo o suspendido. Si no:
  - sus `members` pasan a `user_id = NULL`, `role = 'guest'` y `display_name = 'Jugador eliminado'`;
  - se borran sus solicitudes pendientes o rechazadas.

- [ ] **Step 1: Escribir los tests que fallan**

Reemplaza `backend/test/me.test.ts` por la versión completa:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember, requestClub } from "./fixtures";
import { api, insertRecoveryCode, login, register } from "./helpers";

describe("POST /auth/password", () => {
  it("cambia la contraseña y cierra las demás sesiones, no la actual", async () => {
    const { token } = await register("kevin", "secreto123");
    const other = (await login("kevin", "secreto123")).body.token;

    const res = await api("/auth/password", {
      token,
      body: { currentPassword: "secreto123", newPassword: "nueva-clave" },
    });
    expect(res.status).toBe(204);
    expect((await api("/me", { token })).status).toBe(200);
    expect((await api("/me", { token: other })).status).toBe(401);
    expect((await login("kevin", "nueva-clave")).status).toBe(200);
  });

  it("con la contraseña actual mal: 401 y no cambia nada", async () => {
    const { token } = await register("kevin", "secreto123");
    const res = await api("/auth/password", { token, body: { currentPassword: "mala", newPassword: "nueva-clave" } });
    expect(res.status).toBe(401);
    expect((await login("kevin", "secreto123")).status).toBe(200);
  });

  it("sin sesión: 401", async () => {
    const res = await api("/auth/password", { body: { currentPassword: "a", newPassword: "nueva-clave" } });
    expect(res.status).toBe(401);
  });
});

describe("/me", () => {
  it("GET devuelve el usuario, sin servidores ni solicitudes al principio", async () => {
    const { token, user } = await register();
    const res = await api("/me", { token });
    expect(res.body).toEqual({ user, clubs: [], clubRequests: [] });
  });

  it("DELETE con la contraseña mal: 401 y la cuenta sigue", async () => {
    const { token } = await register("kevin", "secreto123");
    const res = await api("/me", { method: "DELETE", token, body: { password: "mala" } });
    expect(res.status).toBe(401);
    expect((await api("/me", { token })).status).toBe(200);
  });

  it("DELETE borra la cuenta, sus sesiones y sus códigos, y libera el nombre", async () => {
    const { token, user } = await register("kevin", "secreto123");
    await login("kevin", "secreto123");
    await insertRecoveryCode(user.id, "ABCDEFGH");

    const res = await api("/me", { method: "DELETE", token, body: { password: "secreto123" } });
    expect(res.status).toBe(204);
    expect((await api("/me", { token })).status).toBe(401);
    for (const table of ["users", "sessions", "recovery_codes"]) {
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
      expect(row!.n, table).toBe(0);
    }
    await register("kevin", "otra-clave-1");
  });

  it("DELETE: el dueño de un servidor activo tiene que transferirlo antes", async () => {
    const { owner } = await activeClub("kevin");
    const res = await api("/me", { method: "DELETE", token: owner.token, body: { password: "secreto123" } });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("owner_must_transfer");
    expect((await api("/me", { token: owner.token })).status).toBe(200);
  });

  it("DELETE: sus perfiles quedan como 'Jugador eliminado' sin cuenta, y sus solicitudes pendientes se borran", async () => {
    const { clubId } = await activeClub("kevin");
    const raul = await addMember(clubId, "raul", "admin");
    await requestClub(raul.token, "Solicitud de Raúl");

    const res = await api("/me", { method: "DELETE", token: raul.token, body: { password: "secreto123" } });
    expect(res.status).toBe(204);
    const member = await env.DB.prepare("SELECT user_id, role, display_name FROM members WHERE id = ?")
      .bind(raul.memberId)
      .first();
    expect(member).toEqual({ user_id: null, role: "guest", display_name: "Jugador eliminado" });
    const pending = await env.DB.prepare("SELECT COUNT(*) AS n FROM clubs WHERE name = 'Solicitud de Raúl'").first<{ n: number }>();
    expect(pending!.n).toBe(0);
  });
});
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/me.test.ts`
Expected: FAIL. Al dueño se le borra la cuenta (204 en vez de 409). Para el miembro, el `DELETE FROM users` deja el perfil con el `user_id` viejo, en vez de `NULL` con `role = 'guest'`.

- [ ] **Step 3: Implementar**

Reemplaza `backend/src/me/routes.ts` por:

```ts
import { Hono } from "hono";
import { verifyPassword } from "../auth/crypto";
import { requireAuth } from "../auth/middleware";
import { assertNotLocked, authLimits, recordAttempt } from "../auth/rate-limit";
import { confirmPasswordSchema } from "../auth/schemas";
import { deleteUserSessionsStatement } from "../auth/sessions";
import { findUserById } from "../auth/users";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";

export const meRoutes = new Hono<AppEnv>();

meRoutes.use(requireAuth);

/** El usuario, los servidores donde es miembro activo y sus solicitudes pendientes o rechazadas. */
meRoutes.get("/", async (c) => {
  const db = c.env.DB;
  const userId = c.var.auth.user.id;
  const clubs = await db
    .prepare(
      `SELECT c.id, c.name, c.status, m.id AS member_id, m.role
         FROM members m JOIN clubs c ON c.id = m.club_id
        WHERE m.user_id = ? AND m.status = 'active' AND c.status IN ('active', 'suspended')
        ORDER BY c.name`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; member_id: string; role: string }>();
  const requests = await db
    .prepare(
      `SELECT id, name, status, review_note, created_at FROM clubs
        WHERE owner_user_id = ? AND status IN ('pending', 'rejected') ORDER BY created_at DESC`,
    )
    .bind(userId)
    .all<{ id: string; name: string; status: string; review_note: string | null; created_at: string }>();
  return c.json({
    user: c.var.auth.user,
    clubs: clubs.results.map((r) => ({ id: r.id, name: r.name, status: r.status, memberId: r.member_id, role: r.role })),
    clubRequests: requests.results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      reviewNote: r.review_note,
      createdAt: r.created_at,
    })),
  });
});

meRoutes.delete("/", async (c) => {
  const body = await readJson(c, confirmPasswordSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const rateLimits = authLimits.login(c.var.auth.user.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = (await findUserById(db, userId))!;
  if (!(await verifyPassword(body.password, user.passwordHash))) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  const owns = await db
    .prepare("SELECT 1 FROM clubs WHERE owner_user_id = ? AND status IN ('active', 'suspended') LIMIT 1")
    .bind(userId)
    .first();
  if (owns) throw errors.ownerMustTransfer();

  const at = now.toISOString();
  await db.batch([
    // Sus estadísticas se quedan en cada servidor, a nombre de "Jugador eliminado".
    db
      .prepare(
        "UPDATE members SET user_id = NULL, role = 'guest', display_name = 'Jugador eliminado', nickname = NULL, updated_at = ? WHERE user_id = ?",
      )
      .bind(at, userId),
    db.prepare("DELETE FROM clubs WHERE owner_user_id = ? AND status IN ('pending', 'rejected')").bind(userId),
    deleteUserSessionsStatement(db, userId),
    db.prepare("DELETE FROM recovery_codes WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ]);
  return c.body(null, 204);
});
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (123 tests en 13 archivos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: al borrar la cuenta, el dueño transfiere antes y los perfiles quedan como Jugador eliminado"
```

---

### Task 10: Desplegar a staging y README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: todo lo anterior; `npm run deploy:staging` (PR1).
- Produces: staging con la migración 0002 aplicada y las rutas nuevas.

- [ ] **Step 1: Desplegar**

```bash
cd backend && npx wrangler whoami && npm run deploy:staging
```

Expected: `0002_servidores.sql │ ✅` en la tabla de migraciones, y `Deployed furbo-api-staging`. Si `whoami` dice que no hay sesión, `npx wrangler login`, y que el dueño autorice en el navegador.

- [ ] **Step 2: Prueba de humo en staging**

Con `URL=https://furbo-api-staging.furbo-probe.workers.dev`:

```bash
TOKEN=$(curl -s -X POST "$URL/auth/register" -H 'content-type: application/json' -d '{"username":"prueba.ci","password":"secreto123","displayName":"Prueba"}' | node -pe 'JSON.parse(require("fs").readFileSync(0)).token')
curl -s -X POST "$URL/clubs" -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{"name":"Servidor de prueba"}'
curl -s "$URL/me" -H "authorization: Bearer $TOKEN"
curl -s -o /dev/null -w "admin %{http_code}\n" "$URL/admin/metrics" -H "authorization: Bearer $TOKEN"
curl -s -o /dev/null -w "pagina %{http_code}\n" "$URL/i/NOEXISTE"
curl -s -o /dev/null -w "DELETE %{http_code}\n" -X DELETE "$URL/me" -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{"password":"secreto123"}'
```

Expected, en orden:
- `POST /clubs` devuelve `{"club":{...,"status":"pending"}}`.
- `/me` trae `"clubRequests":[{...,"name":"Servidor de prueba","status":"pending",...}]`.
- `admin 403` (no es superadmin).
- `pagina 404`.
- `DELETE 204`, que borra también la solicitud pendiente. En staging no queda nada de la prueba.

- [ ] **Step 3: README**

En `README.md`, dentro de la sección `## Backend propio (Cloudflare Workers + D1)`, añade al final:

````markdown
- Servidores (PR2):
  - Cualquiera los solicita con `POST /clubs`, y el superadmin los aprueba en `POST /admin/clubs/:id/approve`.
  - Se entra por invitación: el staff la crea con `POST /clubs/:id/invites` y la comparte como
    `https://<api>/i/<CÓDIGO>`.
  - Con `targetMemberId`, la invitación sirve para que un jugador sin cuenta reclame su perfil.
  - Si alguien olvida la contraseña, el owner o un admin genera un código con
    `POST /clubs/:id/members/:memberId/recovery-code` y se lo pasa por WhatsApp.
- Panel del superadmin: todo lo de `/admin/*` (servidores, usuarios, métricas). Primero hay que marcarse
  como superadmin con el comando de arriba.
````

- [ ] **Step 4: Comprobación final**

```bash
cd backend && npm run typecheck && npm test && cd .. && git status --short
```

Expected: `typecheck` limpio y `123 passed`. `git status` muestra solo `README.md`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "README: servidores, invitaciones y panel del superadmin"
```
