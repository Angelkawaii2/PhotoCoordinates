# PhotoCoordinates

[中文说明](README.zh-CN.md)

A native macOS app for viewing and editing the location of photos in the Photos library, including iCloud Photos.

Browse photos by capture date, select multiple items, search for places, copy and paste coordinates, and apply a location to all selected photos. The app also supports WGS-84 and GCJ-02 coordinate conversion and Apple Maps, OpenStreetMap, and Google Maps views. Changes to locations are written directly to the Photos library.

## Build and run

Requires macOS 14 or later and Apple Command Line Tools.

```sh
./build.sh
open PhotoCoordinates.app
```

Grant access to the Photos library when prompted. iCloud originals may need to download. Google Maps requires your own Maps JavaScript API key. Maps require network access.

## Shortcuts

| Key | Action |
| --- | --- |
| Left / Right | Previous / next photo |
| F / G | Convert selected coordinates from WGS-84 to GCJ-02 / GCJ-02 to WGS-84 |
| Command-Shift-C | Copy current photo coordinates |
| Command-Shift-V | Paste coordinates to selected photos |

Coordinates are entered as latitude, longitude. Conversion and setting locations write to the Photos library. Map display settings do not change saved coordinates. The coordinate conversion uses an approximate regional boundary; verify results for border regions and different map providers.

For a read-only session, run `open -n PhotoCoordinates.app --args --read-only`. Some user-created smart albums may not be exposed by PhotoKit. Local ad-hoc signing is used for builds; distribution requires an appropriate signing and notarization setup.

## Languages

The interface supports English, Japanese, French, German, and Simplified Chinese. It follows the macOS preferred language; English is the fallback for unsupported languages. Change the app language in macOS System Settings, or change the system language and restart the app.
