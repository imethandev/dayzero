# DayZero

An iPhone app for household emergency preparedness that works with **no internet at all**. Track your food and water and see how many days they last, keep notes on your household, find nearby hospitals and shelters on an offline map, and use tools like a flashlight, SOS signal and compass when the network is down.

Everything stays on the phone. DayZero has no accounts, no analytics and no server. It goes online only when you tap **Download my area** on the Map tab or **Save for offline** on a web page.

> Works anywhere: the app downloads a map of the area around you, and the Emergency page uses your country's emergency number.

## Features

- **Supplies.** Water, Food, Baby Food and Pet Food pages, plus checklists for Power and Fuels, Communication (AM/FM and weather radios, FRS, GMRS, ham, CB, Meshtastic, satellite messengers), Water (filters and purification), Food (stoves and cookware), Sanitation, Medicine, First Aid, Shelter, Navigation, Security and Survival Tools, and a 72-hour Go-Bag checklist (about 240 suggested items). The app shows **days of water and food** for your active household members, colored red, amber or green. Expiry reminders and low-supply alerts are local notifications.
- **Household.** Members with daily calorie and water needs, gender, phone number (tap to call) and notes. Household notes can be pinned and linked to members.
- **Offline map.** Download the area around you (5–30 km, full street detail) once, then use it with no signal. Light and dark styles. Hospitals, clinics, pharmacies, fire stations, police, fuel, drinking water and shelters appear as filterable categories. Includes offline place search, your own pins, distance and bearing to any point, and your coordinates.
- **Emergency.** A Call button with your country's emergency number (about 60 countries built in, 112 elsewhere), national lines for the US (911, 988, Poison Control, 211, FEMA, Red Cross, Disaster Distress Helpline), and a "Near you" group of the closest hospitals, police and fire stations from your downloaded map. Country is detected from the map download or your iPhone's region, or set by hand. You can add your own contacts and save contact websites for offline reading.
- **Tips.** 19 offline guides on Home for outages (power, water, phones), disasters (earthquake, flood, tsunami, volcano, wildfire smoke, heat, winter storm, landslide, nuclear fallout), the home (sewage backflow, utility shutoffs, carbon monoxide, water storage, food safety) and skills (evacuating, pets). Each has an overview, safety warnings and five things to do.
- **Control.** Flashlight, SOS (screen and LED in Morse), screen light, whistle, Morse code, compass, coordinates, sunrise and sunset times, timer, stopwatch, calculator, unit converter and dialer. Home Screen quick actions open the flashlight and SOS.
- **Backup.** Export everything to one JSON file (AirDrop it or save it to a USB drive), restore it later, or print a PDF emergency sheet.

## Requirements

- macOS with **Xcode 16 or later**
- An iPhone on **iOS 17 or later**. The simulator works too, but it has no flashlight or compass.
- A free or paid Apple developer account, to install on a device
- Optional: about 2 GB of free disk space and Java 21 to bundle a map at build time (see below)

## Getting started

```sh
git clone https://github.com/imethandev/dayzero.git
cd dayzero
```

### 1. Set up signing

Your Apple team ID and bundle ID live in a local file that git ignores:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345      // your team ID
BUNDLE_ID_PREFIX = com.yourname    // the app becomes com.yourname.DayZero
```

Without this file, the project still builds and runs in the simulator with the placeholder `org.example.DayZero`.

### 2. Run

Open `DayZero.xcodeproj`, choose the **DayZero** scheme and your iPhone or a simulator, and press Run. Xcode fetches the one dependency, [MapLibre Native](https://github.com/maplibre/maplibre-native), through Swift Package Manager.

Run the tests with ⌘U, or from the command line:

```sh
xcodebuild test -project DayZero.xcodeproj -scheme DayZero \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## Offline map data

### Download in the app (default)

Open the Map tab, allow location and tap **Download my area**. DayZero downloads:

