import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember } from "./fixtures";
import { api } from "./helpers";
import { cmd, push } from "./sync-helpers";

const guest = (clubId: string, name = "Yoandry") => cmd(clubId, "member.createGuest", { id: crypto.randomUUID(), displayName: name });

describe("POST /sync/push", () => {
  it("aplica en orden y deja constancia en changes y applied_commands", async () => {
    const { clubId, owner } = await activeClub();
    const a = guest(clubId, "Uno");
    const b = guest(clubId, "Dos");
    const results = await push(owner.token, a, b);
    expect(results).toEqual([
      { id: a.id, status: "applied" },
      { id: b.id, status: "applied" },
    ]);
    const changes = await env.DB.prepare("SELECT entity, entity_key FROM changes WHERE entity = 'member' ORDER BY id DESC LIMIT 2").all();
    expect(changes.results.map((r) => r.entity_key)).toEqual([
      (b.payload as { id: string }).id,
      (a.payload as { id: string }).id,
    ]);
    const applied = await env.DB.prepare("SELECT COUNT(*) AS n FROM applied_commands WHERE status = 'applied'").first<{ n: number }>();
    expect(applied!.n).toBe(2);
  });

  it("reenviar el mismo comando (respuesta perdida) da duplicate y no lo aplica otra vez", async () => {
    const { clubId, owner } = await activeClub();
    const a = guest(clubId);
    await push(owner.token, a);
    const [again] = await push(owner.token, a);
    expect(again).toEqual({ id: a.id, status: "duplicate", original: { status: "applied" } });
    const guests = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE role = 'guest'").first<{ n: number }>();
    expect(guests!.n).toBe(1);
  });

  it("los rechazos también se guardan: el reintento recibe el mismo rechazo", async () => {
    const { clubId } = await activeClub();
    const player = await addMember(clubId, "raul", "player");
    const a = guest(clubId);
    const [first] = await push(player.token, a);
    expect(first).toMatchObject({ status: "rejected", code: "forbidden" });
    const [again] = await push(player.token, a);
    expect(again).toMatchObject({ status: "duplicate", original: { status: "rejected", code: "forbidden" } });
  });

  it("uno rechazado no frena a los siguientes", async () => {
    const { clubId, owner } = await activeClub();
    const bad = cmd(clubId, "member.createGuest", { id: "no-es-uuid", displayName: "X" });
    const good = guest(clubId);
    const results = await push(owner.token, bad, good);
    expect(results.map((r) => r.status)).toEqual(["rejected", "applied"]);
    expect(results[0]).toMatchObject({ code: "invalid_input" });
    expect(results[0]!.details).toHaveProperty("id");
  });

  it("tipo desconocido (app más nueva que el servidor): rechazado con unknown_command", async () => {
    const { clubId, owner } = await activeClub();
    const [r] = await push(owner.token, cmd(clubId, "matchday.teleport"));
    expect(r).toMatchObject({ status: "rejected", code: "unknown_command" });
  });

  it("un servidor del que no es miembro: rechazado con not_found, sin tocar nada", async () => {
    const a = await activeClub("kevin");
    const b = await activeClub("raul", "Otro");
    const [r] = await push(a.owner.token, guest(b.clubId));
    expect(r).toMatchObject({ status: "rejected", code: "not_found" });
    const guests = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE club_id = ? AND role = 'guest'").bind(b.clubId).first<{ n: number }>();
    expect(guests!.n).toBe(0);
  });

  it("un servidor suspendido es de solo lectura", async () => {
    const { clubId, owner } = await activeClub();
    await env.DB.prepare("UPDATE clubs SET status = 'suspended' WHERE id = ?").bind(clubId).run();
    const [r] = await push(owner.token, guest(clubId));
    expect(r).toMatchObject({ status: "rejected", code: "club_suspended" });
  });

  it("un id de comando ya usado por otra persona se rechaza, sin revelar su resultado", async () => {
    const { clubId, owner } = await activeClub();
    const raul = await addMember(clubId, "raul", "admin");
    const a = guest(clubId);
    await push(owner.token, a);
    const [r] = await push(raul.token, a);
    expect(r).toMatchObject({ status: "rejected", code: "invalid_input" });
    expect(r).not.toHaveProperty("original");
  });

  it("si el comando choca con algo ya guardado (mismo id de jugador): conflict", async () => {
    const { clubId, owner } = await activeClub();
    const id = crypto.randomUUID();
    await push(owner.token, cmd(clubId, "member.createGuest", { id, displayName: "Uno" }));
    const [r] = await push(owner.token, cmd(clubId, "member.createGuest", { id, displayName: "Otro" }));
    expect(r).toMatchObject({ status: "rejected", code: "conflict" });
  });

  it("valida el sobre: entre 1 y 200 comandos, id uuid y clientAt ISO", async () => {
    const { clubId, owner } = await activeClub();
    const send = (commands: unknown) => api("/sync/push", { token: owner.token, body: { commands } });
    expect((await send([])).status).toBe(400);
    expect((await send(Array.from({ length: 201 }, () => guest(clubId)))).status).toBe(400);
    expect((await send([{ ...guest(clubId), clientAt: "ayer" }])).status).toBe(400);
    expect((await send([{ ...guest(clubId), id: "1" }])).status).toBe(400);
  });

  it("admite envíos de hasta 256 KB (más que el límite general de 64 KB)", async () => {
    const { clubId, owner } = await activeClub();
    const commands = Array.from({ length: 150 }, () =>
      cmd(clubId, "member.update", { memberId: "x".repeat(60), displayName: "y".repeat(40) }, {}),
    );
    const big = JSON.stringify({ commands, pad: "z".repeat(100 * 1024) });
    const res = await api("/sync/push", { token: owner.token, body: big });
    expect(res.status).toBe(200);
    const huge = JSON.stringify({ commands: [guest(clubId)], pad: "z".repeat(300 * 1024) });
    expect((await api("/sync/push", { token: owner.token, body: huge })).status).toBe(413);
  });

  it("exige sesión", async () => {
    expect((await api("/sync/push", { body: { commands: [] } })).status).toBe(401);
  });
});
