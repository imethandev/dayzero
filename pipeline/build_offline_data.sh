#!/usr/bin/env bash
# Builds every bundled offline data file for DayZero from one OpenStreetMap extract.
# Runs on a Mac before a release, never on the device.
#
#   pipeline/build_offline_data.sh            # full run
#   SKIP_TILES=1 pipeline/build_offline_data.sh   # reuse existing tiles
#
# Needs: Java 21+, osmium-tool, pmtiles, python3, curl. (brew install openjdk@21 osmium-tool pmtiles)
# Output: DayZero/Resources/Offline/Map.bundle/ (tiles, styles, glyphs, sprites, places, manifest)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/pipeline/work"
OUT="$ROOT/DayZero/Resources/Offline/Map.bundle"
PBF="$WORK/washington-latest.osm.pbf"
JAVA="${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}"
mkdir -p "$WORK" "$OUT"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# 1. Washington extract from Geofabrik
step "1. OSM extract"
[[ -s "$PBF" ]] || curl -fSL -o "$PBF" https://download.geofabrik.de/north-america/us/washington-latest.osm.pbf
osmium fileinfo -e -g header.option.osmosis_replication_timestamp "$PBF" > "$WORK/extract_timestamp.txt" || true
echo "extract timestamp: $(cat "$WORK/extract_timestamp.txt")"

# 2. Planetiler, OpenMapTiles profile, z0-14 -> washington.pmtiles
step "2. Vector tiles (Planetiler / OpenMapTiles)"
[[ -s "$WORK/planetiler.jar" ]] || curl -fSL -o "$WORK/planetiler.jar" \
  https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
if [[ -z "${SKIP_TILES:-}" || ! -s "$OUT/washington.pmtiles" ]]; then
  (cd "$WORK" && "$JAVA" -Xmx6g -jar planetiler.jar \
    --osm-path="$PBF" \
    --download --download-dir="$WORK/sources" \
    --maxzoom=14 \
    --output="$WORK/washington.pmtiles" --force)
  mv "$WORK/washington.pmtiles" "$OUT/washington.pmtiles"
fi

# 3-6. Styles, glyphs and sprites, all rewritten to bundled files
step "3-6. Styles, glyphs, sprites"
python3 -I "$ROOT/pipeline/prepare_style_assets.py" "$WORK" "$OUT"

# 7-8. Places and facilities -> places.sqlite with FTS5
step "7-8. Places database"
osmium tags-filter "$PBF" \
  n/place=city,town,village,hamlet \
  nwr/amenity=hospital,clinic,doctors,pharmacy,fire_station,police,fuel,drinking_water,shelter \
  nwr/healthcare=hospital,clinic \
  nwr/social_facility=shelter \
  nwr/emergency=assembly_point,drinking_water \
  -o "$WORK/places-filtered.osm.pbf" --overwrite
osmium export "$WORK/places-filtered.osm.pbf" -f geojsonseq \
  --geometry-types=point,polygon -a type,id -o "$WORK/places.geojsonseq" --overwrite
python3 -I "$ROOT/pipeline/build_places_db.py" "$WORK/places.geojsonseq" "$OUT/places.sqlite"

# 9. Manifest
step "9. Manifest"
pmtiles show "$OUT/washington.pmtiles" > "$WORK/pmtiles_header.txt"
python3 -I - "$WORK" "$OUT" <<'EOF'
import json, os, re, sqlite3, sys, datetime
work, out = sys.argv[1], sys.argv[2]
hdr = open(os.path.join(work, "pmtiles_header.txt")).read()
m = re.search(r"bounds: \(long: ([-\d.]+), lat: ([-\d.]+)\) \(long: ([-\d.]+), lat: ([-\d.]+)\)", hdr)
bounds = [float(x) for x in m.groups()]
ts = open(os.path.join(work, "extract_timestamp.txt")).read().strip() or None
db = sqlite3.connect(os.path.join(out, "places.sqlite"))
counts = dict(db.execute("select kind, count(*) from places group by kind").fetchall())
manifest = {
    "osmExtract": "washington-latest.osm.pbf (Geofabrik)",
    "osmTimestamp": ts,
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "tiles": {"file": "washington.pmtiles", "minzoom": 0, "maxzoom": 14, "schema": "OpenMapTiles"},
    "bounds": bounds,  # west, south, east, north from the tile header
    "places": counts,
    "attribution": "© OpenMapTiles © OpenStreetMap contributors",
}
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=2)
print(json.dumps(manifest, indent=2))
EOF

step "Sizes"
du -sh "$OUT"/* | sort -h
du -sh "$OUT"
