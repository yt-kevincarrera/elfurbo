import { describe, expect, it } from "vitest";
import fixtures from "../../shared-fixtures/app-commands.json";
import { HANDLERS } from "../src/sync/handlers";

type Case = { name: string; type: string; payload: Record<string, unknown> };

/** "<uuid>" es un id que genera el teléfono: aquí, uno de verdad. */
function withIds(payload: Record<string, unknown>) {
  return Object.fromEntries(Object.entries(payload).map(([k, v]) => [k, v === "<uuid>" ? crypto.randomUUID() : v]));
}

describe("shared-fixtures/app-commands.json (los comandos que emite la app)", () => {
  it.each(fixtures.commands as Case[])("$name", (c) => {
    const handler = HANDLERS[c.type];
    expect(handler, `el servidor no conoce ${c.type}`).toBeDefined();
    const parsed = handler!.schema.safeParse(withIds(c.payload));
    expect(parsed.success, JSON.stringify(parsed.error?.issues)).toBe(true);
  });
});
