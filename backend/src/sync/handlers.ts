import { transferOwnership, updateSettings } from "../commands/club";
import { ban, createGuest, leave, setRole, unban, updateMember } from "../commands/members";
import {
  activateSeason,
  createSeason,
  deleteSeason,
  setSeasonClosed,
  updateSeason,
} from "../commands/seasons";
import { rollCall, setIntent, setPlayed } from "../commands/attendance";
import {
  createMatchday,
  deleteMatchday,
  saveTeams,
  setMatchdayStatus,
  updateMatchday,
} from "../commands/matchdays";
import {
  confirmReport,
  correctReport,
  decideReport,
  deleteReport,
  loadReportFor,
  unconfirmReport,
  upsertReport,
} from "../commands/reports";
import { castVote, clearVote } from "../commands/votes";
import type { CommandHandler } from "./command";

/** Todos los tipos de comando que entiende el servidor (spec §5). */
export const HANDLERS: Record<string, CommandHandler | undefined> = {
  "member.createGuest": createGuest,
  "member.update": updateMember,
  "member.setRole": setRole,
  "member.ban": ban,
  "member.unban": unban,
  "member.leave": leave,
  "club.updateSettings": updateSettings,
  "club.transferOwnership": transferOwnership,
  "season.create": createSeason,
  "season.update": updateSeason,
  "season.activate": activateSeason,
  "season.setClosed": setSeasonClosed,
  "season.delete": deleteSeason,
  "matchday.create": createMatchday,
  "matchday.update": updateMatchday,
  "matchday.setStatus": setMatchdayStatus,
  "matchday.delete": deleteMatchday,
  "teams.save": saveTeams,
  "attendance.setIntent": setIntent,
  "attendance.setPlayed": setPlayed,
  "attendance.rollCall": rollCall,
  "report.upsert": upsertReport,
  "report.delete": deleteReport,
  "report.loadFor": loadReportFor,
  "report.confirm": confirmReport,
  "report.unconfirm": unconfirmReport,
  "report.decide": decideReport,
  "report.correct": correctReport,
  "vote.cast": castVote,
  "vote.clear": clearVote,
};
