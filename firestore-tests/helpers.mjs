import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, setDoc, Timestamp } from "firebase/firestore";

const here = dirname(fileURLToPath(import.meta.url));

export const ADMIN = "admin1";
export const PLAYER = "player1";
export const MATE = "mate1";
export const PENDING = "pending1";

export const HOUR = 60 * 60 * 1000;
export const DAY = 24 * HOUR;

/** Entorno de pruebas apuntando al emulador (host/puerto desde firebase.json). */
export async function setupEnv() {
  const env = await initializeTestEnvironment({
    projectId: "demo-elfurbo",
    firestore: {
      rules: readFileSync(join(here, "..", "firestore.rules"), "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });
  await env.clearFirestore();
  return env;
}

/** Datos base: un admin, un jugador y un compañero activos, uno pendiente. */
export async function seedUsers(env) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const user = (uid, role, status) =>
      setDoc(doc(db, "users", uid), {
        displayName: uid,
        role,
        status,
        createdAt: Timestamp.now(),
      });
    await user(ADMIN, "admin", "active");
    await user(PLAYER, "player", "active");
    await user(MATE, "player", "active");
    await user(PENDING, "player", "pending");
  });
}

/**
 * Crea una jornada. `offsetMs` es la distancia de `date` respecto a ahora
 * (negativo = ya pasó). Devuelve el id.
 */
export async function seedMatch(env, id, offsetMs, extra = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "matches", id), {
      date: Timestamp.fromMillis(Date.now() + offsetMs),
      durationMinutes: 120,
      seasonId: "s1",
      status: "scheduled",
      createdBy: ADMIN,
      ...extra,
    });
  });
  return id;
}

export async function seedSeason(env, id, extra = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "seasons", id), {
      name: id,
      startDate: Timestamp.now(),
      isActive: true,
      isClosed: false,
      ...extra,
    });
  });
}

export async function seedAttendance(env, matchId, uid, data) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "attendance", `${matchId}_${uid}`), {
      matchId,
      uid,
      ...data,
    });
  });
}

export async function seedReport(env, matchId, uid, data = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "reports", `${matchId}_${uid}`), {
      matchId,
      uid,
      goals: 1,
      assists: 0,
      confirmations: [],
      adminStatus: null,
      ...data,
    });
  });
}

export const as = (env, uid) => env.authenticatedContext(uid).firestore();

export { assertFails, assertSucceeds };
