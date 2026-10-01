# PR1 · Backend base (cuentas y sesiones) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Crear `backend/`, un Cloudflare Worker con D1 que ofrece registro, login, sesiones, recuperación con código, cambio de contraseña y borrado de cuenta, probado y desplegado en `staging`.

**Architecture:** Un Worker con router Hono. Cada endpoint valida su entrada con zod y habla con D1 mediante SQL escrito a mano (sin ORM). Las sentencias que deben ir juntas se agrupan en `db.batch` (transacción). Las sesiones son tokens opacos cuyo SHA-256 se guarda en D1. Los tests corren dentro del runtime real de Workers (`@cloudflare/vitest-pool-workers`) contra un D1 local con las migraciones aplicadas.

**Tech Stack:** TypeScript 7, Hono 4, zod 4, Wrangler 4, Vitest 4 + `@cloudflare/vitest-pool-workers`, Cloudflare D1.

**Spec:** `docs/superpowers/specs/2026-10-01-servidores-backend-propio-design.md` (§1, §3, §9, §10 y §12, punto 1).

## Alcance de este PR

Entra:
- Proyecto `backend/`.
- Migración `0001_cuentas.sql` con las tablas `users`, `sessions`, `login_attempts` y `recovery_codes`.
- Endpoints: `/health`, `/auth/register`, `/auth/login`, `/auth/logout`, `/auth/recover`, `/auth/password`, `GET /me` y `DELETE /me`.
- CI y despliegue a `staging`.

Queda para PRs siguientes (no implementar aquí):
- Generar códigos de recuperación (endpoints de admin y superadmin), `clubs` en `GET /me`, anonimizar `members` y comprobar el owner al borrar la cuenta. **PR2.**
- Límite de 120 peticiones por minuto por sesión. **PR3**, junto al sync.
- Tabla `devices` y desvincular el token FCM en logout. **PR6.**
- Entorno `production`. **PR7.**

## Global Constraints

- Node 22 y **npm ≥ 11**. npm 10.8 falla al instalar vitest 4 con `Cannot read properties of null (reading 'edgesOut')`. Usa `npx -y npm@11 <comando>` si `npm --version` da 10.x.
- Versiones exactas (`--save-exact`):
  - `hono@4.13.12`, `zod@4.6.5`;
  - `wrangler@4.145.0`, `vitest@4.1.11`, `@cloudflare/vitest-pool-workers@0.22.0`;
  - `typescript@7.0.2`, `@cloudflare/workers-types@5.20261001.1`.
- `compatibility_date` = `"2026-08-15"`. El `workerd` local de esta versión solo soporta fechas hasta `2026-08-22`; una más nueva rompe los tests al arrancar.
- `backend/package.json` lleva `"type": "module"`. Sin eso, `vitest.config.ts` no carga.
- Todo mensaje visible va en español, de tú. Forma de error: `{ "error": { "code": string, "message": string, "details": unknown | null } }`.
- Fechas en ISO 8601 UTC (`new Date().toISOString()`), comparadas como texto en SQL.
- Valores del spec:
  - PBKDF2-SHA256, 100.000 iteraciones, sal de 16 bytes. Está medido: entra en el límite de CPU del plan gratuito.
  - Token de 32 bytes; en D1 solo su SHA-256.
  - Sesión de 180 días, deslizante.
  - Usuario `[a-z0-9_.]{3,20}`; contraseña de 8 caracteres o más.
  - Login bloqueado tras 10 fallos en 15 minutos.
  - Código de recuperación de un solo uso, que caduca en 24 h.
- Commits en español, como el historial del repo. **Sin ninguna atribución a IA**: ni `Co-Authored-By` de agentes ni "Generated with". Regla global del dueño.
- Trabaja en la rama `feature/backend-base`, que ya existe y contiene el commit del spec.

## Review Focus

1. **CGNAT de ETECSA.** Muchos usuarios cubanos salen por la misma IP. Los límites por IP no pueden dejar fuera a un grupo que entra a la vez. Tests: Task 3 (registro por IP) y Task 5 (15 usuarios, misma IP).
2. **Usuario escrito distinto.** `" Kevin "`, `"KEVIN"` y `"kevin"` son la misma cuenta, al registrarse y al entrar. Tests: Task 3 y Task 5.
3. **Contraseñas con tildes o ñ.** Un teclado Android puede mandar `ñ` compuesta (NFC) o descompuesta (NFD); tiene que entrar igual. Test: Task 2.
4. **Cuerpos rotos, que no son objeto o enormes.** Siempre 400/413 en JSON, nunca 500. Tests: Task 3.
5. **Presupuesto de escrituras de D1** (100k filas/día gratis). Usar una sesión no escribe en cada petición, solo una vez por hora. Test: Task 4.

---

### Task 1: Esqueleto de `backend/` con `/health`

**Files:**
- Create:
  - `backend/package.json`, `backend/package-lock.json` (lo genera npm)
  - `backend/tsconfig.json`, `backend/wrangler.jsonc`, `backend/vitest.config.ts`
  - `backend/migrations/.gitkeep`
  - `backend/src/types.ts`, `backend/src/http/errors.ts`, `backend/src/index.ts`
  - `backend/test/setup.ts`, `backend/test/env.d.ts`, `backend/test/helpers.ts`, `backend/test/health.test.ts`
- Modify: `.gitignore`

**Interfaces:**
- Produces:
  - `ApiError`, el objeto `errors`, `errorResponse(c, err)` y `handleError(err, c)` (en `src/http/errors.ts`).
  - Tipos `Env` y `AppEnv` (en `src/types.ts`).
  - El default export de `src/index.ts`, que es la app Hono.
  - En `test/helpers.ts`: `api(path, { method?, body?, token?, ip? }) → { status, headers, body }`.

- [ ] **Step 1: Crear el proyecto e instalar dependencias**

```bash
mkdir -p backend/src/http backend/test backend/migrations
touch backend/migrations/.gitkeep
cd backend
echo '{ "name": "furbo-api", "private": true, "type": "module" }' > package.json
npx -y npm@11 install --save-exact hono@4.13.12 zod@4.6.5
npx -y npm@11 install --save-exact -D wrangler@4.145.0 vitest@4.1.11 @cloudflare/vitest-pool-workers@0.22.0 typescript@7.0.2 @cloudflare/workers-types@5.20261001.1
```

npm 11 avisa de que hay scripts de instalación sin aprobar (`esbuild`, `workerd`). No hace falta aprobarlos: los tests funcionan sin ellos.

Añade los scripts a `backend/package.json`, que queda así (las versiones que puso npm se quedan como estén):

```json
{
  "name": "furbo-api",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev",
    "test": "vitest run",
    "typecheck": "tsc -p ."
  },
  "dependencies": {
    "hono": "4.13.12",
    "zod": "4.6.5"
  },
  "devDependencies": {
    "@cloudflare/vitest-pool-workers": "0.22.0",
    "@cloudflare/workers-types": "5.20261001.1",
    "typescript": "7.0.2",
    "vitest": "4.1.11",
    "wrangler": "4.145.0"
  }
}
```

- [ ] **Step 2: Configuración**

`backend/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "es2023",
    "module": "es2022",
    "moduleResolution": "bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noEmit": true,
    "skipLibCheck": true,
    "lib": ["es2023"],
    "types": ["@cloudflare/workers-types", "@cloudflare/vitest-pool-workers/types"]
  },
  "include": ["src", "test"]
}
```

`backend/wrangler.jsonc`:

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "furbo-api",
  "main": "src/index.ts",
  "compatibility_date": "2026-08-15",
  "workers_dev": true,
  "observability": { "enabled": true },
  "vars": { "ENVIRONMENT": "local" },
  // Base local para `wrangler dev` y los tests. Los entornos remotos van en "env".
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "furbo-local",
      "database_id": "00000000-0000-0000-0000-000000000000",
      "migrations_dir": "migrations"
    }
  ]
}
```

`backend/vitest.config.ts`:

```ts
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
    test: { setupFiles: ["./test/setup.ts"] },
  };
});
```

`backend/test/setup.ts`:

```ts
import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { beforeEach } from "vitest";

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

// vitest-pool-workers 0.22 aísla la base por archivo de test, pero no entre tests del mismo
// archivo: se vacía antes de cada uno.
beforeEach(async () => {
  const { results } = await env.DB.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'",
  ).all<{ name: string }>();
  if (results.length === 0) return;
  await env.DB.batch(results.map((t) => env.DB.prepare(`DELETE FROM "${t.name}"`)));
});
```

`backend/test/env.d.ts`:

```ts
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
```

Añade al final de `.gitignore` (raíz del repo):

```gitignore

# Backend (Cloudflare Worker)
/backend/node_modules/
/backend/.wrangler/
```

- [ ] **Step 3: Escribir el test que falla**

`backend/test/helpers.ts`:

```ts
import { exports } from "cloudflare:workers";

type ApiInit = { method?: string; body?: unknown; token?: string; ip?: string };

