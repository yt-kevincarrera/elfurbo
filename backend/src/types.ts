import type { AuthContext } from "./auth/sessions";

export type Env = {
  DB: D1Database;
  ENVIRONMENT: string;
  /** Builds por debajo de este dejan de sincronizar hasta actualizar (cambios del protocolo). */
  MIN_SUPPORTED_BUILD?: string;
  /** Opcional (`wrangler secret put GITHUB_TOKEN`): sin él, GitHub limita a 60 consultas por hora e IP. */
  GITHUB_TOKEN?: string;
};

export type AppEnv = {
  Bindings: Env;
  Variables: { auth: AuthContext };
};
