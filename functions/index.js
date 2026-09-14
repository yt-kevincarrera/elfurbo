/**
 * Cloud Functions de El Furbo.
 *
 * - onUserCreated:       el primer usuario que entra queda como admin activo;
 *                        para los siguientes, avisa a los admins que hay alguien pendiente.
 * - onReportCreated:     avisa a los que jugaron ese día que hay un reporte para confirmar.
 * - onReportUpdated:     avisa al autor cuando su reporte queda confirmado o rechazado.
 * - matchDayReminder:    todos los días a las 09:00 avisa si hoy hay jornada (marcar asistencia).
 * - postMatchReminder:   todos los días a las 22:00 recuerda cargar goles y votar MVP.
 *
 * IMPORTANTE: REGION debe coincidir con la región de tu base de Firestore
 * (o ser us-central1 si elegiste una multi-región como nam5).
 */
const { setGlobalOptions } = require("firebase-functions/v2");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();
const messaging = admin.messaging();

const REGION = "us-central1";
const TIME_ZONE = "America/Havana";

setGlobalOptions({ region: REGION, maxInstances: 5 });

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Estado efectivo de un reporte: decisión del admin o 2 confirmaciones de compañeros. */
function derivedStatus(report) {
  if (report.adminStatus === "confirmed" || report.adminStatus === "rejected") {
    return report.adminStatus;
  }
  const confirmations = Array.isArray(report.confirmations) ? report.confirmations : [];
  return confirmations.length >= 2 ? "confirmed" : "pending";
}

function playerName(user) {
  if (!user) return "Alguien";
  return user.nickname || user.displayName || "Alguien";
}

function plural(n, singular, pluralForm) {
  return `${n} ${n === 1 ? singular : pluralForm}`;
}

async function getUser(uid) {
  const snap = await db.collection("users").doc(uid).get();
  return snap.exists ? { uid, ...snap.data() } : null;
}

async function activeUserIds() {
  const snap = await db.collection("users").where("status", "==", "active").get();
  return snap.docs.map((d) => d.id);
}

async function adminUserIds() {
  const snap = await db
    .collection("users")
    .where("status", "==", "active")
    .where("role", "==", "admin")
    .get();
  return snap.docs.map((d) => d.id);
}

/** Jugadores con presencia real confirmada en la jornada. */
async function attendeesPresent(matchId) {
  const snap = await db
    .collection("attendance")
    .where("matchId", "==", matchId)
    .where("played", "==", true)
    .get();
  return snap.docs.map((d) => d.data().uid);
}

/** Jugadores que dijeron que no iban. */
async function intendedNo(matchId) {
  const snap = await db
    .collection("attendance")
    .where("matchId", "==", matchId)
    .where("status", "==", "no")
    .get();
  return snap.docs.map((d) => d.data().uid);
}

/** Jugadores que dijeron que iban (intención previa). */
async function intendedYes(matchId) {
  const snap = await db
    .collection("attendance")
    .where("matchId", "==", matchId)
    .where("status", "==", "yes")
    .get();
  return snap.docs.map((d) => d.data().uid);
}

/**
 * Envía una notificación push a una lista de usuarios y limpia tokens muertos.
 * @param {string[]} uids
 * @param {{title: string, body: string, data?: Record<string, string>}} payload
 */
async function sendToUsers(uids, payload) {
  const unique = [...new Set(uids)].filter(Boolean);
  if (unique.length === 0) return;

  const refs = unique.map((uid) => db.collection("users").doc(uid));
  const snaps = await db.getAll(...refs);
  const tokenOwner = new Map();
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const data = snap.data();
    // Varios teléfonos por usuario (fcmTokens) más el campo viejo (fcmToken).
    const tokens = Array.isArray(data.fcmTokens) ? data.fcmTokens : [];
    if (data.fcmToken) tokens.push(data.fcmToken);
    for (const token of tokens) {
      if (token) tokenOwner.set(token, snap.id);
    }
  }
  const tokens = [...tokenOwner.keys()];
  if (tokens.length === 0) return;

  const response = await messaging.sendEachForMulticast({
    tokens,
    notification: { title: payload.title, body: payload.body },
    data: payload.data || {},
    android: {
      priority: "high",
      notification: { channelId: "elfurbo_default", icon: "ic_notification", color: "#D4AF37" },
    },
  });

  const cleanup = [];
  response.responses.forEach((r, i) => {
    if (r.success) return;
    const code = r.error && r.error.code;
    if (
      code === "messaging/registration-token-not-registered" ||
      code === "messaging/invalid-registration-token"
    ) {
      const uid = tokenOwner.get(tokens[i]);
      cleanup.push(
        db.collection("users").doc(uid).update({
          fcmTokens: admin.firestore.FieldValue.arrayRemove(tokens[i]),
          fcmToken: admin.firestore.FieldValue.delete(),
        })
      );
    } else {
      logger.warn("Fallo enviando push", { code, uid: tokenOwner.get(tokens[i]) });
    }
  });
  await Promise.all(cleanup);
  logger.info(`Push enviado: ${response.successCount} ok, ${response.failureCount} fallidos`);
}

