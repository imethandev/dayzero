# DayZero

An iPhone app for household emergency preparedness that works with **no internet at all**. Track your food and water and see how many days they last, keep notes on your household, find nearby hospitals and shelters on an offline map, and use tools like a flashlight, SOS signal and compass when the network is down.

Everything stays on the phone. DayZero has no accounts, no analytics and no server. It makes a network request only when you tap **Save for offline** on a web page.

> The bundled map and emergency contacts cover **Washington State**. The [data pipeline](#offline-map-data) can build a map for any other region.

## Features

- **Supplies.** Water, Food, Baby Food and Pet Food pages, plus checklists for Power Tools, Water Tools, Sanitation and Survival Tools (about 120 suggested items). The app shows **days of water and food** for your active household members, colored red, amber or green. Expiry reminders and low-supply alerts are local notifications.
- **Household.** Members with daily calorie and water needs, gender, phone number (tap to call) and notes. Household notes can be pinned and linked to members.
- **Offline map.** Vector tiles for all of Washington (zoom 0–14), with light and dark styles. Hospitals, clinics, pharmacies, fire stations, police, fuel, drinking water and shelters appear as filterable categories. Includes offline place search, your own pins, distance and bearing to any point, and your coordinates.
- **Emergency.** 911, Poison Control, 211, Washington EMD and all 39 county emergency management offices. You can add your own contacts, find the nearest facilities, and save contact websites for offline reading.
- **Control.** Flashlight, SOS (screen and LED in Morse), screen light, whistle, Morse code, compass, coordinates, sunrise and sunset times, timer, stopwatch, calculator, unit converter and dialer. Home Screen quick actions open the flashlight and SOS.
- **Backup.** Export everything to one JSON file (AirDrop it or save it to a USB drive), restore it later, or print a PDF emergency sheet.

## Requirements

- macOS with **Xcode 16 or later**
- An iPhone on **iOS 17 or later**. The simulator works too, but it has no flashlight or compass.
- A free or paid Apple developer account, to install on a device
- About 2 GB of free disk space and Java 21 to build the map data (see below)

## Getting started

```sh
git clone https://github.com/enguyendesigner/dayzero.git
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

### 2. Build the offline map data

The map tiles (about 320 MB) and the places database are too large for git, so you generate them once:

```sh
brew install openjdk@21 osmium-tool pmtiles
pipeline/build_offline_data.sh
```

This takes about 3 minutes on an Apple silicon Mac. It downloads a Washington OpenStreetMap extract from Geofabrik (about 350 MB), builds vector tiles with Planetiler, and writes everything to `DayZero/Resources/Offline/Map.bundle/`. If you skip this step, the app still runs, but the Map tab shows "Map data missing".

### 3. Run

Open `DayZero.xcodeproj`, choose the **DayZero** scheme and your iPhone or a simulator, and press Run. Xcode fetches the one dependency, [MapLibre Native](https://github.com/maplibre/maplibre-native), through Swift Package Manager.

Run the tests with ⌘U, or from the command line:

```sh
xcodebuild test -project DayZero.xcodeproj -scheme DayZero \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

## Offline map data

`pipeline/build_offline_data.sh` does the following:

1. Downloads `washington-latest.osm.pbf` from Geofabrik.
2. Runs [Planetiler](https://github.com/onthegomap/planetiler) with the OpenMapTiles profile to make `washington.pmtiles`.
3. Downloads the OSM Bright (light) and Dark Matter (dark) styles, sprites and Noto Sans glyphs, and rewrites them to load only from the app bundle. The script fails if any remote URL remains.
4. Extracts places and facilities with `osmium` into `places.sqlite`, with full-text search.
5. Writes `manifest.json` with the map bounds, data date and attribution.

**For another region,** change the Geofabrik URL in the script, for example `north-america/us/oregon-latest.osm.pbf`, and run it again. The map area, search and facility layers follow the new data automatically. The emergency contacts in `DayZero/Resources/Offline/emergency_contacts.json` are Washington-specific, so replace them for your area.

## How offline is enforced

- **Debug builds** install a network blocker (`DayZero/Shared/Offline/NetworkBlocker.swift`) that logs and fails every `URLSession` request, so a stray remote URL from a style, font or SDK shows up during testing. Settings shows a log of anything it blocked. Save for offline loads pages in a `WKWebView`, which the blocker doesn't intercept, and only when you tap it.
- Map styles, glyphs, sprites and tiles all load from `pmtiles://` and `file://` URLs inside the app bundle.
- SwiftData is set up with CloudKit off. Data never leaves the device unless you export a backup.

## Project layout

```
DayZero/
  App/          App entry, tabs, routing, quick actions
  Home/         Home list
  Supplies/     Supply pages, forms, days-remaining UI
  Household/    Members and notes
  Emergency/    Contacts, nearby facilities, saved web pages
  Map/          MapLibre map, search, pins
  Apps/         Control tab tools (flashlight, SOS, compass…)
  Shared/       Models, days-remaining math, backup, PDF, reminders, places DB
  Resources/Offline/  Supply catalog, emergency contacts, Map.bundle
DayZeroTests/   Swift Testing unit tests
pipeline/       Offline map data build scripts
Config/         Signing xcconfig (your values go in Local.xcconfig)
```

## Contributing

Issues and pull requests are welcome. Some useful places to start:

- **Supply catalog:** `DayZero/Resources/Offline/supply_catalog.json`. Keys must stay stable and unique, because existing installs merge new items by key.
- **Emergency contacts:** `DayZero/Resources/Offline/emergency_contacts.json`. Use official sources only, and only public office numbers, never personal or staff mobile numbers. Include a `source` URL.
- **Other regions:** pipeline changes or contact sets for other states.

Please run the tests before you open a pull request.

## Disclaimer

DayZero is a planning aid, not an emergency service. **In an emergency, call 911.** Phone numbers, facility locations and supply estimates can be wrong or out of date, so check the information that matters to you. The days-remaining figures use the per-person daily needs you enter.

## License and credits

DayZero's source code is released under the [MIT License](LICENSE).

Bundled and generated data have their own licenses:

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), [ODbL](https://opendatacommons.org/licenses/odbl/)
- Vector tile schema © [OpenMapTiles](https://openmaptiles.org), [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/)
- Map styles: [OSM Bright](https://github.com/openmaptiles/osm-bright-gl-style) and [Dark Matter](https://github.com/openmaptiles/dark-matter-gl-style) (BSD-3-Clause code, CC-BY 4.0 design)
- [Noto Sans](https://fonts.google.com/noto) font, SIL Open Font License 1.1
- [MapLibre Native](https://github.com/maplibre/maplibre-native), BSD-2-Clause
- Emergency contacts were compiled from public Washington State and county government websites and the WA Emergency Management Division's statewide contact list.
