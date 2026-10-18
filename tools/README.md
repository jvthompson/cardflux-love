# tools/

## build.ps1

Packages a fused Windows build (`build/Cardflux/Cardflux.exe`) and,
optionally, publishes it as a GitHub Release the in-app updater picks up.
See the script's own header comment for the full `-Bump`/`-Publish` flow.

```
powershell -ExecutionPolicy Bypass -File tools\build.ps1
```

## compat_check/

A standalone LÖVE program (its own `conf.lua`, its own entry point --
not part of the test suite and not run by `--test`) that checks a real,
user-owned Cardflux library -- typically the original Flutter app's data
folder -- loads cleanly and re-saves byte-faithfully through this Lua
port. Meant to be run by hand, not in CI; see
[docs/tests-tools.html](../docs/tests-tools.html#compat-check) for the
full rationale and what it checks.

```
lovec tools/compat_check <libraryRoot> [--all-images]
```

where `<libraryRoot>` contains a `game_library/` and a `deck_library/`
subfolder.