/** Llama al Worker como lo haría la app. `body` string se manda tal cual (para JSON roto). */
export async function api(path: string, init: ApiInit = {}) {
  const headers: Record<string, string> = {};
  if (init.body !== undefined) headers["content-type"] = "application/json";
  if (init.token) headers.authorization = `Bearer ${init.token}`;
  if (init.ip) headers["cf-connecting-ip"] = init.ip;
  const res = await exports.default.fetch(`https://api.test${path}`, {
    method: init.method ?? (init.body !== undefined ? "POST" : "GET"),
    headers,
    body:
      init.body === undefined ? undefined : typeof init.body === "string" ? init.body : JSON.stringify(init.body),
  });
  const text = await res.text();
  return { status: res.status, headers: res.headers, body: text ? JSON.parse(text) : null };
}
```

`backend/test/health.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { api } from "./helpers";

describe("infraestructura HTTP", () => {
  it("GET /health responde con el entorno", async () => {
    const res = await api("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true, environment: "local" });
  });

  it("una ruta desconocida da 404 en JSON", async () => {
    const res = await api("/no-existe");
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe("not_found");
  });
});
```

- [ ] **Step 4: Ver que falla**

Run: `cd backend && npx vitest run`
Expected: FAIL. No existe `src/index.ts`, así que falla al resolver el módulo principal.

- [ ] **Step 5: Implementar**

`backend/src/http/errors.ts`:

```ts
import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";

/** Error de la API con código estable (para la app) y mensaje en español (para el usuario). */
export class ApiError extends Error {
  constructor(
    readonly status: ContentfulStatusCode,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

export const errors = {
  invalidInput: (details?: unknown) => new ApiError(400, "invalid_input", "Datos no válidos", details),
  payloadTooLarge: () => new ApiError(413, "payload_too_large", "La petición es demasiado grande"),
  unauthorized: () => new ApiError(401, "unauthorized", "Inicia sesión para continuar"),
  sessionExpired: () => new ApiError(401, "session_expired", "Tu sesión caducó. Vuelve a entrar"),
  invalidCredentials: () => new ApiError(401, "invalid_credentials", "Usuario o contraseña incorrectos"),
  invalidRecoveryCode: () =>
    new ApiError(400, "invalid_recovery_code", "El código no es válido o ya caducó"),
  accountSuspended: () => new ApiError(403, "account_suspended", "Tu cuenta está suspendida"),
  usernameTaken: () => new ApiError(409, "username_taken", "Ese nombre de usuario ya existe"),
  tooManyAttempts: (retryAfterSeconds: number) =>
    new ApiError(429, "too_many_attempts", "Demasiados intentos. Espera unos minutos", {
      retryAfterSeconds,
    }),
  notFound: () => new ApiError(404, "not_found", "No encontrado"),
};

export function errorResponse(c: Context, err: ApiError) {
  if (err.code === "too_many_attempts") {
    const { retryAfterSeconds } = err.details as { retryAfterSeconds: number };
    c.header("Retry-After", String(retryAfterSeconds));
  }
  return c.json(
    { error: { code: err.code, message: err.message, details: err.details ?? null } },
    err.status,
  );
}

export function handleError(err: Error, c: Context) {
  if (err instanceof ApiError) return errorResponse(c, err);
  console.error(err);
  return c.json(
    { error: { code: "internal", message: "Error interno. Inténtalo de nuevo", details: null } },
    500,
  );
}
```

`backend/src/types.ts` (en la Task 4 se le añade `Variables`):

```ts
export type Env = {
  DB: D1Database;
  ENVIRONMENT: string;
};

export type AppEnv = {
  Bindings: Env;
};
```

`backend/src/index.ts`:

```ts
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { errorResponse, errors, handleError } from "./http/errors";
import type { AppEnv } from "./types";

const app = new Hono<AppEnv>();

app.use(bodyLimit({ maxSize: 64 * 1024, onError: (c) => errorResponse(c, errors.payloadTooLarge()) }));

app.get("/health", (c) => c.json({ ok: true, environment: c.env.ENVIRONMENT }));

app.notFound((c) => errorResponse(c, errors.notFound()));
app.onError(handleError);

export default app;
```

- [ ] **Step 6: Ver que pasa y que tipa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (2 tests) y `tsc` sin salida.

- [ ] **Step 7: Commit**

```bash
git add .gitignore backend
git commit -m "Backend: esqueleto del Worker con /health y tests en el runtime de Workers"
```

---

### Task 2: Criptografía (contraseñas, tokens, códigos)

**Files:**
- Create: `backend/src/auth/crypto.ts`
- Test: `backend/test/crypto.test.ts`

**Interfaces:**
- Produces, en `src/auth/crypto.ts`:
  - `hashPassword(password: string): Promise<string>`
  - `verifyPassword(password: string, stored: string): Promise<boolean>`
  - `DUMMY_HASH: string`
  - `randomToken(): string`
  - `sha256Hex(value: string): Promise<string>`
  - `CODE_ALPHABET: string`
  - `randomCode(length = 8): string`
  - `normalizeCode(input: string): string`

- [ ] **Step 1: Escribir el test que falla**

`backend/test/crypto.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  CODE_ALPHABET,
  DUMMY_HASH,
  hashPassword,
  normalizeCode,
  randomCode,
  randomToken,
  sha256Hex,
  verifyPassword,
} from "../src/auth/crypto";

describe("contraseñas", () => {
  it("el hash tiene el formato pbkdf2_sha256$100000$sal$hash", async () => {
    expect(await hashPassword("secreto123")).toMatch(/^pbkdf2_sha256\$100000\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$/);
  });

  it("verifica la correcta y rechaza otra", async () => {
    const stored = await hashPassword("secreto123");
    expect(await verifyPassword("secreto123", stored)).toBe(true);
    expect(await verifyPassword("secreto124", stored)).toBe(false);
  });

  it("la misma contraseña da hashes distintos (sal aleatoria)", async () => {
    expect(await hashPassword("secreto123")).not.toBe(await hashPassword("secreto123"));
  });

  it("acentos: 'contraseña' compuesta y descompuesta (NFD) son la misma", async () => {
    const stored = await hashPassword("contraseña");
    expect(await verifyPassword("contraseña".normalize("NFD"), stored)).toBe(true);
  });

  it("un hash mal formado o con iteraciones absurdas nunca verifica", async () => {
    expect(await verifyPassword("x", "basura")).toBe(false);
    expect(await verifyPassword("x", "pbkdf2_sha256$999999999$AAAA$AAAA")).toBe(false);
    expect(await verifyPassword("x", DUMMY_HASH)).toBe(false);
  });
});

describe("tokens y códigos", () => {
  it("randomToken: 43 caracteres base64url, distintos cada vez", () => {
    const a = randomToken();
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(randomToken()).not.toBe(a);
  });

  it("sha256Hex da 64 caracteres hex", async () => {
    expect(await sha256Hex("hola")).toBe("b221d9dbb083a7f33428d7c2a3c3198ae925614d70210e28716ccaa7cd4ddb79");
  });

  it("randomCode usa solo el alfabeto sin ambiguos", () => {
    for (let i = 0; i < 50; i++) {
      const code = randomCode();
      expect(code).toHaveLength(8);
      for (const ch of code) expect(CODE_ALPHABET).toContain(ch);
    }
  });

  it("normalizeCode quita espacios y guiones y pasa a mayúsculas", () => {
    expect(normalizeCode(" abcd-efgh ")).toBe("ABCDEFGH");
    expect(normalizeCode("AB CD EF GH")).toBe("ABCDEFGH");
  });
});
```

- [ ] **Step 2: Ver que falla**

Run: `cd backend && npx vitest run test/crypto.test.ts`
Expected: FAIL, no se puede resolver `../src/auth/crypto`.

- [ ] **Step 3: Implementar**

`backend/src/auth/crypto.ts`:

```ts
const ITERATIONS = 100_000;
const enc = new TextEncoder();

/** Alfabeto de códigos sin caracteres ambiguos (sin 0/O, 1/I). 32 símbolos: sin sesgo con bytes. */
export const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/**
 * Hash con formato válido que nunca coincide con nada. Se verifica contra él cuando el usuario
 * no existe, para que el tiempo de respuesta no revele qué usuarios existen.
 */
export const DUMMY_HASH = `pbkdf2_sha256$${ITERATIONS}$${"A".repeat(22)}==$${"A".repeat(43)}=`;

function toB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function fromB64(s: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(s), (ch) => ch.charCodeAt(0));
}

function toB64Url(bytes: Uint8Array): string {
  return toB64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function derive(
  password: string,
  salt: Uint8Array<ArrayBuffer>,
  iterations: number,
): Promise<Uint8Array<ArrayBuffer>> {
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(password.normalize("NFC")),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations },
    key,
    256,
  );
  return new Uint8Array(bits);
}

