import { describe, expect, it } from "vitest";
import fixtures from "../../shared-fixtures/matchday-rules.json";
import { acceptsIntent, isClosed, isPlayed, localDay, type MatchdayTimes } from "../src/rules/matchday";

type Case = {
  name: string;
  fn: "isPlayed" | "acceptsIntent" | "isClosed" | "localDay";
  at: string;
  expected: boolean | string;
  matchday?: Partial<MatchdayTimes>;
  closeAfterHours?: number;
  timezone?: string;
};

describe("shared-fixtures/matchday-rules.json (los mismos casos que ejecuta la app en Dart)", () => {
  it.each(fixtures.cases as Case[])("$name", (c) => {
    const md = { ...(fixtures.matchday as MatchdayTimes), ...c.matchday };
    const at = new Date(c.at);
    const result = {
      isPlayed: () => isPlayed(md, at),
      acceptsIntent: () => acceptsIntent(md, at),
      isClosed: () => isClosed(md, at, c.closeAfterHours!),
      localDay: () => localDay(c.at, c.timezone!),
    }[c.fn]();
    expect(result).toBe(c.expected);
  });
});
