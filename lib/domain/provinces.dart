/// Provincias de Cuba (y "Fuera de Cuba") con el código corto que guarda el
/// servidor (`backend/src/rules/provinces.ts`), en orden de oeste a este.
const provinces = <String, String>{
  'pri': 'Pinar del Río',
  'art': 'Artemisa',
  'hab': 'La Habana',
  'may': 'Mayabeque',
  'mat': 'Matanzas',
  'cfg': 'Cienfuegos',
  'vcl': 'Villa Clara',
  'ssp': 'Sancti Spíritus',
  'cav': 'Ciego de Ávila',
  'cam': 'Camagüey',
  'ltu': 'Las Tunas',
  'hol': 'Holguín',
  'gra': 'Granma',
  'stg': 'Santiago de Cuba',
  'gtm': 'Guantánamo',
  'ijv': 'Isla de la Juventud',
  'ext': 'Fuera de Cuba',
};

/// "Playa, La Habana", "La Habana", "Playa" o null.
String? placeLabel(String? province, String? city) {
  final p = provinces[province];
  final c = (city ?? '').trim();
  if (p == null) return c.isEmpty ? null : c;
  return c.isEmpty ? p : '$c, $p';
}
