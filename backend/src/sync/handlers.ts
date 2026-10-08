import { setVisibility, transferOwnership, updateProfile, updateSettings } from "../commands/club";
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
  mergeMatchdays,
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
import {
  addPlayer,
  createTeam,
  leaveTeam,
  removePlayer,
  setShirt,
  setTeamStatus,
  updateTeam,
  finishTournament,
  reopenTournament,
  updateTournament,
} from "../commands/tournament";
import {
  advanceStage,
  clearFixtures,
  fixtureResult,
  generateFixtures,
  scheduleFixture,
  setFixtureStatus,
} from "../commands/fixtures";
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
  "club.updateProfile": updateProfile,
  "club.setVisibility": setVisibility,
  "season.create": createSeason,
  "season.update": updateSeason,
  "season.activate": activateSeason,
  "season.setClosed": setSeasonClosed,
  "season.delete": deleteSeason,
  "matchday.create": createMatchday,
  "matchday.update": updateMatchday,
  "matchday.setStatus": setMatchdayStatus,
  "matchday.delete": deleteMatchday,
  "matchday.merge": mergeMatchdays,
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
  "tournament.update": updateTournament,
  "tournament.finish": finishTournament,
  "tournament.reopen": reopenTournament,
  "team.create": createTeam,
  "team.update": updateTeam,
  "team.setStatus": setTeamStatus,
  "team.addPlayer": addPlayer,
  "team.removePlayer": removePlayer,
  "team.leave": leaveTeam,
  "team.setShirt": setShirt,
  "fixtures.generate": generateFixtures,
  "fixtures.clear": clearFixtures,
  "fixture.schedule": scheduleFixture,
  "fixture.result": fixtureResult,
  "fixture.setStatus": setFixtureStatus,
  "stage.advance": advanceStage,
};

/** Los comandos de la pachanga de siempre: solo en servidores (grupos). */
const GROUP_ONLY = /^(season|matchday|attendance|report|vote|teams)./;
/** Los de torneos: solo en torneos. */
const TOURNAMENT_ONLY = /^(tournament|team|fixture|fixtures|stage)./;

/** En qué tipo de servidor vale un comando (los de miembros y ajustes, en los dos). */
export function commandFits(type: string, kind: string) {
  if (GROUP_ONLY.test(type)) return kind === "group";
  if (TOURNAMENT_ONLY.test(type)) return kind === "tournament";
  return true;
}
