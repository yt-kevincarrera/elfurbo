import { describe, expect, it } from "vitest";
import { api, register } from "./helpers";

describe("/me", () => {
  it("GET devuelve el usuario y, por ahora, ningún servidor", async () => {
    const { token, user } = await register();
    const res = await api("/me", { token });
    expect(res.body).toEqual({ user, clubs: [] });
  });
});
