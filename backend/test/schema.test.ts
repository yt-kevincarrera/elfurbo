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
