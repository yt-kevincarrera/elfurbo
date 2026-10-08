import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub, addMember, auditActions } from "./fixtures";
import { api, register, type Registered } from "./helpers";
import { apply, cmd, pullAll, rejection } from "./sync-helpers";

const post = (path: string, token: string, body: unknown = {}) => api(path, { method: "POST", token, body });

async function tournament(host: Awaited<ReturnType<typeof activeClub>>, extra: Record<string, unknown> = {}) {
  const res = await post(`/clubs/${host.clubId}/tournaments`, host.owner.token, { name: "Copa Verano", format: "league", ...extra });
  expect(res.status, JSON.stringify(res.body)).toBe(201);
  return res.body.club.id as string;
}

/** Mete a `user` en el torneo como jugador, directo en D1. */
async function joinTournament(tournamentId: string, user: Registered) {
  const id = crypto.randomUUID();
  const at = new Date().toISOString();
  await env.DB.prepare(
    "INSERT INTO members (id, club_id, user_id, role, display_name, created_at, updated_at) VALUES (?, ?, ?, 'player', ?, ?, ?)",
  )
    .bind(id, tournamentId, user.user.id, user.user.displayName, at, at)
    .run();
  return id;
}

const team = (extra: Record<string, unknown> = {}) => ({ id: crypto.randomUUID(), name: "Los Tigres", shortName: "tig", ...extra });

async function teamRow(id: string) {
  return env.DB.prepare("SELECT * FROM teams WHERE id = ?").bind(id).first<Record<string, unknown>>();
}

async function players(teamId: string) {
  const { results } = await env.DB.prepare("SELECT member_id FROM team_players WHERE team_id = ? AND status = 'active' ORDER BY member_id")
    .bind(teamId)
    .all<{ member_id: string }>();
  return results.map((r) => r.member_id);
}

describe("organizar un torneo", () => {
  it("lo crea el owner o un admin del servidor: queda de dueño, en /me y en el pull con su entidad", async () => {
    const host = await activeClub();
    const id = await tournament(host, { description: "Fútbol 7", visibility: "public" });
    const me = await api("/me", { token: host.owner.token });
    expect(me.body.clubs.find((c: { id: string }) => c.id === id)).toMatchObject({ kind: "tournament", role: "owner" });
    const pull = (await pullAll(host.owner.token)).clubs[id]!;
    expect(pull.upserts.club).toMatchObject([{ kind: "tournament", hostClubId: host.clubId, visibility: "public" }]);
    expect(pull.upserts.tournament).toMatchObject([{ id, format: "league", status: "draft", rules: { pointsWin: 3 }, maxTeams: 16 }]);
    expect(pull.upserts.season).toBeUndefined();
    expect((await pullAll(host.owner.token)).clubs[host.clubId]!.upserts.team).toBeUndefined();
    expect(await auditActions(host.clubId)).toContain("tournament.create");

    const admin = await addMember(host.clubId, "jefe", "admin");
    expect((await post(`/clubs/${host.clubId}/tournaments`, admin.token, { name: "Otra", format: "cup" })).status).toBe(201);
    const player = await addMember(host.clubId, "jugador", "player");
    expect((await post(`/clubs/${host.clubId}/tournaments`, player.token, { name: "Otra", format: "cup" })).status).toBe(403);
  });

  it("como mucho 3 sin terminar por anfitrión; y no desde un torneo", async () => {
    const host = await activeClub();
    const first = await tournament(host);
    await tournament(host);
    await tournament(host);
    const res = await post(`/clubs/${host.clubId}/tournaments`, host.owner.token, { name: "Cuarta", format: "cup" });
    expect(res.body.error.code).toBe("too_many_tournaments");
    expect((await post(`/clubs/${first}/tournaments`, host.owner.token, { name: "Dentro", format: "cup" })).body.error.code).toBe(
      "wrong_kind",
    );
  });

  it("los comandos de jornadas no van en un torneo, ni los de equipos en un servidor", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    expect(
      await rejection(host.owner.token, cmd(id, "matchday.create", { id: crypto.randomUUID(), startsAt: new Date().toISOString() })),
    ).toBe("wrong_kind");
    expect(await rejection(host.owner.token, cmd(host.clubId, "team.create", team()))).toBe("wrong_kind");
    // Los de miembros sí, en los dos.
    await apply(host.owner.token, cmd(id, "member.createGuest", { id: crypto.randomUUID(), displayName: "Yoandry" }));
  });
});