/** `pbkdf2_sha256$<iteraciones>$<sal b64>$<hash b64>`. El formato permite subir iteraciones luego. */
export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await derive(password, salt, ITERATIONS);
  return `pbkdf2_sha256$${ITERATIONS}$${toB64(salt)}$${toB64(hash)}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [algo, it, saltB64, hashB64] = stored.split("$");
  const iterations = Number(it);
  if (algo !== "pbkdf2_sha256" || !saltB64 || !hashB64) return false;
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > ITERATIONS) return false;
  const expected = fromB64(hashB64);
  const actual = await derive(password, fromB64(saltB64), iterations);
  return actual.byteLength === expected.byteLength && crypto.subtle.timingSafeEqual(actual, expected);
}

/** Token opaco de sesión: 32 bytes aleatorios en base64url. */
export function randomToken(): string {
  return toB64Url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(value)));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Código corto para leer en voz alta o pasar por WhatsApp (recuperación, invitaciones). */
export function randomCode(length = 8): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

/** Acepta el código como lo escriba la gente: minúsculas, espacios o guiones. */
export function normalizeCode(input: string): string {
  return input.toUpperCase().replace(/[\s-]/g, "");
}
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run test/crypto.test.ts && npx tsc -p .`
Expected: PASS (9 tests), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend/src/auth/crypto.ts backend/test/crypto.test.ts
git commit -m "Backend: hash de contraseñas PBKDF2, tokens y códigos cortos"
```

---

### Task 3: Migración de cuentas y registro

**Files:**
- Create:
  - `backend/migrations/0001_cuentas.sql`
  - `backend/src/http/validate.ts`
  - `backend/src/auth/users.ts`, `backend/src/auth/sessions.ts`, `backend/src/auth/rate-limit.ts`
  - `backend/src/auth/schemas.ts`, `backend/src/auth/routes.ts`
- Delete: `backend/migrations/.gitkeep`
- Modify: `backend/src/index.ts`, `backend/test/helpers.ts`, `backend/test/health.test.ts`
- Test: `backend/test/register.test.ts`

**Interfaces:**
- Consumes: `hashPassword`, `randomToken` y `sha256Hex` (Task 2); `errors` (Task 1).
- Produces:
  - `src/http/validate.ts`: `readJson(c, schema)` y `clientIp(c): string`.
  - `src/auth/users.ts`: tipos `UserRecord`, `PublicUser` y `UserStatus`; funciones `findUserByUsername(db, username)`, `findUserById(db, id)`, `toPublicUser(user)`, `insertUserStatement(db, user, now)` y `updatePasswordStatement(db, userId, hash, now)`.
  - `src/auth/sessions.ts`: `newSession(db, userId, deviceLabel, now) → Promise<{ token, statement }>`.
  - `src/auth/rate-limit.ts`: tipo `Limit`; `assertNotLocked(db, limits, now)`, `recordAttempt(db, limits, now)`, `clearAttempts(db, keys)` y `authLimits.{register, login, recover}`.
  - `src/auth/schemas.ts`: `registerSchema`, `loginSchema`, `recoverSchema`, `changePasswordSchema` y `confirmPasswordSchema`.
  - `src/auth/routes.ts`: `authRoutes`, una app Hono montada en `/auth`.
  - `test/helpers.ts`: `register(username?, password?, displayName?) → Promise<Registered>`.

- [ ] **Step 1: Escribir los tests que fallan**

Añade a `backend/test/helpers.ts`. El import va arriba con los demás y el resto al final del archivo:

```ts
import { expect } from "vitest";
```

```ts
export type Registered = {
  token: string;
  user: { id: string; username: string; displayName: string; isSuperadmin: boolean; status: string };
};

export async function register(username = "kevin", password = "secreto123", displayName = "Kevin") {
  const res = await api("/auth/register", { body: { username, password, displayName } });
  expect(res.status).toBe(201);
  return res.body as Registered;
}
```

Añade dentro del `describe` de `backend/test/health.test.ts`:

```ts
  it("JSON roto da 400 invalid_input, no 500", async () => {
    const res = await api("/auth/register", { body: "{esto no es json" });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe("invalid_input");
  });

  it("un cuerpo que no es un objeto da 400", async () => {
    const res = await api("/auth/register", { body: [1, 2, 3] });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe("invalid_input");
  });

  it("un cuerpo de más de 64 KB da 413", async () => {
    const res = await api("/auth/register", { body: { username: "x".repeat(70 * 1024) } });
    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe("payload_too_large");
  });
```

`backend/test/register.test.ts`. La comprobación "el token sirve en `/me`" se añade en la Task 4, cuando exista `/me`:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth/crypto";
import { api, register } from "./helpers";

describe("POST /auth/register", () => {
  it("crea la cuenta y una sesión para el token devuelto", async () => {
    const { token, user } = await register("kevin", "secreto123", "Kevin");
    expect(user).toMatchObject({ username: "kevin", displayName: "Kevin", isSuperadmin: false, status: "active" });
    const session = await env.DB.prepare("SELECT user_id FROM sessions WHERE token_hash = ?")
      .bind(await sha256Hex(token))
      .first<{ user_id: string }>();
    expect(session!.user_id).toBe(user.id);
  });

  it("guarda el hash, nunca la contraseña", async () => {
    await register("kevin", "secreto123");
    const row = await env.DB.prepare("SELECT password_hash FROM users WHERE username = 'kevin'").first<{
      password_hash: string;
    }>();
    expect(row!.password_hash).toMatch(/^pbkdf2_sha256\$/);
    expect(row!.password_hash).not.toContain("secreto123");
  });

  it("normaliza el usuario: espacios y mayúsculas no cuentan", async () => {
    const { user } = await register("  Kevin.CC ", "secreto123");
    expect(user.username).toBe("kevin.cc");
  });

  it("no deja repetir usuario, aunque cambien las mayúsculas", async () => {
    await register("kevin");
    const res = await api("/auth/register", { body: { username: "KEVIN", password: "otra-clave", displayName: "Otro" } });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe("username_taken");
  });

  it.each([
    ["ab", "muy corto"],
    ["a".repeat(21), "muy largo"],
    ["kevín", "con tilde"],
    ["kevin carrera", "con espacio"],
  ])("rechaza el usuario %s (%s) con detalle por campo", async (username) => {
    const res = await api("/auth/register", { body: { username, password: "secreto123", displayName: "K" } });
    expect(res.status).toBe(400);
    expect(res.body.error.details.username).toBeDefined();
  });

  it("exige contraseña de al menos 8 caracteres y un nombre", async () => {
    const res = await api("/auth/register", { body: { username: "kevin", password: "corta", displayName: "  " } });
    expect(res.status).toBe(400);
    expect(res.body.error.details.password).toEqual(["Mínimo 8 caracteres"]);
    expect(res.body.error.details.displayName).toEqual(["Escribe tu nombre"]);
  });

  it("como mucho 30 registros por hora desde la misma IP", async () => {
    for (let i = 0; i < 30; i++) {
      const res = await api("/auth/register", {
        body: { username: `jugador${i}`, password: "secreto123", displayName: "J" },
        ip: "152.206.0.1",
      });
      expect(res.status).toBe(201);
    }
    const res = await api("/auth/register", {
      body: { username: "jugador30", password: "secreto123", displayName: "J" },
      ip: "152.206.0.1",
    });
    expect(res.status).toBe(429);
    expect(Number(res.headers.get("retry-after"))).toBeGreaterThan(0);
    const otherIp = await api("/auth/register", {
      body: { username: "jugador30", password: "secreto123", displayName: "J" },
      ip: "152.206.0.2",
    });
    expect(otherIp.status).toBe(201);
  });
});
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run`
Expected: FAIL. Los tests de registro y los tres nuevos de `health.test.ts` dan 404, porque la ruta todavía no existe.

- [ ] **Step 3: Migración**

Borra `backend/migrations/.gitkeep` y crea `backend/migrations/0001_cuentas.sql`:

```sql
-- Cuentas, sesiones, límite de intentos y códigos de recuperación.
-- Fechas en ISO 8601 UTC (`2026-10-01T15:00:00.000Z`): se comparan como texto.

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  is_superadmin INTEGER NOT NULL DEFAULT 0 CHECK (is_superadmin IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  device_label TEXT,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX sessions_user ON sessions (user_id);

CREATE TABLE login_attempts (
  key TEXT PRIMARY KEY,
  window_start TEXT NOT NULL,
  count INTEGER NOT NULL
);

CREATE TABLE recovery_codes (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL,
  created_by TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT
);
CREATE INDEX recovery_codes_user ON recovery_codes (user_id);
```

- [ ] **Step 4: Validación de entrada**

`backend/src/http/validate.ts`:

```ts
import type { Context } from "hono";
import { z } from "zod";
import { errors } from "./errors";

/** Lee el cuerpo JSON y lo valida. Cualquier fallo es un 400 `invalid_input`, nunca un 500. */
export async function readJson<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T>> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    throw errors.invalidInput();
  }
  const parsed = schema.safeParse(body);
  if (!parsed.success) throw errors.invalidInput(z.flattenError(parsed.error).fieldErrors);
  return parsed.data;
}

/** IP del cliente según Cloudflare. En local y en tests puede faltar. */
export function clientIp(c: Context): string {
  return c.req.header("cf-connecting-ip") ?? "unknown";
}
```

`backend/src/auth/schemas.ts`:

