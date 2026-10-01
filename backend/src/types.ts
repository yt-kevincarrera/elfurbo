import type { AuthContext } from "./auth/sessions";

export type Env = {
  DB: D1Database;
  ENVIRONMENT: string;
};

export type AppEnv = {
  Bindings: Env;
  Variables: { auth: AuthContext };
};
