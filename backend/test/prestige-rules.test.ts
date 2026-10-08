import { describe, expect, it } from "vitest";
import { prestigeReport, score, tierFor, type Signals } from "../src/rules/prestige";

const solid: Signals = {
  ageDays: 200,
  totalPlayed: 40,
  matchdays90: 12,
  avgPlayers: 12,
  players90: 18,
  confirmMode: true,
  confirmationsNeeded: 2,
  staffShare: 1,
  checkinShare: 1,
  accountsShare: 1,
  networkShare: 0.5,
  rejectedShare: 0,
  goalsPerPresence: 1,
};

describe("reglas de prestigio", () => {
  it("todo al máximo: 100 y Verificado; oficial manda sobre todo", () => {
    expect(score(solid)).toBe(100);
    expect(tierFor(solid, false)).toBe("verified");
    expect(tierFor({ ...solid, totalPlayed: 1 }, true)).toBe("official");
  });

  it("Nuevo hasta 30 días y 4 jornadas, aunque puntúe alto", () => {
    expect(tierFor({ ...solid, ageDays: 29 }, false)).toBe("new");
    expect(tierFor({ ...solid, totalPlayed: 3 }, false)).toBe("new");
    expect(prestigeReport({ ...solid, totalPlayed: 3 }, false).newReason).toContain("lleva 3");
  });

  it("penalizaciones: muchos rechazos (−10) y goles imposibles (−5 o −15)", () => {
    expect(score({ ...solid, rejectedShare: 0.2 })).toBe(90);
    expect(score({ ...solid, goalsPerPresence: 2.5 })).toBe(95);
    expect(score({ ...solid, goalsPerPresence: 3.5 })).toBe(85);
    expect(score({ ...solid, goalsPerPresence: 3.5, rejectedShare: 0.5, ageDays: 0, matchdays90: 0 })).toBe(45);
  });

  it("niveles por puntuación: 40 Establecido, menos Casual; confiando no pasa de Establecido", () => {
    const weak: Signals = { ...solid, matchdays90: 1, avgPlayers: 3, accountsShare: 0.2, networkShare: 0, staffShare: 0, checkinShare: 0 };
    expect(score(weak)).toBeLessThan(70);
    expect(tierFor(weak, false)).toBe(score(weak) >= 40 ? "established" : "casual");
    expect(tierFor({ ...solid, confirmMode: false }, false)).toBe("established");
    expect(tierFor({ ...weak, confirmMode: false, accountsShare: 0, ageDays: 31 }, false)).toBe("casual");
  });

  it("qué le falta: una pista por parte incompleta, ninguna si está completa", () => {
    const report = prestigeReport({ ...solid, matchdays90: 6, networkShare: 0.1 }, false);
    const hint = (key: string) => report.parts.find((p) => p.key === key)?.hint;
    expect(hint("activity")).toContain("6 jornadas");
    expect(hint("network")).toContain("10 %");
    expect(hint("age")).toBeNull();
    expect(hint("validation")).toBeNull();
  });
});
