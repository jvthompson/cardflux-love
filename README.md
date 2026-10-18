# CardTable

A desktop virtual tabletop for card games, built with [LÖVE2D](https://love2d.org/)
and written entirely in Lua. Cards, piles, hands, zones and board widgets
(counters, tokens, pack generators, deck-building widgets) can be dragged,
flipped, stacked and shared between players -- on one machine for
practice/hot-seat play, peer-to-peer over LAN/internet with one player
hosting, or through a dedicated lobby server. What a specific game looks
like isn't hard-coded: it's a *game definition* (`gamedef.json` plus a
folder of card images) that ships with the app, is authored/edited in-app,
or is downloaded from a lobby server. One standard 52-card deck ships
built in.

## Running

Requires [LÖVE 11.5](https://love2d.org/) installed, or `love.exe` on
`PATH`.

```
run.bat           start the app
run.bat test      run the Lua test suite in this console
run.bat console   start the app with a console window for print/log output
```

A packaged Windows build (no LÖVE install needed) is published on the
[Releases](https://github.com/jvthompson/cardtable/releases) page;
the app checks for and installs updates to it in place.

## Controls

See [CONTROLS.md](CONTROLS.md).

## Documentation

[docs/index.html](docs/index.html) is a complete, file-by-file map of the
client and its companion server -- what everything is, what it does, and
how it's wired together. Open it directly in a browser.

## Server

[server/README.md](server/README.md) covers the companion Go lobby server
(accounts, chat, server-kept decks, an optional collection/pack-opening
economy). It's a separate git repository, checked out at `server/`.

## Building a release

See [tools/README.md](tools/README.md) -- `tools/build.ps1` packages a
fused Windows build into `build/CardTable/`.

## License

Public domain -- see [LICENSE](LICENSE). CardTable is a solo project; see
[SUPPORT-ME.md](SUPPORT-ME.md) if you'd like to support its development.
