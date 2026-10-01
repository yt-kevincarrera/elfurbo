import { createGuest } from "../commands/members";
import type { CommandHandler } from "./command";

/** Todos los tipos de comando que entiende el servidor. El PR3b añade los de la pachanga. */
export const HANDLERS: Record<string, CommandHandler | undefined> = {
  "member.createGuest": createGuest,
};
