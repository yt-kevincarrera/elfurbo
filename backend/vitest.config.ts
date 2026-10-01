import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: { bindings: { TEST_MIGRATIONS: migrations } },
      }),
    ],
    // Cada login o registro hace PBKDF2 de 100k iteraciones; los tests con decenas de ellos
    // pasan de los 5 s por defecto en máquinas lentas (y en el CI).
    test: { setupFiles: ["./test/setup.ts"], testTimeout: 30_000 },
  };
});
