import { ban, createGuest, leave, setRole, unban, updateMember } from "../commands/members";
import type { CommandHandler } from "./command";

/** Todos los tipos de comando que entiende el servidor. El PR3b añade los de la pachanga. */
export const HANDLERS: Record<string, CommandHandler | undefined> = {
  "member.createGuest": createGuest,
  "member.update": updateMember,
  "member.setRole": setRole,
  "member.ban": ban,
  "member.unban": unban,
  "member.leave": leave,
};