```ts
import { z } from "zod";

/** Al registrarse: 3–20 caracteres `a-z 0-9 _ .`, sin distinguir mayúsculas ni espacios alrededor. */
export const newUsername = z
  .string()
  .trim()
  .toLowerCase()
  .regex(/^[a-z0-9_.]{3,20}$/, {
    error: "Entre 3 y 20 caracteres: letras sin tildes, números, punto o guion bajo",
  });

/** Al entrar se normaliza igual, pero sin validar el formato: uno mal escrito solo no coincide. */
export const existingUsername = z.string().trim().toLowerCase().min(1).max(40);

export const newPassword = z
  .string()
  .min(8, { error: "Mínimo 8 caracteres" })
  .max(200, { error: "Máximo 200 caracteres" });

const anyPassword = z.string().min(1).max(200);
const deviceLabel = z.string().trim().max(60).optional();

export const registerSchema = z.object({
  username: newUsername,
  password: newPassword,
  displayName: z.string().trim().min(1, { error: "Escribe tu nombre" }).max(40),
  deviceLabel,
});

export const loginSchema = z.object({
  username: existingUsername,
  password: anyPassword,
  deviceLabel,
});

export const recoverSchema = z.object({
  username: existingUsername,
  code: z.string().min(1).max(40),
  newPassword,
  deviceLabel,
});

export const changePasswordSchema = z.object({
  currentPassword: anyPassword,
  newPassword,
});

export const confirmPasswordSchema = z.object({ password: anyPassword });
```

- [ ] **Step 5: Usuarios, sesión nueva y límite de intentos**

`backend/src/auth/users.ts`:

```ts
export type UserStatus = "active" | "suspended";

export type UserRecord = {
  id: string;
  username: string;
  displayName: string;
  passwordHash: string;
  isSuperadmin: boolean;
  status: UserStatus;
};

/** Lo que la API devuelve de un usuario. Nunca incluye el hash. */
export type PublicUser = Omit<UserRecord, "passwordHash">;

type UserRow = {
  id: string;
  username: string;
  display_name: string;
  password_hash: string;
  is_superadmin: number;
  status: UserStatus;
};

const COLUMNS = "id, username, display_name, password_hash, is_superadmin, status";

function fromRow(row: UserRow): UserRecord {
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    passwordHash: row.password_hash,
    isSuperadmin: row.is_superadmin === 1,
    status: row.status,
  };
}

export function toPublicUser({ passwordHash: _, ...user }: UserRecord): PublicUser {
  return user;
}

export async function findUserByUsername(db: D1Database, username: string) {
  const row = await db
    .prepare(`SELECT ${COLUMNS} FROM users WHERE username = ?`)
    .bind(username)
    .first<UserRow>();
  return row ? fromRow(row) : null;
}

export async function findUserById(db: D1Database, id: string) {
  const row = await db.prepare(`SELECT ${COLUMNS} FROM users WHERE id = ?`).bind(id).first<UserRow>();
  return row ? fromRow(row) : null;
}

export function insertUserStatement(
  db: D1Database,
  user: { id: string; username: string; displayName: string; passwordHash: string },
  now: Date,
) {
  const at = now.toISOString();
  return db
    .prepare(
      "INSERT INTO users (id, username, display_name, password_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(user.id, user.username, user.displayName, user.passwordHash, at, at);
}

export function updatePasswordStatement(db: D1Database, userId: string, passwordHash: string, now: Date) {
  return db
    .prepare("UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?")
    .bind(passwordHash, now.toISOString(), userId);
}
```

`backend/src/auth/sessions.ts`. La Task 4 lo reemplaza por la versión completa:

```ts
import { randomToken, sha256Hex } from "./crypto";

const SESSION_DAYS = 180;
const DAY_MS = 24 * 60 * 60 * 1000;

function expiresFrom(now: Date) {
  return new Date(now.getTime() + SESSION_DAYS * DAY_MS).toISOString();
}

/** Prepara una sesión nueva. Se devuelve la sentencia para poder meterla en un `batch`. */
export async function newSession(db: D1Database, userId: string, deviceLabel: string | null, now: Date) {
  const token = randomToken();
  const at = now.toISOString();
  const statement = db
    .prepare(
      "INSERT INTO sessions (id, user_id, token_hash, device_label, created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(crypto.randomUUID(), userId, await sha256Hex(token), deviceLabel, at, at, expiresFrom(now));
  return { token, statement };
}
```

`backend/src/auth/rate-limit.ts`:

```ts
import { errors } from "../http/errors";

/** Ventana fija: como mucho `max` intentos por `key` cada `windowMinutes`. */
export type Limit = { key: string; max: number; windowMinutes: number };

const MINUTE_MS = 60 * 1000;

function windowFloor(now: Date, limit: Limit) {
  return new Date(now.getTime() - limit.windowMinutes * MINUTE_MS).toISOString();
}

/** Lanza 429 (con segundos de espera) si alguna de las claves llegó a su máximo. */
export async function assertNotLocked(db: D1Database, limits: Limit[], now: Date) {
  const rows = await db
    .prepare(
      `SELECT key, window_start, count FROM login_attempts WHERE key IN (${limits.map(() => "?").join(", ")})`,
    )
    .bind(...limits.map((l) => l.key))
    .all<{ key: string; window_start: string; count: number }>();

  let retryAfterMs = 0;
  for (const row of rows.results) {
    const limit = limits.find((l) => l.key === row.key)!;
    if (row.window_start > windowFloor(now, limit) && row.count >= limit.max) {
      const endsAt = Date.parse(row.window_start) + limit.windowMinutes * MINUTE_MS;
      retryAfterMs = Math.max(retryAfterMs, endsAt - now.getTime());
    }
  }
  if (retryAfterMs > 0) throw errors.tooManyAttempts(Math.ceil(retryAfterMs / 1000));
}

/** Suma un intento a cada clave; si su ventana ya pasó, empieza una nueva. */
export async function recordAttempt(db: D1Database, limits: Limit[], now: Date) {
  const at = now.toISOString();
  await db.batch(
    limits.map((l) =>
      db
        .prepare(
          `INSERT INTO login_attempts (key, window_start, count) VALUES (?1, ?2, 1)
           ON CONFLICT(key) DO UPDATE SET
             count = CASE WHEN window_start <= ?3 THEN 1 ELSE count + 1 END,
             window_start = CASE WHEN window_start <= ?3 THEN ?2 ELSE window_start END`,
        )
        .bind(l.key, at, windowFloor(now, l)),
    ),
  );
}

export async function clearAttempts(db: D1Database, keys: string[]) {
  await db.batch(keys.map((k) => db.prepare("DELETE FROM login_attempts WHERE key = ?").bind(k)));
}

// En Cuba mucha gente sale a internet por la misma IP (CGNAT de ETECSA): los límites por IP son
// altos a propósito, y el freno real es el límite por usuario.
export const authLimits = {
  register: (ip: string): Limit[] => [{ key: `register-ip:${ip}`, max: 30, windowMinutes: 60 }],
  login: (username: string, ip: string): Limit[] => [
    { key: `login-user:${username}`, max: 10, windowMinutes: 15 },
    { key: `login-ip:${ip}`, max: 100, windowMinutes: 15 },
  ],
  recover: (username: string, ip: string): Limit[] => [
    { key: `recover-user:${username}`, max: 5, windowMinutes: 15 },
    { key: `recover-ip:${ip}`, max: 100, windowMinutes: 15 },
  ],
};
```

Nota sobre el `UPDATE` de `recordAttempt`: en SQLite todas las expresiones del `SET` leen los valores **anteriores** de la fila. Por eso las dos ramas del `CASE` comparan la `window_start` vieja.

- [ ] **Step 6: Ruta de registro y montaje**

`backend/src/auth/routes.ts`:

```ts
import { Hono } from "hono";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { hashPassword } from "./crypto";
import { assertNotLocked, authLimits, recordAttempt } from "./rate-limit";
import { registerSchema } from "./schemas";
import { newSession } from "./sessions";
import { findUserByUsername, insertUserStatement } from "./users";

export const authRoutes = new Hono<AppEnv>();

authRoutes.post("/register", async (c) => {
  const body = await readJson(c, registerSchema);
  const db = c.env.DB;
  const now = new Date();
  const rateLimits = authLimits.register(clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  if (await findUserByUsername(db, body.username)) throw errors.usernameTaken();

  const user = {
    id: crypto.randomUUID(),
    username: body.username,
    displayName: body.displayName,
    passwordHash: await hashPassword(body.password),
  };
  const session = await newSession(db, user.id, body.deviceLabel ?? null, now);
  try {
    await db.batch([insertUserStatement(db, user, now), session.statement]);
  } catch (e) {
    // Dos registros simultáneos con el mismo nombre: gana el primero.
    if (String(e).includes("UNIQUE constraint failed: users.username")) throw errors.usernameTaken();
    throw e;
  }
  await recordAttempt(db, rateLimits, now);

  return c.json(
    {
      token: session.token,
      user: { id: user.id, username: user.username, displayName: user.displayName, isSuperadmin: false, status: "active" },
    },
    201,
  );
});
```

En `backend/src/index.ts`, añade el import y monta la ruta después de `/health`:

```ts
import { authRoutes } from "./auth/routes";
```

```ts
app.route("/auth", authRoutes);
```

- [ ] **Step 7: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 8: Commit**

```bash
git add backend
git commit -m "Backend: tablas de cuentas y registro con usuario y contraseña"
```

---

### Task 4: Sesiones, `GET /me` y logout

**Files:**
- Create: `backend/src/auth/middleware.ts`, `backend/src/me/routes.ts`
- Modify:
  - `backend/src/auth/sessions.ts` (reemplazo completo)
  - `backend/src/types.ts`, `backend/src/auth/routes.ts`, `backend/src/index.ts`
  - `backend/test/register.test.ts`
