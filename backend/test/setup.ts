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
  // Claves foráneas diferidas: el orden de creación ya no sirve desde que la 0006 rehízo matchdays.
  await env.DB.batch([
    env.DB.prepare("PRAGMA defer_foreign_keys = true"),
    ...results.map((t) => env.DB.prepare(`DELETE FROM "${t.name}"`)),
  ]);
});
