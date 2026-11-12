"""Load filtered OSM places/facilities (GeoJSON sequence from `osmium export`) into
places.sqlite with an FTS5 index on name. Read-only on the device.

Usage: python3 build_places_db.py places.geojsonseq places.sqlite
"""
import json
import os
import sqlite3
import sys

src, dst = sys.argv[1], sys.argv[2]

# Order matters: the first matching rule decides the kind.
def kind_of(t):
    a = t.get("amenity")
    if a in ("hospital",) or t.get("healthcare") == "hospital":
        return "hospital"
    if a in ("clinic", "doctors") or t.get("healthcare") == "clinic":
        return "clinic"
    if a == "pharmacy":
        return "pharmacy"
    if a == "fire_station":
        return "fire_station"
    if a == "police":
        return "police"
    if a == "fuel":
        return "fuel"
    if a == "drinking_water" or t.get("emergency") == "drinking_water":
        return "drinking_water"
    if a == "shelter" or t.get("social_facility") == "shelter" or t.get("emergency") == "assembly_point":
        # Picnic and bus shelters are not emergency shelters.
        if a == "shelter" and t.get("shelter_type") in ("picnic_shelter", "public_transport", "weather_shelter", "lean_to", "basic_hut", "field_shelter"):
            return None
        return "shelter"
    p = t.get("place")
    if p in ("city", "town", "village", "hamlet"):
        return p
    return None


def centroid(geom):
    g = geom["type"]
    c = geom["coordinates"]
    if g == "Point":
        return c[1], c[0]
    if g == "Polygon":
        ring = c[0]
    elif g == "MultiPolygon":
        ring = max((poly[0] for poly in c), key=len)
    else:
        return None
    # Area-weighted centroid of the outer ring; falls back to vertex mean.
    a = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
        f = x0 * y1 - x1 * y0
        a += f
        cx += (x0 + x1) * f
        cy += (y0 + y1) * f
    if abs(a) < 1e-12:
        xs, ys = zip(*ring)
        return sum(ys) / len(ys), sum(xs) / len(xs)
    a *= 0.5
    return cy / (6 * a), cx / (6 * a)


def address(t):
    street = " ".join(x for x in (t.get("addr:housenumber"), t.get("addr:street")) if x)
    parts = [street, t.get("addr:city"), " ".join(x for x in ("WA" if t.get("addr:city") else None, t.get("addr:postcode")) if x)]
    return ", ".join(p for p in parts if p)


if os.path.exists(dst):
    os.remove(dst)
db = sqlite3.connect(dst)
db.executescript(
    """
    CREATE TABLE places (
        id INTEGER PRIMARY KEY,
        osm_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        address TEXT NOT NULL DEFAULT '',
        phone TEXT NOT NULL DEFAULT '',
        website TEXT NOT NULL DEFAULT '',
        population INTEGER
    );
    CREATE INDEX places_kind ON places(kind);
    CREATE VIRTUAL TABLE places_fts USING fts5(
        name, kind, address,
        content='places', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
    );
    """
)

seen = set()
rows = 0
skipped_unnamed = 0
with open(src, encoding="utf-8") as f:
    for line in f:
        line = line.strip().lstrip("\x1e")
        if not line:
            continue
        feat = json.loads(line)
        t = feat.get("properties", {})
        kind = kind_of(t)
        if not kind:
            continue
        name = t.get("name") or t.get("official_name")
        if not name:
            if kind in ("drinking_water", "fuel"):
                name = {"drinking_water": "Drinking water", "fuel": t.get("brand") or "Fuel"}[kind]
            else:
                skipped_unnamed += 1
                continue
        osm_id = f"{t.get('@type', '?')[0]}{t.get('@id', '')}"
        if osm_id in seen:
            continue
        seen.add(osm_id)
        c = centroid(feat["geometry"])
        if not c:
            continue
        lat, lon = c
        pop = t.get("population")
        try:
            pop = int(str(pop).replace(",", "")) if pop else None
        except ValueError:
            pop = None
        db.execute(
            "INSERT INTO places(osm_id,name,kind,lat,lon,address,phone,website,population) VALUES (?,?,?,?,?,?,?,?,?)",
            (osm_id, name, kind, round(lat, 6), round(lon, 6), address(t),
             t.get("phone") or t.get("contact:phone") or "",
             t.get("website") or t.get("contact:website") or "", pop),
        )
        rows += 1

db.execute("INSERT INTO places_fts(places_fts) VALUES ('rebuild')")
db.commit()
db.execute("VACUUM")
db.close()
print(f"places.sqlite: {rows} rows ({skipped_unnamed} unnamed facilities skipped)")
