import { describe, expect, it } from "vitest";
import {
  canActForOthers,
  canActForSelf,
  canBan,
  canCreateMatchday,
  canDecideReports,
  canEditMatchday,
  canInviteAs,
  canIssueRecoveryCode,
  canManageClub,
  canManageInvites,
  canManageMatchday,
  canManageSeasons,
  canSetRole,
  type Role,
} from "../src/authz";

const ROLES: Role[] = ["owner", "admin", "scorer", "player", "guest"];
/** Quién tiene el permiso, en el orden de ROLES. */
const who = (f: (r: Role) => boolean) => ROLES.filter(f);

describe("matriz de permisos (spec §4)", () => {
  it("ajustes y transferir: solo owner", () => expect(who(canManageClub)).toEqual(["owner"]));
  it("ver y revocar invitaciones: owner y admin", () => expect(who(canManageInvites)).toEqual(["owner", "admin"]));
  it("temporadas: owner y admin", () => expect(who(canManageSeasons)).toEqual(["owner", "admin"]));
  it("decidir reportes: owner y admin", () => expect(who(canDecideReports)).toEqual(["owner", "admin"]));
  it("pasar lista, cargar por otros, sin cuenta, equipos: staff", () =>
    expect(who(canActForOthers)).toEqual(["owner", "admin", "scorer"]));
  it("acciones propias: todos los que tienen cuenta", () =>
    expect(who(canActForSelf)).toEqual(["owner", "admin", "scorer", "player"]));

  it("invitar: owner con cualquier rol; admin solo player o scorer", () => {
    expect(who((r) => canInviteAs(r, "admin"))).toEqual(["owner"]);
    expect(who((r) => canInviteAs(r, "scorer"))).toEqual(["owner", "admin"]);
    expect(who((r) => canInviteAs(r, "player"))).toEqual(["owner", "admin"]);
  });

  it("códigos de recuperación: owner para todos menos sí mismo; admin para scorer y player", () => {
    expect(who((r) => canIssueRecoveryCode(r, "admin"))).toEqual(["owner"]);
    expect(who((r) => canIssueRecoveryCode(r, "player"))).toEqual(["owner", "admin"]);
    expect(who((r) => canIssueRecoveryCode(r, "owner"))).toEqual([]);
    expect(who((r) => canIssueRecoveryCode(r, "guest"))).toEqual([]);
  });

  it("roles: el owner nombra y quita admins; un admin solo mueve entre scorer y player", () => {
    expect(canSetRole("owner", "player", "admin")).toBe(true);
    expect(canSetRole("owner", "admin", "player")).toBe(true);
    expect(canSetRole("admin", "player", "scorer")).toBe(true);
    expect(canSetRole("admin", "player", "admin")).toBe(false);
    expect(canSetRole("admin", "admin", "player")).toBe(false);
    expect(canSetRole("scorer", "player", "scorer")).toBe(false);
  });

  it("nadie se vuelve owner cambiando el rol, ni se le cambia el rol a un sin cuenta", () => {
    for (const actor of ROLES) {
      expect(canSetRole(actor, "admin", "owner")).toBe(false);
      expect(canSetRole(actor, "owner", "admin")).toBe(false);
      expect(canSetRole(actor, "guest", "player")).toBe(false);
    }
  });

  it("expulsar: owner a cualquiera menos al owner; admin a scorer, player o sin cuenta", () => {
    expect(who((r) => canBan(r, "admin"))).toEqual(["owner"]);
    expect(who((r) => canBan(r, "guest"))).toEqual(["owner", "admin"]);
    expect(who((r) => canBan(r, "owner"))).toEqual([]);
  });

  it("crear jornadas: staff siempre; player solo si el servidor deja a cualquier miembro", () => {
    expect(who((r) => canCreateMatchday(r, "members"))).toEqual(["owner", "admin", "scorer", "player"]);
    expect(who((r) => canCreateMatchday(r, "staff"))).toEqual(["owner", "admin", "scorer"]);
  });

  it("editar jornadas: staff, o el player que la creó", () => {
    expect(canEditMatchday("player", { isCreator: true })).toBe(true);
    expect(canEditMatchday("player", { isCreator: false })).toBe(false);
    expect(canEditMatchday("scorer", { isCreator: false })).toBe(true);
  });

  it("cancelar o borrar jornadas: el player creador solo si nadie más cargó datos", () => {
    expect(canManageMatchday("player", { isCreator: true, hasOthersData: false })).toBe(true);
    expect(canManageMatchday("player", { isCreator: true, hasOthersData: true })).toBe(false);
    expect(canManageMatchday("admin", { isCreator: false, hasOthersData: true })).toBe(true);
    expect(canManageMatchday("guest", { isCreator: true, hasOthersData: false })).toBe(false);
  });
});
