/**
 * El código de asistencia de una jornada (spec 2.0 §8.1): 6 cifras que cambian cada 5 minutos,
 * TOTP con HMAC-SHA256 sobre el secreto del servidor. Igual que lib/domain/checkin.dart: los dos
 * pasan shared-fixtures/checkin.json.
 */
export const CHECKIN_WINDOW_MS = 5 * 60 * 1000;

function hexToBytes(hex: string) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** El código de la ventana `floor(at / 5 min)`. */
export async function checkinCode(secretHex: string, at: Date, offset = 0) {
  const counter = Math.floor(at.getTime() / CHECKIN_WINDOW_MS) + offset;
  const msg = new Uint8Array(8);
  new DataView(msg.buffer).setBigUint64(0, BigInt(counter));
  const key = await crypto.subtle.importKey("raw", hexToBytes(secretHex), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, msg));
  // Truncado dinámico (RFC 4226).
  const o = mac[mac.length - 1]! & 0x0f;
  const bin = ((mac[o]! & 0x7f) << 24) | (mac[o + 1]! << 16) | (mac[o + 2]! << 8) | mac[o + 3]!;
  return String(bin % 1_000_000).padStart(6, "0");
}

/** Vale el de la ventana de `at` o el de la de al lado (los relojes no van iguales). */
export async function checkinValid(secretHex: string, at: Date, code: string) {
  for (const offset of [0, -1, 1]) if ((await checkinCode(secretHex, at, offset)) === code) return true;
  return false;
}
