import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";

const at = new Date().toISOString();

function season(id: string, active: 0 | 1, closed: 0 | 1 = 0) {
  return env.DB.prepare(
    "INSERT INTO seasons (id, club_id, name, start_date, is_active, is_closed, created_at, updated_at) VALUES (?, 'c1', 'T', '2026-01-01', ?, ?, ?, ?)",
  )
    .bind(id, active, closed, at, at)
    .run();
}

describe("esquema de temporadas y sync", () => {
  beforeEach(async () => {
    await env.DB.prepare(
      "INSERT INTO clubs (id, name, status, owner_user_id, settings, created_at, updated_at) VALUES ('c1', 'Club', 'active', 'u1', '{}', ?, ?)",
    )
      .bind(at, at)
      .run();
  });

  it("como mucho una temporada activa por servidor; inactivas, las que sean", async () => {
    await season("s1", 1);
    await expect(season("s2", 1)).rejects.toThrow(/UNIQUE constraint failed/);
    await season("s3", 0);
    await season("s4", 0);
  });

  it("una temporada no puede estar activa y cerrada a la vez", async () => {
    await expect(season("s1", 1, 1)).rejects.toThrow(/CHECK constraint failed/);
  });

  it("changes solo acepta upsert o delete", async () => {
    await expect(
      env.DB.prepare("INSERT INTO changes (club_id, entity, entity_key, op, at) VALUES ('c1', 'member', 'm1', 'borrar', ?)").bind(at).run(),
    ).rejects.toThrow(/CHECK constraint failed/);
  });
});