describe("tournament.update", () => {
  it("cambia reglas (mezcladas con las de antes), fechas y plantillas; el estado solo avanza", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    await apply(
      host.owner.token,
      cmd(id, "tournament.update", { rules: { pointsWin: 2, legs: 2 }, maxPlayers: 12, startsOn: "2026-11-01", format: "cup" }),
    );
    const row = await env.DB.prepare("SELECT * FROM tournaments WHERE club_id = ?").bind(id).first<Record<string, unknown>>();
    expect(row).toMatchObject({ format: "cup", max_players: 12, starts_on: "2026-11-01" });
    expect(JSON.parse(String(row!.rules))).toMatchObject({ pointsWin: 2, legs: 2, pointsDraw: 1 });

    await apply(host.owner.token, cmd(id, "tournament.update", { status: "registration" }));
    expect(await rejection(host.owner.token, cmd(id, "tournament.update", { status: "registration" }))).toBe("invalid_state");
    // Para empezar hacen falta 2 equipos aprobados.
    expect(await rejection(host.owner.token, cmd(id, "tournament.update", { status: "in_progress" }))).toBe("invalid_state");
    await apply(host.owner.token, cmd(id, "team.create", team()));
    await apply(host.owner.token, cmd(id, "team.create", team({ name: "Leones", shortName: "LEO" })));
    await apply(host.owner.token, cmd(id, "tournament.update", { status: "in_progress" }));
  });

  it.each([
    [{ rules: { pointsWin: 99 } }],
    [{ rules: { inventada: 1 } }],
    [{ rules: { tiebreakers: ["points", "points"] } }],
    [{ minPlayers: 20, maxPlayers: 10 }],
    [{ status: "finished" }],
    [{}],
  ])("rechaza %o", async (payload) => {
    const host = await activeClub();
    const id = await tournament(host);
    expect(await rejection(host.owner.token, cmd(id, "tournament.update", payload))).toBe("invalid_input");
  });

  it("solo organizadores", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    await joinTournament(id, yoan);
    expect(await rejection(yoan.token, cmd(id, "tournament.update", { maxTeams: 8 }))).toBe("forbidden");
  });
});

describe("equipos", () => {
  it("un organizador crea equipos aprobados con capitán; un jugador, pendientes y solo con la inscripción abierta", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    const yoanMember = await joinTournament(id, yoan);
    const tigres = team({ captainMemberId: yoanMember });
    await apply(host.owner.token, cmd(id, "team.create", tigres));
    expect(await teamRow(tigres.id)).toMatchObject({ status: "approved", captain_member_id: yoanMember, short_name: "TIG" });
    expect(await players(tigres.id)).toEqual([yoanMember]);

    const pepe = await register("pepe");
    await joinTournament(id, pepe);
    expect(await rejection(pepe.token, cmd(id, "team.create", team()))).toBe("registration_closed");
    await apply(host.owner.token, cmd(id, "tournament.update", { status: "registration" }));
    const leones = team({ name: "Leones", shortName: "LEO" });
    await apply(pepe.token, cmd(id, "team.create", leones));
    expect(await teamRow(leones.id)).toMatchObject({ status: "pending" });
    // Pepe ya está en un equipo: no puede inscribir otro.
    expect(await rejection(pepe.token, cmd(id, "team.create", team({ name: "Otro", shortName: "OTR" })))).toBe("already_in_team");
  });

  it("no se aprueban más equipos de los que admite el torneo", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    await apply(host.owner.token, cmd(id, "tournament.update", { maxTeams: 2 }));
    await apply(host.owner.token, cmd(id, "team.create", team()));
    await apply(host.owner.token, cmd(id, "team.create", team({ name: "Leones", shortName: "LEO" })));
    expect(await rejection(host.owner.token, cmd(id, "team.create", team({ name: "Pumas", shortName: "PUM" })))).toBe("tournament_full");
  });

  it("plantilla: el capitán la arma mientras no empiece, con tope; el organizador siempre", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    await apply(host.owner.token, cmd(id, "tournament.update", { minPlayers: 1, maxPlayers: 2, status: "registration" }));
    const yoan = await register("yoan");
    const captain = await joinTournament(id, yoan);
    const t = team({ captainMemberId: captain });
    await apply(host.owner.token, cmd(id, "team.create", t));
    const pepe = await joinTournament(id, await register("pepe"));
    const lia = await joinTournament(id, await register("lia"));
    await apply(yoan.token, cmd(id, "team.addPlayer", { teamId: t.id, memberId: pepe, shirt: 10 }));
    expect(await rejection(yoan.token, cmd(id, "team.addPlayer", { teamId: t.id, memberId: lia }))).toBe("team_full");
    expect(await rejection(yoan.token, cmd(id, "team.removePlayer", { teamId: t.id, memberId: captain }))).toBe("invalid_state");
    await apply(yoan.token, cmd(id, "team.removePlayer", { teamId: t.id, memberId: pepe }));
    await apply(yoan.token, cmd(id, "team.addPlayer", { teamId: t.id, memberId: lia }));
    expect((await players(t.id)).sort()).toEqual([captain, lia].sort());

    // Empieza el torneo: el capitán ya no toca la plantilla; el organizador sí.
    await apply(host.owner.token, cmd(id, "team.create", team({ name: "Leones", shortName: "LEO" })));
    await apply(host.owner.token, cmd(id, "tournament.update", { status: "in_progress" }));
    expect(await rejection(yoan.token, cmd(id, "team.removePlayer", { teamId: t.id, memberId: lia }))).toBe("forbidden");
    await apply(host.owner.token, cmd(id, "team.removePlayer", { teamId: t.id, memberId: lia }));
  });

  it("retirar un equipo libera su plantilla; el capitán solo puede retirar el suyo", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    await apply(host.owner.token, cmd(id, "tournament.update", { status: "registration" }));
    const yoan = await register("yoan");
    const captain = await joinTournament(id, yoan);
    const t = team({ captainMemberId: captain });
    await apply(host.owner.token, cmd(id, "team.create", t));
    expect(await rejection(yoan.token, cmd(id, "team.setStatus", { teamId: t.id, status: "approved" }))).toBe("forbidden");
    await apply(yoan.token, cmd(id, "team.setStatus", { teamId: t.id, status: "withdrawn" }));
    expect(await players(t.id)).toEqual([]);
    // Ya puede inscribir otro.
    await apply(yoan.token, cmd(id, "team.create", team({ name: "Nuevo", shortName: "NUE" })));
    expect(await rejection(host.owner.token, cmd(id, "team.setStatus", { teamId: t.id, status: "approved" }))).toBe("invalid_state");
  });

  it("representar a un servidor: el capitán tiene que ser miembro de él", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const owner = (await api("/me", { token: host.owner.token })).body.clubs.find((c: { id: string }) => c.id === id).memberId;
    await apply(host.owner.token, cmd(id, "team.create", team({ captainMemberId: owner, representsClubId: host.clubId })));
    const other = await activeClub("otro", "Otro");
    expect(
      await rejection(
        host.owner.token,
        cmd(id, "team.create", team({ name: "Leones", shortName: "LEO", captainMemberId: null, representsClubId: other.clubId })),
      ),
    ).toBe("invalid_input");
  });
});