- **Map tiles** from [OpenFreeMap](https://openfreemap.org) (OpenMapTiles schema, zoom 0–14) for 5 to 30 km around you, into an MBTiles file in the app's Application Support folder. Downloads follow OpenFreeMap's offline rules: at most 3,000 tiles or 50 MB each, at most 4 parallel requests, and a User-Agent naming the app. In dense cities the 50 MB limit is reached first; tiles are fetched from the center outward, so you keep full detail closest to you.
- **Places and facilities** (hospitals, clinics, pharmacies, fire stations, police, fuel, drinking water, shelters and town names) from one [Overpass API](https://overpass-api.de) query, into a searchable `places.sqlite`.

Only the area's coordinates are sent. Tap the ↓ button on the map later to replace the area or delete it. If your fork ships to many users, consider hosting your own tiles or contacting OpenFreeMap.

### Bundle a map at build time (optional)

For a larger area, or a build that has a map before it's ever online, generate one with the pipeline. The tiles (about 320 MB for a US state) and places database are too large for git:

```sh
brew install openjdk@21 osmium-tool pmtiles
pipeline/build_offline_data.sh
```

It takes about 3 minutes on an Apple silicon Mac and writes to `DayZero/Resources/Offline/Map.bundle/`. A map downloaded in the app takes priority over a bundled one. The script:

1. Downloads `washington-latest.osm.pbf` from Geofabrik.
2. Runs [Planetiler](https://github.com/onthegomap/planetiler) with the OpenMapTiles profile to make `washington.pmtiles`.
3. Downloads the OSM Bright (light) and Dark Matter (dark) styles, sprites and Noto Sans glyphs, and rewrites them to load only from the app bundle. The script fails if any remote URL remains.
4. Extracts places and facilities with `osmium` into `places.sqlite`, with full-text search.
5. Writes `manifest.json` with the map bounds, data date and attribution.

The script uses Washington by default. **For another region,** change the Geofabrik URL in the script, for example `north-america/us/oregon-latest.osm.pbf`, and run it again. The map area, search and facility layers follow the new data automatically.

## How offline is enforced

- **Debug builds** install a network blocker (`DayZero/Shared/Offline/NetworkBlocker.swift`) that logs and fails every `URLSession` request, so a stray remote URL from a style, font or SDK shows up during testing. Settings shows a log of anything it blocked. Save for offline loads pages in a `WKWebView`, which the blocker doesn't intercept, and only when you tap it.
- Map styles, glyphs and sprites load from `file://` URLs inside the app bundle, and tiles from a local `mbtiles://` or `pmtiles://` file. The map itself never goes online.
- The map download uses its own session (`NetworkBlocker.userInitiatedSession()`), so the debug blocker still catches anything else.
- SwiftData is set up with CloudKit off. Data never leaves the device unless you export a backup.

## Project layout

```
DayZero/
  App/          App entry, tabs, routing, quick actions
  Home/         Home list
  Supplies/     Supply pages, forms, days-remaining UI
  Household/    Members and notes
  Emergency/    Contacts, nearby facilities, saved web pages
  Map/          MapLibre map, search, pins, in-app map download
  Apps/         Control tab tools (flashlight, SOS, compass…)
  Tips/         Tips page (content in Resources/Offline/tips.json)
  Shared/       Models, days-remaining math, backup, PDF, reminders, places DB
  Resources/Offline/  Supply catalog, emergency contacts, Map.bundle
DayZeroTests/   Swift Testing unit tests
pipeline/       Offline map data build scripts
Config/         Signing xcconfig (your values go in Local.xcconfig)
```

## Contributing

Issues and pull requests are welcome. Some useful places to start:

- **Supply catalog:** `DayZero/Resources/Offline/supply_catalog.json`. Keys must stay stable and unique, because existing installs merge new items by key.
- **Emergency numbers:** `DayZero/Resources/Offline/emergency_numbers.json` lists each country's police, fire and ambulance numbers. Add or correct a country with an official source.
- **National contacts:** add `contacts_<country code>.json` (copy `contacts_US.json`) with national lines such as poison control and crisis lines. Use official sources and public numbers only, never personal or staff mobile numbers, and include a `source` URL. Keys must stay stable because installs merge by key.
- **Tips:** `DayZero/Resources/Offline/tips.json`. Each tip needs an overview, safety notes and exactly five steps. Write original text based on official guidance (Ready.gov, CDC, WA EMD).
- **Other regions:** pipeline changes or contact sets for other states.

Please run the tests before you open a pull request.

## Disclaimer

DayZero is a planning aid, not an emergency service. **In an emergency, call 911.** Phone numbers, facility locations and supply estimates can be wrong or out of date, so check the information that matters to you. The days-remaining figures use the per-person daily needs you enter.

## License and credits

DayZero's source code is released under the [MIT License](LICENSE).

Bundled and generated data have their own licenses:

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), [ODbL](https://opendatacommons.org/licenses/odbl/)
- Downloaded map tiles from [OpenFreeMap](https://openfreemap.org); places from the [Overpass API](https://overpass-api.de)
- Vector tile schema © [OpenMapTiles](https://openmaptiles.org), [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/)
- Map styles: [OSM Bright](https://github.com/openmaptiles/osm-bright-gl-style) and [Dark Matter](https://github.com/openmaptiles/dark-matter-gl-style) (BSD-3-Clause code, CC-BY 4.0 design)
- [Noto Sans](https://fonts.google.com/noto) font, SIL Open Font License 1.1
- [MapLibre Native](https://github.com/maplibre/maplibre-native), BSD-2-Clause
- Emergency numbers and national contacts were compiled from official government and service websites (sources in each contact's `source` field).
