import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { purge, PURGE_HOUR_UTC, tick } from "../src/cron";
import { activeClub } from "./fixtures";
import { api } from "./helpers";
import { apply, cmd, pullAll } from "./sync-helpers";

const DAY = 24 * 60 * 60 * 1000;
const count = async (table: string) =>
  (await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>())!.n;
const ago = (days: number) => new Date(Date.now() - days * DAY).toISOString();
const guest = () => ({ id: crypto.randomUUID(), displayName: "Yoandry" });

describe("purga diaria", () => {
  it("borra cambios de más de 90 días, comandos de más de 30, sesiones caducadas e intentos viejos", async () => {
    const { clubId, owner } = await activeClub();
    await apply(owner.token, cmd(clubId, "member.createGuest", guest()));
    expect(await count("changes")).toBeGreaterThan(1);
    expect(await count("applied_commands")).toBeGreaterThan(0);

    // Todo lo del servidor menos el último cambio, hace 100 días; los comandos, hace 40.
    await env.DB.prepare("UPDATE changes SET at = ? WHERE id < (SELECT MAX(id) FROM changes)").bind(ago(100)).run();
    await env.DB.prepare("UPDATE applied_commands SET at = ?").bind(ago(40)).run();
    await env.DB.prepare("UPDATE sessions SET expires_at = ? WHERE user_id <> ?").bind(ago(10), owner.user.id).run();
    await env.DB.prepare("INSERT INTO login_attempts (key, window_start, count) VALUES ('viejo', ?, 3), ('nuevo', ?, 1)")
      .bind(ago(8), ago(0))
      .run();
    const sessions = await count("sessions");

    await purge(env.DB, new Date());
    expect(await count("changes")).toBe(1);
    expect(await count("applied_commands")).toBe(0);
    expect(await count("sessions")).toBe(1);
    expect(sessions).toBeGreaterThan(1);
    const keys = (await env.DB.prepare("SELECT key FROM login_attempts").all<{ key: string }>()).results.map((r) => r.key);
    expect(keys).toContain("nuevo");
    expect(keys).not.toContain("viejo");
    // La sesión del dueño sigue viva.
    expect((await api("/me", { token: owner.token })).status).toBe(200);
    // Otra vez no hace nada raro.
    await purge(env.DB, new Date());
    expect(await count("changes")).toBe(1);
  });

  it("un teléfono con un cursor de antes de la purga recibe la foto completa", async () => {
    const { clubId, owner } = await activeClub();
    const old = (await pullAll(owner.token)).clubs[clubId]!.cursor;
    await apply(owner.token, cmd(clubId, "member.createGuest", guest()));
    const latest = (await pullAll(owner.token, { [clubId]: old })).clubs[clubId]!.cursor;
    await env.DB.prepare("UPDATE changes SET at = ?").bind(ago(100)).run();
    await purge(env.DB, new Date());
    expect(await count("changes")).toBe(0);

    const stale = (await pullAll(owner.token, { [clubId]: old })).clubs[clubId]!;
    expect(stale.snapshot).toBe(true);
    expect(stale.upserts.member).toHaveLength(2);
    // El cursor no vuelve a 0: si no, cada pull sería otra foto completa.
    expect(stale.cursor).toBe(latest);
    const fresh = (await pullAll(owner.token, { [clubId]: stale.cursor })).clubs[clubId]!;
    expect(fresh.snapshot).toBe(false);
    expect(fresh.upserts).toEqual({});

    // Un servidor nuevo (sin cambios purgados) sigue igual.
    const other = await activeClub("otro", "Otro");
    expect((await pullAll(other.owner.token)).clubs[other.clubId]!.cursor).toBeGreaterThan(latest);
  });

  it("un servidor tranquilo no recibe una foto completa cada día: su cursor avanza con los demás", async () => {
    const quiet = await activeClub();
    const busy = await activeClub("otro", "Otro");
    let cursor = (await pullAll(quiet.owner.token)).clubs[quiet.clubId]!.cursor;
    for (let day = 0; day < 3; day++) {
      // En el otro servidor pasan cosas; todo lo anterior ya es viejo y se purga.
      await apply(busy.owner.token, cmd(busy.clubId, "member.createGuest", guest()));
      await env.DB.prepare("UPDATE changes SET at = ? WHERE id < (SELECT MAX(id) FROM changes)").bind(ago(100)).run();
      const before = (await pullAll(quiet.owner.token, { [quiet.clubId]: cursor })).clubs[quiet.clubId]!;
      expect(before.snapshot, `día ${day}, antes de la purga`).toBe(false);
      await purge(env.DB, new Date());
      const after = (await pullAll(quiet.owner.token, { [quiet.clubId]: before.cursor })).clubs[quiet.clubId]!;
      expect(after.snapshot, `día ${day}`).toBe(false);
      cursor = after.cursor;
    }
  });

  it("el cron solo purga en la primera pasada de su hora", async () => {
    const { clubId, owner } = await activeClub();
    await apply(owner.token, cmd(clubId, "member.createGuest", guest()));
    await env.DB.prepare("UPDATE applied_commands SET at = ?").bind(ago(40)).run();
    const today = new Date();
    const at = (h: number) => new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate(), h));
    await tick(env, at((PURGE_HOUR_UTC + 1) % 24));
    expect(await count("applied_commands")).toBe(1);
    await tick(env, at(PURGE_HOUR_UTC));
    expect(await count("applied_commands")).toBe(0);
  });
});