describe("inscribirse desde el directorio", () => {
  it("en un torneo público con inscripción abierta: entra, crea su equipo pendiente y queda de capitán", async () => {
    const host = await activeClub();
    const id = await tournament(host, { visibility: "public" });
    const yoan = await register("yoan");
    expect((await post(`/tournaments/${id}/teams`, yoan.token, { name: "Tigres", shortName: "tig" })).body.error.code).toBe(
      "registration_closed",
    );
    await apply(host.owner.token, cmd(id, "tournament.update", { status: "registration" }));
    const res = await post(`/tournaments/${id}/teams`, yoan.token, { name: "Tigres", shortName: "tig", color: 3 });
    expect(res.status).toBe(201);
    expect(await teamRow(res.body.team.id)).toMatchObject({ status: "pending", short_name: "TIG", color: 3 });
    expect((await api("/me", { token: yoan.token })).body.clubs[0]).toMatchObject({ id, kind: "tournament", role: "player" });
    expect((await post(`/tournaments/${id}/teams`, yoan.token, { name: "Otro", shortName: "OTR" })).body.error.code).toBe(
      "already_in_team",
    );
  });

  it("uno privado o que no es torneo: 404", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    expect((await post(`/tournaments/${id}/teams`, yoan.token, { name: "Tigres", shortName: "TIG" })).status).toBe(404);
    expect((await post(`/tournaments/${host.clubId}/teams`, yoan.token, { name: "Tigres", shortName: "TIG" })).status).toBe(404);
  });
});

