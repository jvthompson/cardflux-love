-- App version. `build` is compared against GitHub release tags ("+N") by
-- the updater; the LÖVE port numbers its builds independently of Flutter's,
-- so it must publish to its own repo (the Flutter repo's build numbers
-- would always look newer).
return {
  name = "0.1.0",
  build = 4,
  -- src/platform/updater.lua: where releases are published, the zip asset
  -- each release must carry, and the executable inside it.
  releaseRepo = "jvthompson/cardflux-love",
  releaseAssetName = "cardflux-windows.zip",
  exeName = "Cardflux.exe",
}
