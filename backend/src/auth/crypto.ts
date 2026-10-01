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