/** Rango [inicio, fin) del día de hoy en la zona horaria del grupo. */
function todayRange(now = new Date()) {
  const ymd = new Intl.DateTimeFormat("en-CA", {
    timeZone: TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
  const wallClock = new Date(now.toLocaleString("en-US", { timeZone: TIME_ZONE }));
  const offsetMs = now.getTime() - wallClock.getTime();
  const start = new Date(new Date(`${ymd}T00:00:00Z`).getTime() + offsetMs);
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  return { start, end };
}

async function matchesToday() {
  const { start, end } = todayRange();
  const snap = await db
    .collection("matches")
    .where("date", ">=", admin.firestore.Timestamp.fromDate(start))
    .where("date", "<", admin.firestore.Timestamp.fromDate(end))
    .get();
  return snap.docs
    .map((d) => ({ id: d.id, ...d.data() }))
    .filter((m) => m.status !== "cancelled");
}

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

exports.onUserCreated = onDocumentCreated("users/{uid}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const uid = event.params.uid;
  const user = snap.data();

  const countSnap = await db.collection("users").count().get();
  const total = countSnap.data().count;

  if (total <= 1) {
    logger.info(`Primer usuario ${uid}: queda como admin activo`);
    await snap.ref.update({ role: "admin", status: "active" });
    return;
  }

  const admins = await adminUserIds();
  await sendToUsers(admins, {
    title: "Nuevo jugador esperando",
    body: `${playerName(user)} quiere entrar al grupo. Apruébalo desde Admin.`,
    data: { type: "pending_user", uid },
  });
});

exports.onReportCreated = onDocumentCreated("reports/{id}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const report = snap.data();

  const [author, attendees] = await Promise.all([getUser(report.uid), attendeesPresent(report.matchId)]);
  const targets = attendees.filter((uid) => uid !== report.uid);

  await sendToUsers(targets, {
    title: "Reporte para confirmar",
    body: `${playerName(author)} dice que hizo ${plural(report.goals, "gol", "goles")} y ${plural(
      report.assists,
      "asistencia",
      "asistencias"
    )}. ¿Es verdad?`,
    data: { type: "report", matchId: report.matchId, reportId: event.params.id },
  });
});

exports.onReportUpdated = onDocumentUpdated("reports/{id}", async (event) => {
  if (!event.data) return;
  const before = event.data.before.data();
  const after = event.data.after.data();
  const prev = derivedStatus(before);
  const next = derivedStatus(after);

  // El admin corrigió los números: avisamos al autor.
  if (after.correctedBy && after.correctedBy !== before.correctedBy) {
    await sendToUsers([after.uid], {
      title: "Reporte corregido",
      body: `El admin corrigió tu reporte: ${plural(after.goals, "gol", "goles")} y ${plural(
        after.assists,
        "asistencia",
        "asistencias"
      )}. Ya cuentan en la tabla.`,
      data: { type: "report_status", matchId: after.matchId, reportId: event.params.id },
    });
    return;
  }

  if (prev === next) return;

  // Un reporte confirmado volvió a pendiente (el autor lo editó): hay que
  // confirmarlo de nuevo.
  if (prev === "confirmed" && next === "pending") {
    const [author, present] = await Promise.all([getUser(after.uid), attendeesPresent(after.matchId)]);
    await sendToUsers(present.filter((uid) => uid !== after.uid), {
      title: "Reporte editado",
      body: `${playerName(author)} cambió su reporte a ${plural(after.goals, "gol", "goles")} y ${plural(
        after.assists,
        "asistencia",
        "asistencias"
      )}. Vuelve a confirmarlo.`,
      data: { type: "report", matchId: after.matchId, reportId: event.params.id },
    });
    return;
  }

  let title;
  let body;
  if (next === "confirmed") {
    title = "Reporte confirmado";
    body = `Te confirmaron ${plural(after.goals, "gol", "goles")} y ${plural(
      after.assists,
      "asistencia",
      "asistencias"
    )}. Ya cuentan en la tabla.`;
  } else if (next === "rejected") {
    title = "Reporte rechazado";
    body = "El admin rechazó tu reporte. Revísalo y vuelve a cargarlo si hace falta.";
  } else {
    return;
  }

  await sendToUsers([after.uid], {
    title,
    body,
    data: { type: "report_status", matchId: after.matchId, reportId: event.params.id },
  });
});

exports.matchDayReminder = onSchedule(
  { schedule: "0 9 * * *", timeZone: TIME_ZONE },
  async () => {
    const matches = await matchesToday();
    if (matches.length === 0) return;
    const users = await activeUserIds();
    for (const match of matches) {
      // Quien ya dijo "No voy" no necesita el recordatorio.
      const declined = new Set(await intendedNo(match.id));
      const targets = users.filter((uid) => !declined.has(uid));
      const hour = new Intl.DateTimeFormat("es", {
        timeZone: TIME_ZONE,
        hour: "2-digit",
        minute: "2-digit",
      }).format(match.date.toDate());
      await sendToUsers(targets, {
        title: "¡Hoy se juega!",
        body: `Jornada a las ${hour}${match.place ? ` en ${match.place}` : ""}. Marca si vas.`,
        data: { type: "match_day", matchId: match.id },
      });
    }
  }
);

exports.postMatchReminder = onSchedule(
  { schedule: "0 22 * * *", timeZone: TIME_ZONE },
  async () => {
    const matches = await matchesToday();
    for (const match of matches) {
      if (match.date.toDate() > new Date()) continue;
      // A las 22:00 casi nadie confirmó presencia todavía: avisamos a los que
      // dijeron que iban y a los que ya se marcaron presentes.
      const [intended, present] = await Promise.all([intendedYes(match.id), attendeesPresent(match.id)]);
      const attendees = [...intended, ...present];
      await sendToUsers(attendees, {
        title: "¿Cuántos metiste hoy?",
        body: "Carga tus goles y asistencias, y vota al MVP de la jornada.",
        data: { type: "post_match", matchId: match.id },
      });
    }
  }
);
