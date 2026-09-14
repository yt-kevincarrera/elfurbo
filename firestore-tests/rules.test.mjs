import { after, before, beforeEach, describe, it } from "node:test";
import {
  arrayUnion,
  deleteDoc,
  doc,
  setDoc,
  updateDoc,
} from "firebase/firestore";
import {
  ADMIN,
  DAY,
  HOUR,
  MATE,
  PENDING,
  PLAYER,
  as,
  assertFails,
  assertSucceeds,
  seedAttendance,
  seedMatch,
  seedReport,
  seedSeason,
  seedUsers,
  setupEnv,
} from "./helpers.mjs";

let env;

before(async () => {
  env = await setupEnv();
});

after(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await seedUsers(env);
  await seedSeason(env, "s1");
});

// Jornadas de referencia (offset respecto a ahora):
const UPCOMING = 2 * DAY; // todavía no empezó
const PLAYED = -5 * HOUR; // terminó hace 3 h, sigue abierta
const CLOSED = -4 * DAY; // pasaron más de 72 h

describe("asistencia", () => {
  it("un jugador activo marca su intención antes de la jornada", async () => {
    await seedMatch(env, "m", UPCOMING);
    await assertSucceeds(
      setDoc(doc(as(env, PLAYER), "attendance", `m_${PLAYER}`), {
        matchId: "m",
        uid: PLAYER,
        status: "yes",
      })
    );
  });

  it("no puede marcar presencia antes de que termine la jornada", async () => {
    await seedMatch(env, "m", UPCOMING);
    await assertFails(
      setDoc(doc(as(env, PLAYER), "attendance", `m_${PLAYER}`), {
        matchId: "m",
        uid: PLAYER,
        status: "yes",
        played: true,
        playedSetBy: PLAYER,
      })
    );
  });

  it("después de jugarse marca presencia propia, pero no la de otro", async () => {
    await seedMatch(env, "m", PLAYED);
    await assertSucceeds(
      setDoc(doc(as(env, PLAYER), "attendance", `m_${PLAYER}`), {
        matchId: "m",
        uid: PLAYER,
        status: "maybe",
        played: true,
        playedSetBy: PLAYER,
      })
    );
    await assertFails(
      setDoc(doc(as(env, PLAYER), "attendance", `m_${MATE}`), {
        matchId: "m",
        uid: MATE,
        status: "maybe",
        played: true,
        playedSetBy: PLAYER,
      })
    );
  });

  it("después de jugarse ya no cambia la intención sola", async () => {
    await seedMatch(env, "m", PLAYED);
    await assertFails(
      setDoc(doc(as(env, PLAYER), "attendance", `m_${PLAYER}`), {
        matchId: "m",
        uid: PLAYER,
        status: "no",
      })
    );
  });

  it("el admin pasa lista de cualquiera", async () => {
    await seedMatch(env, "m", PLAYED);
    await assertSucceeds(
      setDoc(doc(as(env, ADMIN), "attendance", `m_${MATE}`), {
        matchId: "m",
        uid: MATE,
        played: true,
        playedSetBy: ADMIN,
      })
    );
  });

  it("nada se escribe en una jornada cerrada o cancelada", async () => {
    await seedMatch(env, "old", CLOSED);
    await seedMatch(env, "cancel", UPCOMING, { status: "cancelled" });
    await assertFails(
      setDoc(doc(as(env, PLAYER), "attendance", `old_${PLAYER}`), {
        matchId: "old",
        uid: PLAYER,
        status: "yes",
        played: true,
        playedSetBy: PLAYER,
      })
    );
    await assertFails(
      setDoc(doc(as(env, PLAYER), "attendance", `cancel_${PLAYER}`), {
        matchId: "cancel",
        uid: PLAYER,
        status: "yes",
      })
    );
  });

  it("una jornada reabierta por el admin vuelve a aceptar cambios", async () => {
    await seedMatch(env, "old", CLOSED, { status: "reopened" });
    await assertSucceeds(
      setDoc(doc(as(env, PLAYER), "attendance", `old_${PLAYER}`), {
        matchId: "old",
        uid: PLAYER,
        status: "yes",
        played: true,
        playedSetBy: PLAYER,
      })
    );
  });

  it("una temporada cerrada congela sus jornadas", async () => {
    await seedSeason(env, "s1", { isClosed: true, isActive: false });
    await seedMatch(env, "m", PLAYED);
    await assertFails(
      setDoc(doc(as(env, PLAYER), "attendance", `m_${PLAYER}`), {
        matchId: "m",
        uid: PLAYER,
        status: "yes",
        played: true,
        playedSetBy: PLAYER,
      })
    );
  });
});