- Test: `backend/test/sessions.test.ts`, `backend/test/me.test.ts`

**Interfaces:**
- Consumes: `newSession` (Task 3); `sha256Hex` y `randomToken` (Task 2).
- Produces:
  - `src/auth/sessions.ts`:
    - `type AuthContext = { sessionId: string; user: PublicUser }`
    - `authenticate(db, token, now): Promise<AuthContext>`
    - `deleteSessionStatement(db, sessionId)`
    - `deleteUserSessionsStatement(db, userId, exceptSessionId?)`
  - `src/auth/middleware.ts`: el middleware `requireAuth`, que deja la sesión en `c.var.auth`.
  - `src/me/routes.ts`: `meRoutes`, montada en `/me`.

- [ ] **Step 1: Escribir los tests que fallan**

`backend/test/sessions.test.ts`:

```ts
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth/crypto";
import { api, register } from "./helpers";

const HOUR_MS = 60 * 60 * 1000;

describe("sesiones", () => {
  it("sin cabecera, con basura o con otro esquema: 401 unauthorized", async () => {
    expect((await api("/me")).body.error.code).toBe("unauthorized");
    expect((await api("/me", { token: "no-existe" })).status).toBe(401);
    const { token } = await register();
    const res = await exports.default.fetch("https://api.test/me", { headers: { authorization: `Basic ${token}` } });
    expect(res.status).toBe(401);
  });

  it("en la base solo está el hash del token", async () => {
    const { token } = await register();
    const row = await env.DB.prepare("SELECT token_hash FROM sessions").first<{ token_hash: string }>();
    expect(row!.token_hash).toBe(await sha256Hex(token));
  });

  it("caduca a los 180 días: 401 session_expired", async () => {
    const { token } = await register();
    await env.DB.prepare("UPDATE sessions SET expires_at = ?").bind(new Date(Date.now() - 1000).toISOString()).run();
    const res = await api("/me", { token });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("session_expired");
  });

  it("si se usa tras más de una hora, renueva last_seen y alarga la caducidad", async () => {
    const { token } = await register();
    const old = new Date(Date.now() - 2 * HOUR_MS).toISOString();
    await env.DB.prepare("UPDATE sessions SET last_seen_at = ?, expires_at = ?")
      .bind(old, new Date(Date.now() + 10 * 24 * HOUR_MS).toISOString())
      .run();
    await api("/me", { token });
    const row = await env.DB.prepare("SELECT last_seen_at, expires_at FROM sessions").first<{
      last_seen_at: string;
      expires_at: string;
    }>();
    expect(Date.parse(row!.last_seen_at)).toBeGreaterThan(Date.now() - 60_000);
    expect(Date.parse(row!.expires_at)).toBeGreaterThan(Date.now() + 179 * 24 * HOUR_MS);
  });

  it("si se usa antes de una hora, no escribe nada", async () => {
    const { token } = await register();
    const before = await env.DB.prepare("SELECT last_seen_at FROM sessions").first<{ last_seen_at: string }>();
    await api("/me", { token });
    const after = await env.DB.prepare("SELECT last_seen_at FROM sessions").first<{ last_seen_at: string }>();
    expect(after!.last_seen_at).toBe(before!.last_seen_at);
  });

  it("logout revoca solo esa sesión", async () => {
    const { token } = await register("kevin", "secreto123");
    const other = await register("raul", "secreto123");
    expect((await api("/auth/logout", { method: "POST", token })).status).toBe(204);
    expect((await api("/me", { token })).status).toBe(401);
    expect((await api("/me", { token: other.token })).status).toBe(200);
  });

  it("si suspenden la cuenta, las sesiones abiertas dan 403", async () => {
    const { token } = await register();
    await env.DB.prepare("UPDATE users SET status = 'suspended'").run();
    const res = await api("/me", { token });
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("account_suspended");
  });
});
```

En la Task 5, cuando exista login, el test de logout se reforzará con dos sesiones del mismo usuario.

`backend/test/me.test.ts`. Las Tasks 6 y 7 le añaden más `describe`:

```ts
import { describe, expect, it } from "vitest";
import { api, register } from "./helpers";

describe("/me", () => {
  it("GET devuelve el usuario y, por ahora, ningún servidor", async () => {
    const { token, user } = await register();
    const res = await api("/me", { token });
    expect(res.body).toEqual({ user, clubs: [] });
  });
});
```

En `backend/test/register.test.ts`, añade al final del primer test (`"crea la cuenta y una sesión para el token devuelto"`):

```ts
    const me = await api("/me", { token });
    expect(me.status).toBe(200);
    expect(me.body.user.id).toBe(user.id);
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run`
Expected: FAIL. `/me` y `/auth/logout` dan 404.

- [ ] **Step 3: Implementar sesiones completas**

Reemplaza `backend/src/auth/sessions.ts` entero por:

```ts
import { errors } from "../http/errors";
import { randomToken, sha256Hex } from "./crypto";
import type { PublicUser, UserStatus } from "./users";

const SESSION_DAYS = 180;
const DAY_MS = 24 * 60 * 60 * 1000;
/** Solo se reescribe `last_seen_at` si pasó más de esto: una escritura por hora, no por petición. */
const TOUCH_AFTER_MS = 60 * 60 * 1000;

export type AuthContext = { sessionId: string; user: PublicUser };

function expiresFrom(now: Date) {
  return new Date(now.getTime() + SESSION_DAYS * DAY_MS).toISOString();
}

/** Prepara una sesión nueva. Se devuelve la sentencia para poder meterla en un `batch`. */
export async function newSession(db: D1Database, userId: string, deviceLabel: string | null, now: Date) {
  const token = randomToken();
  const at = now.toISOString();
  const statement = db
    .prepare(
      "INSERT INTO sessions (id, user_id, token_hash, device_label, created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(crypto.randomUUID(), userId, await sha256Hex(token), deviceLabel, at, at, expiresFrom(now));
  return { token, statement };
}

type SessionRow = {
  session_id: string;
  last_seen_at: string;
  expires_at: string;
  id: string;
  username: string;
  display_name: string;
  is_superadmin: number;
  status: UserStatus;
};

/** Valida un token. Lanza 401 si no existe o caducó, 403 si la cuenta está suspendida. */
export async function authenticate(db: D1Database, token: string, now: Date): Promise<AuthContext> {
  const row = await db
    .prepare(
      `SELECT s.id AS session_id, s.last_seen_at, s.expires_at,
              u.id, u.username, u.display_name, u.is_superadmin, u.status
         FROM sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = ?`,
    )
    .bind(await sha256Hex(token))
    .first<SessionRow>();
  if (!row) throw errors.unauthorized();
  if (row.expires_at <= now.toISOString()) throw errors.sessionExpired();
  if (row.status === "suspended") throw errors.accountSuspended();

  if (now.getTime() - Date.parse(row.last_seen_at) > TOUCH_AFTER_MS) {
    await db
      .prepare("UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?")
      .bind(now.toISOString(), expiresFrom(now), row.session_id)
      .run();
  }

  return {
    sessionId: row.session_id,
    user: {
      id: row.id,
      username: row.username,
      displayName: row.display_name,
      isSuperadmin: row.is_superadmin === 1,
      status: row.status,
    },
  };
}

export function deleteSessionStatement(db: D1Database, sessionId: string) {
  return db.prepare("DELETE FROM sessions WHERE id = ?").bind(sessionId);
}

/** Borra todas las sesiones del usuario salvo, opcionalmente, una. */
export function deleteUserSessionsStatement(db: D1Database, userId: string, exceptSessionId?: string) {
  return exceptSessionId
    ? db.prepare("DELETE FROM sessions WHERE user_id = ? AND id <> ?").bind(userId, exceptSessionId)
    : db.prepare("DELETE FROM sessions WHERE user_id = ?").bind(userId);
}
```

Reemplaza `backend/src/types.ts` por:

```ts
import type { AuthContext } from "./auth/sessions";

export type Env = {
  DB: D1Database;
  ENVIRONMENT: string;
};

export type AppEnv = {
  Bindings: Env;
  Variables: { auth: AuthContext };
};
```

`backend/src/auth/middleware.ts`:

```ts
import { createMiddleware } from "hono/factory";
import { errors } from "../http/errors";
import type { AppEnv } from "../types";
import { authenticate } from "./sessions";

/** Exige `Authorization: Bearer <token>` válido y deja la sesión en `c.var.auth`. */
export const requireAuth = createMiddleware<AppEnv>(async (c, next) => {
  const match = /^Bearer\s+(\S+)$/i.exec(c.req.header("authorization") ?? "");
  if (!match) throw errors.unauthorized();
  c.set("auth", await authenticate(c.env.DB, match[1]!, new Date()));
  await next();
});
```

`backend/src/me/routes.ts`:

```ts
import { Hono } from "hono";
import { requireAuth } from "../auth/middleware";
import type { AppEnv } from "../types";

export const meRoutes = new Hono<AppEnv>();

meRoutes.use(requireAuth);

// `clubs` se rellena en el PR2 (servidores). Hasta entonces, siempre vacío.
meRoutes.get("/", (c) => c.json({ user: c.var.auth.user, clubs: [] }));
```

