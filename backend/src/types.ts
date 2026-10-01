export type Env = {
  DB: D1Database;
  ENVIRONMENT: string;
};

export type AppEnv = {
  Bindings: Env;
};
