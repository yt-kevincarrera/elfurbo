import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { applyCommands } from "../src/sync/push";
import { activeClub, addMember } from "./fixtures";
import { api } from "./helpers";
import { cmd, push } from "./sync-helpers";

const guest = (clubId: string) => cmd(clubId, "member.createGuest", { id: crypto.randomUUID(), displayName: "X" });

async function stored() {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM applied_commands").first<{ n: number }>();
  return row!.n;
}

describe("límites del push", () => {
  it("si no alcanza el presupuesto de consultas, el resto vuelve aplazado (en orden, sin guardarse) y se aplica al reenviarlo", async () => {
    const { clubId, owner } = await activeClub();
    const me = (await api("/me", { token: owner.token })).body.user;
    const commands = Array.from({ length: 6 }, () => guest(clubId));
    const results = await applyCommands(env.DB, me, commands, new Date(), { queryBudget: 20 });
    const statuses = results.map((r) => r.status);
    const firstDeferred = statuses.indexOf("deferred");
    expect(firstDeferred).toBeGreaterThan(0);
    expect(statuses.slice(0, firstDeferred).every((s) => s === "applied")).toBe(true);
    expect(statuses.slice(firstDeferred).every((s) => s === "deferred")).toBe(true);
    expect(await stored()).toBe(firstDeferred);

    const retry = await push(owner.token, ...commands.slice(firstDeferred));
    expect(retry.every((r) => r.status === "applied")).toBe(true);
  });

  it("los duplicados no gastan presupuesto: reenviar todo (respuesta perdida) avanza con los que faltaban", async () => {
    const { clubId, owner } = await activeClub();
    const me = (await api("/me", { token: owner.token })).body.user;
    const commands = Array.from({ length: 8 }, () => guest(clubId));
    const first = await applyCommands(env.DB, me, commands, new Date(), { queryBudget: 20 });
    const applied = first.filter((r) => r.status === "applied").length;
    expect(applied).toBeLessThan(8);
    const again = await applyCommands(env.DB, me, commands, new Date(), { queryBudget: 20 });
    expect(again.filter((r) => r.status === "duplicate")).toHaveLength(applied);
    expect(again.filter((r) => r.status === "applied").length).toBeGreaterThan(0);
  });

  it("con el tiempo agotado procesa al menos uno y aplaza el resto (respuestas cortas para conexiones malas)", async () => {
    const { clubId, owner } = await activeClub();
    const me = (await api("/me", { token: owner.token })).body.user;
    const commands = Array.from({ length: 4 }, () => guest(clubId));
    const results = await applyCommands(env.DB, me, commands, new Date(), { timeBudgetMs: 0 });
    expect(results.map((r) => r.status)).toEqual(["applied", "deferred", "deferred", "deferred"]);
  });

  it("crear jugadores no vuelve a leer la membresía en cada comando: 30 entran con poco presupuesto", async () => {
    const { clubId, owner } = await activeClub();
    const me = (await api("/me", { token: owner.token })).body.user;
    const commands = Array.from({ length: 30 }, () => guest(clubId));
    const results = await applyCommands(env.DB, me, commands, new Date(), { queryBudget: 200 });
    expect(results.every((r) => r.status === "applied")).toBe(true);
  });

  it("el mismo comando en dos envíos a la vez: uno se aplica, el otro es duplicate (sin error 500)", async () => {
    const { clubId, owner } = await activeClub();
    const me = (await api("/me", { token: owner.token })).body.user;
    const c = guest(clubId);
    const [a, b] = await Promise.all([
      applyCommands(env.DB, me, [c], new Date()),
      applyCommands(env.DB, me, [c], new Date()),
    ]);
    expect([a[0]!.status, b[0]!.status].sort()).toEqual(["applied", "duplicate"]);
    const guests = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE role = 'guest'").first<{ n: number }>();
    expect(guests!.n).toBe(1);
  });

  it("lo que no depende del estado del servidor no se guarda (no gasta escrituras): no ser miembro, payload inválido", async () => {
    const { clubId, owner } = await activeClub();
    const before = await stored();
    await push(owner.token, ...Array.from({ length: 5 }, () => guest("servidor-inventado")));
    await push(owner.token, cmd(clubId, "member.createGuest", { id: "no-uuid", displayName: "X" }));
    expect(await stored()).toBe(before);
  });

  it("un tipo desconocido (app más nueva que el servidor) queda aplazado, no rechazado, para reintentarlo tras el despliegue", async () => {
    const { clubId, owner } = await activeClub();
    const [r] = await push(owner.token, cmd(clubId, "matchday.create", {}));
    expect(r).toMatchObject({ status: "deferred", code: "unknown_command" });
    expect(await stored()).toBe(0);
  });

  it("las decisiones sobre el estado del servidor sí se guardan (forbidden)", async () => {
    const { clubId } = await activeClub();
    const raul = await addMember(clubId, "raul", "player");
    await push(raul.token, guest(clubId));
    expect(await stored()).toBe(1);
  });
});