En `backend/src/auth/routes.ts`, añade estos imports (y amplía el de `./sessions`):

```ts
import { requireAuth } from "./middleware";
import { deleteSessionStatement, newSession } from "./sessions";
```

Añade al final:

```ts
authRoutes.post("/logout", requireAuth, async (c) => {
  await deleteSessionStatement(c.env.DB, c.var.auth.sessionId).run();
  return c.body(null, 204);
});
```

En `backend/src/index.ts`, añade el import y monta la ruta después de `/auth`:

```ts
import { meRoutes } from "./me/routes";
```

```ts
app.route("/me", meRoutes);
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: sesiones con token opaco, GET /me y cerrar sesión"
```

---

### Task 5: Login con bloqueo por intentos

**Files:**
- Modify: `backend/src/auth/routes.ts`, `backend/test/helpers.ts`, `backend/test/sessions.test.ts`
- Test: `backend/test/login.test.ts`

**Interfaces:**
- Consumes:
  - `verifyPassword` y `DUMMY_HASH` (Task 2);
  - `assertNotLocked`, `recordAttempt`, `clearAttempts`, `authLimits.login` y `loginSchema` (Task 3);
  - `findUserByUsername` y `toPublicUser` (Task 3);
  - `newSession` (Task 4).
- Produces:
  - `POST /auth/login` → `{ token, user }`.
  - `test/helpers.ts`: `login(username, password, ip?)`.

- [ ] **Step 1: Escribir los tests que fallan**

Añade a `backend/test/helpers.ts`:

```ts
export async function login(username: string, password: string, ip?: string) {
  return api("/auth/login", { body: { username, password }, ip });
}
```

`backend/test/login.test.ts`:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, login, register } from "./helpers";

