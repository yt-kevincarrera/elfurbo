import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { activeClub } from "./fixtures";
import { api, register } from "./helpers";

// Archivo aparte: rompe la tabla de auditoría a propósito y eso afectaría a otros tests del archivo.
describe("aceptar una invitación es todo o nada", () => {
  it("si no se puede auditar, no entra nadie y el uso no se pierde", async () => {
    const { clubId, owner } = await activeClub();
    const code = (await api(`/clubs/${clubId}/invites`, { token: owner.token, body: {} })).body.invite.code;
    const raul = await register("raul");
    await env.DB.prepare("DROP TABLE audit_log").run();

    const res = await api(`/invites/${code}/accept`, { method: "POST", token: raul.token });
    expect(res.status).toBe(500);
    const member = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE user_id = ?").bind(raul.user.id).first<{ n: number }>();
    const invite = await env.DB.prepare("SELECT uses FROM invites").first<{ uses: number }>();
    expect({ members: member!.n, uses: invite!.uses }).toEqual({ members: 0, uses: 0 });
  });
});
