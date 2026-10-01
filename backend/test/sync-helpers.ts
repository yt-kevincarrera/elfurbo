import { expect } from "vitest";
import { api } from "./helpers";

export type Cmd = { id: string; clubId: string; type: string; payload: unknown; clientAt: string };

/** Un comando como lo manda la app: id nuevo y hora del teléfono = ahora (o la que se pase). */
export function cmd(clubId: string, type: string, payload: unknown = {}, extra: Partial<Cmd> = {}): Cmd {
  return { id: crypto.randomUUID(), clubId, type, payload, clientAt: new Date().toISOString(), ...extra };
}

export async function push(token: string, ...commands: Cmd[]) {
  const res = await api("/sync/push", { token, body: { commands } });
  expect(res.status).toBe(200);
  return res.body.results as { id: string; status: string; code?: string; message?: string; details?: unknown; original?: unknown }[];
}

/** Empuja un solo comando y comprueba que se aplicó. */
export async function apply(token: string, command: Cmd) {
  const [result] = await push(token, command);
  expect(result, JSON.stringify(result)).toMatchObject({ status: "applied" });
}

/** Empuja un solo comando y devuelve el código con el que se rechazó. */
export async function rejection(token: string, command: Cmd) {
  const [result] = await push(token, command);
  expect(result!.status).toBe("rejected");
  return result!.code;
}

export async function pullAll(token: string, cursors: Record<string, number> = {}) {
  const res = await api("/sync/pull", { token, body: { cursors } });
  expect(res.status).toBe(200);
  return res.body as {
    clubs: Record<
      string,
      {
        cursor: number;
        hasMore: boolean;
        snapshot: boolean;
        upserts: Record<string, Record<string, unknown>[]>;
        deletes: Record<string, string[]>;
      }
    >;
    removed: string[];
  };
}