describe("invitaciones de equipo", () => {
  it("el capitán invita a su equipo; quien acepta entra en el torneo y en el equipo", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    await apply(host.owner.token, cmd(id, "tournament.update", { minPlayers: 1, maxPlayers: 2 }));
    const yoan = await register("yoan");
    const captain = await joinTournament(id, yoan);
    const t = team({ captainMemberId: captain });
    await apply(host.owner.token, cmd(id, "team.create", t));
    const invite = await post(`/clubs/${id}/invites`, yoan.token, { teamId: t.id, maxUses: 5, role: "admin" });
    expect(invite.status).toBe(201);
    expect(invite.body.invite).toMatchObject({ role: "player", teamId: t.id });
    const code = invite.body.invite.code;
    expect((await api(`/invites/${code}`)).body.team).toEqual({ id: t.id, name: "Los Tigres" });

    const pepe = await register("pepe");
    expect((await post(`/invites/${code}/accept`, pepe.token)).status).toBe(201);
    expect((await players(t.id)).length).toBe(2);
    // Lleno.
    const lia = await register("lia");
    expect((await post(`/invites/${code}/accept`, lia.token)).body.error.code).toBe("team_full");
  });

  it("un jugador que no es capitán no invita a un equipo; quien ya está en otro equipo no entra", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    const captain = await joinTournament(id, yoan);
    const t = team({ captainMemberId: captain });
    await apply(host.owner.token, cmd(id, "team.create", t));
    const pepe = await register("pepe");
    const pepeMember = await joinTournament(id, pepe);
    expect((await post(`/clubs/${id}/invites`, pepe.token, { teamId: t.id })).status).toBe(403);
    const other = team({ name: "Leones", shortName: "LEO", captainMemberId: pepeMember });
    await apply(host.owner.token, cmd(id, "team.create", other));
    const code = (await post(`/clubs/${id}/invites`, yoan.token, { teamId: t.id })).body.invite.code;
    expect((await post(`/invites/${code}/accept`, pepe.token)).body.error.code).toBe("already_in_team");
  });
});

describe("lo que no se cuela (revisión)", () => {
  it("una invitación de equipo no reclama perfiles sin cuenta", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    const captain = await joinTournament(id, yoan);
    const t = team({ captainMemberId: captain });
    await apply(host.owner.token, cmd(id, "team.create", t));
    const guest = crypto.randomUUID();
    await apply(host.owner.token, cmd(id, "member.createGuest", { id: guest, displayName: "Yoandry" }));
    const res = await post(`/clubs/${id}/invites`, yoan.token, { teamId: t.id, targetMemberId: guest });
    expect(res.status).toBe(400);
  });

  it("irse o ser expulsado libera el sitio en el equipo; el capitán no se puede ir sin nombrar a otro", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    const captain = await joinTournament(id, yoan);
    const pepe = await register("pepe");
    const pepeMember = await joinTournament(id, pepe);
    const t = team({ captainMemberId: captain });
    await apply(host.owner.token, cmd(id, "team.create", t));
    await apply(host.owner.token, cmd(id, "team.addPlayer", { teamId: t.id, memberId: pepeMember }));
    expect(await rejection(yoan.token, cmd(id, "member.leave"))).toBe("invalid_state");
    await apply(pepe.token, cmd(id, "member.leave"));
    expect(await players(t.id)).toEqual([captain]);
    await apply(host.owner.token, cmd(id, "member.ban", { memberId: captain }));
    expect(await players(t.id)).toEqual([]);
    expect((await teamRow(t.id))!.captain_member_id).toBeNull();
  });

  it("quien ya está en el torneo sin equipo puede usar una invitación de equipo", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    const t = team({ captainMemberId: await joinTournament(id, yoan) });
    await apply(host.owner.token, cmd(id, "team.create", t));
    const pepe = await register("pepe");
    const pepeMember = await joinTournament(id, pepe);
    const code = (await post(`/clubs/${id}/invites`, yoan.token, { teamId: t.id })).body.invite.code;
    const res = await post(`/invites/${code}/accept`, pepe.token);
    expect(res.status).toBe(201);
    expect(res.body.team).toEqual({ id: t.id });
    expect(await players(t.id)).toContain(pepeMember);
  });

  it("dorsales: el capitán ya no los cambia cuando empieza el torneo; el máximo de equipos no baja de los aprobados", async () => {
    const host = await activeClub();
    const id = await tournament(host);
    const yoan = await register("yoan");
    const captain = await joinTournament(id, yoan);
    const t = team({ captainMemberId: captain });
    await apply(host.owner.token, cmd(id, "team.create", t));
    await apply(host.owner.token, cmd(id, "team.create", team({ name: "Leones", shortName: "LEO" })));
    await apply(yoan.token, cmd(id, "team.setShirt", { teamId: t.id, memberId: captain, shirt: 9 }));
    expect(await rejection(host.owner.token, cmd(id, "tournament.update", { maxTeams: 1 + 0 }))).toBe("invalid_input");
    await apply(host.owner.token, cmd(id, "tournament.update", { status: "in_progress" }));
    expect(await rejection(yoan.token, cmd(id, "team.setShirt", { teamId: t.id, memberId: captain, shirt: 10 }))).toBe("forbidden");
  });
});