describe("POST /auth/login", () => {
  it("entra con usuario y contraseña, sin importar mayúsculas ni espacios en el usuario", async () => {
    const { user } = await register("kevin", "secreto123");
    const res = await login(" KEVIN ", "secreto123");
    expect(res.status).toBe(200);
    expect(res.body.user).toEqual(user);
    expect((await api("/me", { token: res.body.token })).status).toBe(200);
  });

  it("contraseña mala y usuario inexistente dan el mismo error", async () => {
    await register("kevin", "secreto123");
    const wrong = await login("kevin", "otra-cosa");
    const unknown = await login("nadie", "otra-cosa");
    expect(wrong.status).toBe(401);
    expect(unknown.status).toBe(401);
    expect(wrong.body).toEqual(unknown.body);
    expect(wrong.body.error.code).toBe("invalid_credentials");
  });

  it("tras 10 fallos bloquea ese usuario 15 minutos, aunque luego acierte", async () => {
    await register("kevin", "secreto123");
    for (let i = 0; i < 10; i++) expect((await login("kevin", "mala")).status).toBe(401);
    const res = await login("kevin", "secreto123");
    expect(res.status).toBe(429);
    expect(res.body.error.code).toBe("too_many_attempts");
    const retryAfter = Number(res.headers.get("retry-after"));
    expect(retryAfter).toBeGreaterThan(14 * 60);
    expect(retryAfter).toBeLessThanOrEqual(15 * 60);
  });

  it("pasada la ventana de 15 minutos vuelve a dejar entrar", async () => {
    await register("kevin", "secreto123");
    for (let i = 0; i < 10; i++) await login("kevin", "mala");
    const old = new Date(Date.now() - 16 * 60 * 1000).toISOString();
    await env.DB.prepare("UPDATE login_attempts SET window_start = ?").bind(old).run();
    expect((await login("kevin", "secreto123")).status).toBe(200);
  });

  it("un acierto pone a cero el contador del usuario", async () => {
    await register("kevin", "secreto123");
    for (let i = 0; i < 9; i++) await login("kevin", "mala");
    expect((await login("kevin", "secreto123")).status).toBe(200);
    for (let i = 0; i < 9; i++) await login("kevin", "mala");
    expect((await login("kevin", "secreto123")).status).toBe(200);
  });

  it("CGNAT: 15 personas en la misma IP, cada una con un fallo, entran todas", async () => {
    for (let i = 0; i < 15; i++) await register(`jugador${i}`, "secreto123");
    for (let i = 0; i < 15; i++) {
      expect((await login(`jugador${i}`, "mala", "152.206.0.1")).status).toBe(401);
      expect((await login(`jugador${i}`, "secreto123", "152.206.0.1")).status).toBe(200);
    }
  });

  it("una cuenta suspendida no puede entrar", async () => {
    await register("kevin", "secreto123");
    await env.DB.prepare("UPDATE users SET status = 'suspended'").run();
    const res = await login("kevin", "secreto123");
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("account_suspended");
  });
});
```

En `backend/test/sessions.test.ts`, cambia el import de helpers a `import { api, login, register } from "./helpers";`. Luego reemplaza el test `"logout revoca solo esa sesión"` por:

```ts
  it("logout revoca solo esa sesión", async () => {
    const { token } = await register("kevin", "secreto123");
    const other = (await login("kevin", "secreto123")).body.token;
    expect((await api("/auth/logout", { method: "POST", token })).status).toBe(204);
    expect((await api("/me", { token })).status).toBe(401);
    expect((await api("/me", { token: other })).status).toBe(200);
  });
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/login.test.ts test/sessions.test.ts`
Expected: FAIL. `/auth/login` da 404.

- [ ] **Step 3: Implementar**

En `backend/src/auth/routes.ts`, deja los imports así:

```ts
import { Hono } from "hono";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { DUMMY_HASH, hashPassword, verifyPassword } from "./crypto";
import { requireAuth } from "./middleware";
import { assertNotLocked, authLimits, clearAttempts, recordAttempt } from "./rate-limit";
import { loginSchema, registerSchema } from "./schemas";
import { deleteSessionStatement, newSession } from "./sessions";
import { findUserByUsername, insertUserStatement, toPublicUser } from "./users";
```

Añade, entre `/register` y `/logout`:

```ts
authRoutes.post("/login", async (c) => {
  const body = await readJson(c, loginSchema);
  const db = c.env.DB;
  const now = new Date();
  const rateLimits = authLimits.login(body.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = await findUserByUsername(db, body.username);
  const ok = await verifyPassword(body.password, user?.passwordHash ?? DUMMY_HASH);
  if (!user || !ok) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  if (user.status === "suspended") throw errors.accountSuspended();

  await clearAttempts(db, [rateLimits[0]!.key]);
  const session = await newSession(db, user.id, body.deviceLabel ?? null, now);
  await session.statement.run();
  return c.json({ token: session.token, user: toPublicUser(user) });
});
```

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: login con bloqueo tras 10 fallos y límites por IP pensados para CGNAT"
```

---

### Task 6: Recuperación con código y cambio de contraseña

**Files:**
- Modify: `backend/src/auth/routes.ts`, `backend/test/helpers.ts`, `backend/test/me.test.ts`
- Test: `backend/test/recover.test.ts`

**Interfaces:**
- Consumes:
  - `normalizeCode`, `sha256Hex` y `hashPassword` (Task 2);
  - `recoverSchema`, `changePasswordSchema`, `authLimits.recover`, `authLimits.login`, `findUserById` y `updatePasswordStatement` (Task 3);
  - `deleteUserSessionsStatement` y `requireAuth` (Task 4).
- Produces:
  - `POST /auth/recover` → `{ token, user }`.
  - `POST /auth/password` → 204.
  - `test/helpers.ts`: `insertRecoveryCode(userId, code, { expiresAt?, usedAt? })`. El PR2 añadirá los endpoints que generan los códigos de verdad.

- [ ] **Step 1: Escribir los tests que fallan**

Añade a `backend/test/helpers.ts`. Los imports van arriba y la función al final:

```ts
import { env } from "cloudflare:workers";
import { normalizeCode, sha256Hex } from "../src/auth/crypto";
```

El import de `cloudflare:workers` que ya existe se convierte en `import { env, exports } from "cloudflare:workers";`.

```ts
/** Inserta un código de recuperación como lo hará el PR2 (admin o superadmin). */
export async function insertRecoveryCode(
  userId: string,
  code: string,
  opts: { expiresAt?: string; usedAt?: string } = {},
) {
  await env.DB.prepare(
    "INSERT INTO recovery_codes (id, user_id, code_hash, created_by, expires_at, used_at) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(
      crypto.randomUUID(),
      userId,
      await sha256Hex(normalizeCode(code)),
      "superadmin-de-prueba",
      opts.expiresAt ?? new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      opts.usedAt ?? null,
    )
    .run();
}
```

`backend/test/recover.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { api, insertRecoveryCode, login, register } from "./helpers";

function recover(username: string, code: string, newPassword = "nueva-clave") {
  return api("/auth/recover", { body: { username, code, newPassword } });
}

describe("POST /auth/recover", () => {
  it("con un código válido cambia la contraseña, entra y cierra las demás sesiones", async () => {
    const { token: oldToken, user } = await register("kevin", "secreto123");
    await insertRecoveryCode(user.id, "ABCDEFGH");

    const res = await recover("kevin", "ABCDEFGH");
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(user.id);
    expect((await api("/me", { token: res.body.token })).status).toBe(200);
    expect((await api("/me", { token: oldToken })).status).toBe(401);
    expect((await login("kevin", "secreto123")).status).toBe(401);
    expect((await login("kevin", "nueva-clave")).status).toBe(200);
  });

  it("acepta el código en minúsculas, con espacios o guiones", async () => {
    const { user } = await register("kevin");
    await insertRecoveryCode(user.id, "ABCDEFGH");
    expect((await recover("kevin", " abcd-efgh ")).status).toBe(200);
  });

  it("el código sirve una sola vez", async () => {
    const { user } = await register("kevin");
    await insertRecoveryCode(user.id, "ABCDEFGH");
    expect((await recover("kevin", "ABCDEFGH")).status).toBe(200);
    const again = await recover("kevin", "ABCDEFGH", "otra-clave-mas");
    expect(again.status).toBe(400);
    expect(again.body.error.code).toBe("invalid_recovery_code");
  });

  it("un código caducado o ya usado no vale", async () => {
    const { user } = await register("kevin");
    await insertRecoveryCode(user.id, "CADUCADO", { expiresAt: new Date(Date.now() - 1000).toISOString() });
    await insertRecoveryCode(user.id, "YAUSADO2", { usedAt: new Date().toISOString() });
    expect((await recover("kevin", "CADUCADO")).body.error.code).toBe("invalid_recovery_code");
    expect((await recover("kevin", "YAUSADO2")).body.error.code).toBe("invalid_recovery_code");
  });

  it("el código de otro usuario no vale", async () => {
    const { user: kevin } = await register("kevin");
    await register("raul");
    await insertRecoveryCode(kevin.id, "ABCDEFGH");
    expect((await recover("raul", "ABCDEFGH")).status).toBe(400);
  });

  it("usuario inexistente: mismo error que código malo", async () => {
    const res = await recover("nadie", "ABCDEFGH");
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe("invalid_recovery_code");
  });

  it("tras 5 códigos malos se bloquea, aunque el sexto sea bueno", async () => {
    const { user } = await register("kevin");
    await insertRecoveryCode(user.id, "ABCDEFGH");
    for (let i = 0; i < 5; i++) expect((await recover("kevin", "MALO0000")).status).toBe(400);
    expect((await recover("kevin", "ABCDEFGH")).status).toBe(429);
  });

  it("exige que la contraseña nueva tenga 8 caracteres", async () => {
    const { user } = await register("kevin");
    await insertRecoveryCode(user.id, "ABCDEFGH");
    const res = await recover("kevin", "ABCDEFGH", "corta");
    expect(res.status).toBe(400);
    expect(res.body.error.details.newPassword).toBeDefined();
  });
});
```

En `backend/test/me.test.ts`, cambia el import de helpers a `import { api, login, register } from "./helpers";`. Añade, antes del `describe("/me", ...)`:

```ts
describe("POST /auth/password", () => {
  it("cambia la contraseña y cierra las demás sesiones, no la actual", async () => {
    const { token } = await register("kevin", "secreto123");
    const other = (await login("kevin", "secreto123")).body.token;

    const res = await api("/auth/password", {
      token,
      body: { currentPassword: "secreto123", newPassword: "nueva-clave" },
    });
    expect(res.status).toBe(204);
    expect((await api("/me", { token })).status).toBe(200);
    expect((await api("/me", { token: other })).status).toBe(401);
    expect((await login("kevin", "nueva-clave")).status).toBe(200);
  });

  it("con la contraseña actual mal: 401 y no cambia nada", async () => {
    const { token } = await register("kevin", "secreto123");
    const res = await api("/auth/password", { token, body: { currentPassword: "mala", newPassword: "nueva-clave" } });
    expect(res.status).toBe(401);
    expect((await login("kevin", "secreto123")).status).toBe(200);
  });

  it("sin sesión: 401", async () => {
    const res = await api("/auth/password", { body: { currentPassword: "a", newPassword: "nueva-clave" } });
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/recover.test.ts test/me.test.ts`
Expected: FAIL. `/auth/recover` y `/auth/password` dan 404.

- [ ] **Step 3: Implementar**

En `backend/src/auth/routes.ts`, deja los imports así:

```ts
import { Hono } from "hono";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";
import { DUMMY_HASH, hashPassword, normalizeCode, sha256Hex, verifyPassword } from "./crypto";
import { requireAuth } from "./middleware";
import { assertNotLocked, authLimits, clearAttempts, recordAttempt } from "./rate-limit";
import { changePasswordSchema, loginSchema, recoverSchema, registerSchema } from "./schemas";
import { deleteSessionStatement, deleteUserSessionsStatement, newSession } from "./sessions";
import {
  findUserById,
  findUserByUsername,
  insertUserStatement,
  toPublicUser,
  updatePasswordStatement,
} from "./users";
```

Añade al final:

```ts
authRoutes.post("/recover", async (c) => {
  const body = await readJson(c, recoverSchema);
  const db = c.env.DB;
  const now = new Date();
  const rateLimits = authLimits.recover(body.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = await findUserByUsername(db, body.username);
  const code = user
    ? await db
        .prepare(
          "SELECT id FROM recovery_codes WHERE user_id = ? AND code_hash = ? AND used_at IS NULL AND expires_at > ?",
        )
        .bind(user.id, await sha256Hex(normalizeCode(body.code)), now.toISOString())
        .first<{ id: string }>()
    : null;
  if (!user || !code) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidRecoveryCode();
  }
  if (user.status === "suspended") throw errors.accountSuspended();

  const session = await newSession(db, user.id, body.deviceLabel ?? null, now);
  await db.batch([
    db.prepare("UPDATE recovery_codes SET used_at = ? WHERE id = ?").bind(now.toISOString(), code.id),
    updatePasswordStatement(db, user.id, await hashPassword(body.newPassword), now),
    deleteUserSessionsStatement(db, user.id),
    session.statement,
  ]);
  await clearAttempts(db, [rateLimits[0]!.key]);
  return c.json({ token: session.token, user: toPublicUser(user) });
});

authRoutes.post("/password", requireAuth, async (c) => {
  const body = await readJson(c, changePasswordSchema);
  const db = c.env.DB;
  const now = new Date();
  const { user: authUser, sessionId } = c.var.auth;
  const rateLimits = authLimits.login(authUser.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = (await findUserById(db, authUser.id))!;
  if (!(await verifyPassword(body.currentPassword, user.passwordHash))) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  await db.batch([
    updatePasswordStatement(db, user.id, await hashPassword(body.newPassword), now),
    deleteUserSessionsStatement(db, user.id, sessionId),
  ]);
  return c.body(null, 204);
});
```

Orden del `batch` de `/recover`: primero se borran **todas** las sesiones y después se inserta la nueva. Si se invierte, la sesión recién creada se borra también.

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (todos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: recuperar la cuenta con código de un solo uso y cambiar la contraseña"
```

---

### Task 7: Borrar la cuenta

**Files:**
- Modify: `backend/src/me/routes.ts`, `backend/test/me.test.ts`

**Interfaces:**
- Consumes:
  - `verifyPassword` (Task 2);
  - `assertNotLocked`, `recordAttempt`, `authLimits.login`, `confirmPasswordSchema` y `findUserById` (Task 3);
  - `deleteUserSessionsStatement` y `requireAuth` (Task 4).
- Produces: `DELETE /me` (cuerpo `{ password }`) → 204. El PR2 lo amplía: anonimizar `members` y comprobar que no sea owner.

- [ ] **Step 1: Escribir los tests que fallan**

En `backend/test/me.test.ts`, deja los imports así:

```ts
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, insertRecoveryCode, login, register } from "./helpers";
```

Añade dentro de `describe("/me", ...)`:

```ts
  it("DELETE con la contraseña mal: 401 y la cuenta sigue", async () => {
    const { token } = await register("kevin", "secreto123");
    const res = await api("/me", { method: "DELETE", token, body: { password: "mala" } });
    expect(res.status).toBe(401);
    expect((await api("/me", { token })).status).toBe(200);
  });

  it("DELETE borra la cuenta, sus sesiones y sus códigos, y libera el nombre", async () => {
    const { token, user } = await register("kevin", "secreto123");
    await login("kevin", "secreto123");
    await insertRecoveryCode(user.id, "ABCDEFGH");

    const res = await api("/me", { method: "DELETE", token, body: { password: "secreto123" } });
    expect(res.status).toBe(204);
    expect((await api("/me", { token })).status).toBe(401);
    for (const table of ["users", "sessions", "recovery_codes"]) {
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
      expect(row!.n, table).toBe(0);
    }
    await register("kevin", "otra-clave-1");
  });
```

- [ ] **Step 2: Ver que fallan**

Run: `cd backend && npx vitest run test/me.test.ts`
Expected: FAIL. `DELETE /me` da 404, porque `meRoutes` solo tiene el `GET`.

- [ ] **Step 3: Implementar**

Reemplaza `backend/src/me/routes.ts` por:

```ts
import { Hono } from "hono";
import { verifyPassword } from "../auth/crypto";
import { requireAuth } from "../auth/middleware";
import { assertNotLocked, authLimits, recordAttempt } from "../auth/rate-limit";
import { confirmPasswordSchema } from "../auth/schemas";
import { deleteUserSessionsStatement } from "../auth/sessions";
import { findUserById } from "../auth/users";
import { errors } from "../http/errors";
import { clientIp, readJson } from "../http/validate";
import type { AppEnv } from "../types";

export const meRoutes = new Hono<AppEnv>();

meRoutes.use(requireAuth);

// `clubs` se rellena en el PR2 (servidores). Hasta entonces, siempre vacío.
meRoutes.get("/", (c) => c.json({ user: c.var.auth.user, clubs: [] }));

meRoutes.delete("/", async (c) => {
  const body = await readJson(c, confirmPasswordSchema);
  const db = c.env.DB;
  const now = new Date();
  const userId = c.var.auth.user.id;
  const rateLimits = authLimits.login(c.var.auth.user.username, clientIp(c));
  await assertNotLocked(db, rateLimits, now);

  const user = (await findUserById(db, userId))!;
  if (!(await verifyPassword(body.password, user.passwordHash))) {
    await recordAttempt(db, rateLimits, now);
    throw errors.invalidCredentials();
  }
  await db.batch([
    deleteUserSessionsStatement(db, userId),
    db.prepare("DELETE FROM recovery_codes WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ]);
  return c.body(null, 204);
});
```

Se borran las tablas hijas explícitamente y antes que `users`, para no depender de que D1 aplique `ON DELETE CASCADE`.

- [ ] **Step 4: Ver que pasa**

Run: `cd backend && npx vitest run && npx tsc -p .`
Expected: PASS (52 tests en 7 archivos), `tsc` limpio.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "Backend: borrar la propia cuenta confirmando la contraseña"
```

---

### Task 8: CI, despliegue a staging y README

**Files:**
- Modify: `backend/wrangler.jsonc`, `backend/package.json`, `.github/workflows/ci.yml`, `README.md`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces:
  - El Worker `furbo-api-staging` en `https://furbo-api-staging.<subdominio>.workers.dev`, con la base D1 `furbo-staging`.
  - Los jobs de CI `backend` y `deploy-staging`.

**Antes de empezar (lo hace el dueño, no el agente):**
- *(Opcional)* Cambiar el subdominio de `workers.dev` de la cuenta, que hoy es `furbo-probe` porque salió del Worker de prueba, a algo como `elfurbo`. Se hace en el panel de Cloudflare: Workers & Pages → Account details → Subdomain. Es un ajuste de la cuenta: el agente **no** lo cambia. Si no se cambia, todo funciona igual con `furbo-probe`.
- Para que el CI pueda desplegar:
  1. Crear un API token en Cloudflare: My Profile → API Tokens → plantilla "Edit Cloudflare Workers", añadiendo el permiso **D1: Edit**.
  2. Guardarlo en GitHub como secreto `CLOUDFLARE_API_TOKEN`.
  3. Guardar el Account ID como secreto `CLOUDFLARE_ACCOUNT_ID`.

  Mientras falten, el job de despliegue se salta con un aviso.

- [ ] **Step 1: Crear la base de staging**

```bash
cd backend && npx wrangler whoami && npx wrangler d1 create furbo-staging
```

Expected: `✅ Successfully created DB 'furbo-staging'` y un `database_id`. Si `whoami` dice que no hay sesión, ejecuta `npx wrangler login` y que el dueño autorice en el navegador.

- [ ] **Step 2: Entorno `staging` en Wrangler y scripts**

En `backend/wrangler.jsonc`, añade al final del objeto raíz, después de `d1_databases`, este bloque `env`. Pon el `database_id` que imprimió el paso anterior:

```jsonc
  "env": {
    "staging": {
      "name": "furbo-api-staging",
      "vars": { "ENVIRONMENT": "staging" },
      "d1_databases": [
        {
          "binding": "DB",
          "database_name": "furbo-staging",
          "database_id": "PEGAR-AQUÍ-EL-ID-DE-furbo-staging",
          "migrations_dir": "migrations"
        }
      ]
    }
  }
```

El texto `PEGAR-AQUÍ-EL-ID-DE-furbo-staging` no puede llegar al commit. Comprueba con `grep -c PEGAR backend/wrangler.jsonc`: tiene que dar `0`.

En `backend/package.json`, deja `scripts` así:

```json
  "scripts": {
    "dev": "wrangler dev",
    "test": "vitest run",
    "typecheck": "tsc -p .",
    "db:migrate:local": "wrangler d1 migrations apply DB --local",
    "db:migrate:staging": "wrangler d1 migrations apply DB --remote --env staging",
    "deploy:staging": "npm run db:migrate:staging && wrangler deploy --env staging"
  },
```

- [ ] **Step 3: Desplegar y probar staging de punta a punta**

```bash
cd backend && npm run deploy:staging
```

Expected: se aplica `0001_cuentas.sql` y la salida termina con `https://furbo-api-staging.<subdominio>.workers.dev`. Luego, con esa URL en `$URL`:

```bash
curl -s "$URL/health"
```

Expected: `{"ok":true,"environment":"staging"}`. Si da error de DNS, espera un minuto y repite: el primer despliegue tarda en propagarse.

```bash
TOKEN=$(curl -s -X POST "$URL/auth/register" -H 'content-type: application/json' -d '{"username":"prueba.ci","password":"secreto123","displayName":"Prueba"}' | node -pe 'JSON.parse(require("fs").readFileSync(0)).token')
curl -s "$URL/me" -H "authorization: Bearer $TOKEN"
curl -s -o /dev/null -w "%{http_code}\n" -X DELETE "$URL/me" -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{"password":"secreto123"}'
```

Expected:
- `/me` devuelve `{"user":{...,"username":"prueba.ci",...},"clubs":[]}`.
- El `DELETE` imprime `204`, y la cuenta de prueba no queda en staging.

- [ ] **Step 4: CI**

En `.github/workflows/ci.yml`, añade al final de `jobs:`, con la misma indentación que `functions:`:

```yaml
  backend:
    name: Backend · tipos y tests
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: backend/package-lock.json
      # npm 10 falla al resolver las dependencias peer de vitest 4.
      - run: npm install -g npm@11
      - run: npm ci
      - run: npm run typecheck
      - run: npm test

  deploy-staging:
    name: Backend · desplegar a staging
    needs: backend
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    env:
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: backend/package-lock.json
      - run: npm install -g npm@11
      - run: npm ci
      - name: ¿Hay credenciales de Cloudflare?
        id: creds
        run: |
          if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
            echo "::warning::Falta el secreto CLOUDFLARE_API_TOKEN: no se despliega a staging."
            echo "skip=true" >> "$GITHUB_OUTPUT"
          fi
      - if: steps.creds.outputs.skip != 'true'
        run: npm run deploy:staging
```

Revisa que `backend:` y `deploy-staging:` tengan exactamente la misma indentación (2 espacios) que `functions:`. GitHub valida el archivo al hacer push y marca el workflow como inválido si no.

- [ ] **Step 5: README**

En `README.md`, añade antes de `## Tests y CI` la sección siguiente. Pon la URL real de staging del Step 3:

````markdown
## Backend propio (Cloudflare Workers + D1)

La versión 1.0 deja Firebase Auth y Firestore (bloqueados en Cuba sin VPN) por un backend
propio en `backend/`: un Cloudflare Worker con base D1, en el plan gratuito. Se probó desde
ETECSA sin VPN el 2026-10-01. Diseño completo:
`docs/superpowers/specs/2026-10-01-servidores-backend-propio-design.md`.

Requisitos: Node 22 y **npm 11** (con npm 10 falla la instalación: `npm install -g npm@11`).

```bash
cd backend
npm ci
npm test               # tests dentro del runtime de Workers, con D1 local
npm run typecheck
npm run dev            # API local en http://localhost:8787 (antes: npm run db:migrate:local)
npm run deploy:staging # migraciones + despliegue a staging (requiere `npx wrangler login`)
```

- Staging: `https://furbo-api-staging.<subdominio>.workers.dev`. El CI despliega solo en cada push a
  `main` si existen los secretos `CLOUDFLARE_API_TOKEN` y `CLOUDFLARE_ACCOUNT_ID`.
- Marcar a alguien como superadmin (no se puede desde la API, a propósito):

  ```bash
  cd backend && npx wrangler d1 execute DB --remote --env staging --command "UPDATE users SET is_superadmin = 1 WHERE username = 'kevin'"
  ```

- Copias de seguridad: D1 Time Travel permite volver a cualquier minuto de los últimos 7 días
  (`npx wrangler d1 time-travel restore DB --env staging --timestamp=<ISO>`). Export manual:
  `npx wrangler d1 export DB --remote --env staging --output=backup.sql`.
````

- [ ] **Step 6: Comprobación final**

```bash
cd backend && npm ci && npm run typecheck && npm test && cd .. && git status --short
```

Expected:
- `typecheck` limpio y `52 passed`.
- `git status` muestra solo `.github/workflows/ci.yml`, `README.md`, `backend/package.json` y `backend/wrangler.jsonc`. No debe aparecer `.wrangler/` ni `node_modules/`.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yml README.md backend/package.json backend/wrangler.jsonc
git commit -m "Backend: entorno staging, job de CI y despliegue automático a staging"
```
