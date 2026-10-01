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
