declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
  interface Env {
    DB: D1Database;
    ENVIRONMENT: string;
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }
}
