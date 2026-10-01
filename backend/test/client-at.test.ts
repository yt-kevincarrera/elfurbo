import { describe, expect, it } from "vitest";
import { effectiveClientAt } from "../src/sync/command";

const now = new Date("2026-10-10T12:00:00Z");
const hoursAgo = (h: number) => new Date(now.getTime() - h * 3600_000);

describe("hora del teléfono (spec §5)", () => {
  it("se cree si es del pasado reciente: el reporte hecho sin señal cuenta con su hora", () => {
    expect(effectiveClientAt(hoursAgo(30), now)).toEqual(hoursAgo(30));
  });

  it("si está en el futuro (reloj adelantado), vale la hora del servidor", () => {
    expect(effectiveClientAt(new Date(now.getTime() + 60_000), now)).toEqual(now);
  });

  it("si es de hace 7 días o más (reloj atrasado o trampa), vale la hora del servidor", () => {
    expect(effectiveClientAt(hoursAgo(7 * 24), now)).toEqual(now);
    expect(effectiveClientAt(hoursAgo(7 * 24 - 1), now)).toEqual(hoursAgo(7 * 24 - 1));
  });
});
