/** Provincias de Cuba (y "Fuera de Cuba"), con el código corto que se guarda en `clubs.province`. */
export const PROVINCES = {
  pri: "Pinar del Río",
  art: "Artemisa",
  hab: "La Habana",
  may: "Mayabeque",
  mat: "Matanzas",
  cfg: "Cienfuegos",
  vcl: "Villa Clara",
  ssp: "Sancti Spíritus",
  cav: "Ciego de Ávila",
  cam: "Camagüey",
  ltu: "Las Tunas",
  hol: "Holguín",
  gra: "Granma",
  stg: "Santiago de Cuba",
  gtm: "Guantánamo",
  ijv: "Isla de la Juventud",
  ext: "Fuera de Cuba",
} as const;

export type Province = keyof typeof PROVINCES;

export const PROVINCE_CODES = Object.keys(PROVINCES) as [Province, ...Province[]];
