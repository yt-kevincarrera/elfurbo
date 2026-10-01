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
