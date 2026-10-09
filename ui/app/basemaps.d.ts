// app/basemaps.d.ts — the @protomaps/basemaps surface the dial actually calls.
//
// The third foreign API declared by hand, under the policy of d3.d.ts and
// maplibre.d.ts: DECLARE A MEMBER THE FIRST TIME A MODULE CALLS IT. The
// library is vendored as a classic script (vendor/basemaps/basemaps.js, loaded
// after maplibre), so it is a global rather than an import.
//
// A flavor is the style's palette: a flat object of colour strings, with two
// nested palettes (pois, landcover) and three optional font names. Typed as
// that shape and nothing narrower, because basemap.ts walks it generically —
// every colour through the theme, every font name left as it is.

declare global {
  namespace basemaps {
    type Flavor = Record<string, string | Record<string, string> | undefined>;
    /** The light palette; the dial's theme re-hues it (app/basemap.ts). */
    const LIGHT: Flavor;
    /**
     * The style layers for a Protomaps build in SOURCE, coloured by FLAVOR,
     * labelled in LANG (an OSM `name:xx` code; the local name where none).
     */
    function layers(source: string, flavor: Flavor,
                    options?: { lang?: string; labelsOnly?: boolean }): maplibregl.StyleLayer[];
  }
}

export {};