describe("reportes", () => {
  const fresh = (uid, goals = 2) => ({
    matchId: "m",
    uid,
    goals,
    assists: 1,
    confirmations: [],
    adminStatus: null,
  });

  it("se crea después de jugarse, no antes", async () => {
    await seedMatch(env, "m", PLAYED);
    await assertSucceeds(
      setDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`), fresh(PLAYER))
    );
    await seedMatch(env, "soon", UPCOMING);
    await assertFails(
      setDoc(doc(as(env, PLAYER), "reports", `soon_${PLAYER}`), {
        ...fresh(PLAYER),
        matchId: "soon",
      })
    );
  });

  it("no se crea en una jornada cerrada", async () => {
    await seedMatch(env, "m", CLOSED);
    await assertFails(
      setDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`), fresh(PLAYER))
    );
  });

  it("goles fuera de rango se rechazan", async () => {
    await seedMatch(env, "m", PLAYED);
    await assertFails(
      setDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`), fresh(PLAYER, 31))
    );
  });

  it("el autor puede editar y borrar el suyo mientras no esté rechazado", async () => {
    await seedMatch(env, "m", PLAYED);
    await seedReport(env, "m", PLAYER, { confirmations: [MATE] });
    await assertSucceeds(
      setDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`), fresh(PLAYER, 3))
    );
    await assertSucceeds(deleteDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`)));
  });

  it("el rechazo del admin es definitivo para el autor", async () => {
    await seedMatch(env, "m", PLAYED);
    await seedReport(env, "m", PLAYER, { adminStatus: "rejected" });
    await assertFails(
      setDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`), fresh(PLAYER, 3))
    );
    await assertFails(deleteDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`)));
    // El admin sí puede quitar la decisión.
    await assertSucceeds(
      updateDoc(doc(as(env, ADMIN), "reports", `m_${PLAYER}`), {
        adminStatus: null,
      })
    );
  });

  it("solo un compañero presente confirma, y solo con su propio uid", async () => {
    await seedMatch(env, "m", PLAYED);
    await seedReport(env, "m", PLAYER);
    // Sin presencia: no.
    await assertFails(
      updateDoc(doc(as(env, MATE), "reports", `m_${PLAYER}`), {
        confirmations: arrayUnion(MATE),
      })
    );
    // Con intención "yes" pero sin presencia real: tampoco.
    await seedAttendance(env, "m", MATE, { status: "yes" });
    await assertFails(
      updateDoc(doc(as(env, MATE), "reports", `m_${PLAYER}`), {
        confirmations: arrayUnion(MATE),
      })
    );
    // Con presencia real: sí.
    await seedAttendance(env, "m", MATE, { status: "yes", played: true });
    await assertSucceeds(
      updateDoc(doc(as(env, MATE), "reports", `m_${PLAYER}`), {
        confirmations: arrayUnion(MATE),
      })
    );
    // Confirmar en nombre de otro: no.
    await assertFails(
      updateDoc(doc(as(env, MATE), "reports", `m_${PLAYER}`), {
        confirmations: arrayUnion(ADMIN),
      })
    );
  });

  it("el autor no se confirma a sí mismo", async () => {
    await seedMatch(env, "m", PLAYED);
    await seedReport(env, "m", PLAYER);
    await seedAttendance(env, "m", PLAYER, { played: true });
    await assertFails(
      updateDoc(doc(as(env, PLAYER), "reports", `m_${PLAYER}`), {
        confirmations: arrayUnion(PLAYER),
      })
    );
  });

  it("el admin corrige números de cualquiera", async () => {
    await seedMatch(env, "m", PLAYED);
    await seedReport(env, "m", PLAYER);
    await assertSucceeds(
      updateDoc(doc(as(env, ADMIN), "reports", `m_${PLAYER}`), {
        goals: 5,
        assists: 0,
        adminStatus: "confirmed",
        correctedBy: ADMIN,
      })
    );
  });
});

describe("MVP", () => {
  it("vota solo un presente, por otro presente, tras jugarse", async () => {
    await seedMatch(env, "m", PLAYED);
    const vote = (voter, votedFor) =>
      setDoc(doc(as(env, voter), "mvpVotes", `m_${voter}`), {
        matchId: "m",
        voterUid: voter,
        votedFor,
      });
    await assertFails(vote(PLAYER, MATE)); // nadie presente
    await seedAttendance(env, "m", PLAYER, { played: true });
    await assertFails(vote(PLAYER, MATE)); // el votado no está presente
    await seedAttendance(env, "m", MATE, { played: true });
    await assertSucceeds(vote(PLAYER, MATE));
    await assertFails(vote(PLAYER, PLAYER)); // a sí mismo no
  });

  it("no se vota antes de jugarse ni en jornada cerrada", async () => {
    await seedMatch(env, "soon", UPCOMING);
    await seedMatch(env, "old", CLOSED);
    for (const id of ["soon", "old"]) {
      await seedAttendance(env, id, PLAYER, { played: true });
      await seedAttendance(env, id, MATE, { played: true });
      await assertFails(
        setDoc(doc(as(env, PLAYER), "mvpVotes", `${id}_${PLAYER}`), {
          matchId: id,
          voterUid: PLAYER,
          votedFor: MATE,
        })
      );
    }
  });
});

describe("usuarios y jornadas", () => {
  it("un pendiente no lee jornadas ni cambia su rol", async () => {
    await seedMatch(env, "m", UPCOMING);
    const { getDoc } = await import("firebase/firestore");
    await assertFails(getDoc(doc(as(env, PENDING), "matches", "m")));
    await assertFails(
      updateDoc(doc(as(env, PENDING), "users", PENDING), { role: "admin" })
    );
    await assertFails(
      updateDoc(doc(as(env, PENDING), "users", PENDING), { status: "active" })
    );
  });

  it("el alta propia siempre es jugador pendiente", async () => {
    const db = env.authenticatedContext("nuevo").firestore();
    await assertFails(
      setDoc(doc(db, "users", "nuevo"), {
        displayName: "N",
        role: "admin",
        status: "active",
      })
    );
    await assertSucceeds(
      setDoc(doc(db, "users", "nuevo"), {
        displayName: "N",
        role: "player",
        status: "pending",
      })
    );
  });

  it("cada uno borra solo su propia cuenta", async () => {
    await assertFails(deleteDoc(doc(as(env, PLAYER), "users", MATE)));
    await assertSucceeds(deleteDoc(doc(as(env, PLAYER), "users", PLAYER)));
  });

  it("solo el admin crea jornadas, con estado y duración válidos", async () => {
    const match = (durationMinutes, status = "scheduled") => ({
      date: new Date(),
      durationMinutes,
      seasonId: "s1",
      status,
      createdBy: ADMIN,
    });
    await assertFails(
      setDoc(doc(as(env, PLAYER), "matches", "x"), {
        ...match(120),
        createdBy: PLAYER,
      })
    );
    await assertSucceeds(setDoc(doc(as(env, ADMIN), "matches", "a"), match(120)));
    await assertFails(setDoc(doc(as(env, ADMIN), "matches", "b"), match(10)));
    await assertFails(
      setDoc(doc(as(env, ADMIN), "matches", "c"), match(120, "played"))
    );
  });
});
