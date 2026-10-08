import { describe, expect, it } from "vitest";
import fixture from "../../shared-fixtures/stats.json";
import { computeStats, type StatsRows, type StatsSettings } from "../src/rules/stats";

type Case = { name: string; now: string; data?: unknown; settings: StatsSettings; seasonId: string | null; expected: Record<string, Record<string, number>> };

const KEYS = ["played", "goals", "assists", "mvps", "hatTricks", "pokers", "completeMatches", "bestDayGoals", "bestStreak"] as const;

describe("shared-fixtures/stats.json (los mismos casos que ejecuta la app en Dart)", () => {
  it.each(fixture.cases as unknown as Case[])("$name", (c) => {
    // Un caso con sus propios datos, o los de arriba.
    const data = (c.data ?? fixture.data) as StatsRows & { member: { id: string }[] };
    const stats = computeStats(data, c.settings, c.seasonId, new Date(c.now));
    for (const m of data.member) {
      const s = stats.get(m.id);
      const got = Object.fromEntries(KEYS.map((k) => [k, s?.[k] ?? 0]));
      if (c.expected[m.id]) expect(got, m.id).toEqual(c.expected[m.id]);
      else expect([got.played, got.goals, got.mvps], m.id).toEqual([0, 0, 0]);
    }
  });

  it("cuenta los reportes del período y los rechazados (para el prestigio)", () => {
    const stats = computeStats(fixture.data as unknown as StatsRows, { reportValidation: "confirm", confirmationsNeeded: 2 }, "s1", new Date("2026-10-07T12:00:00.000Z"));
    // Beto: md1 (pendiente) y md2 (rechazado). El reporte de md3 (cancelada) no es del período jugado.
    expect(stats.get("b")).toMatchObject({ reports: 2, rejected: 1 });
    expect(stats.get("a")).toMatchObject({ reports: 2, rejected: 0 });
  });
});
