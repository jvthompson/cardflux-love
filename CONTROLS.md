# Cardflux Controls

## Window

| Key | Effect |
|-----|--------|
| F11 | Toggle between the custom title bar and a standard window frame |

## Game table

### Mouse

| Action | Effect |
|--------|--------|
| Drag a card | Move it. A card with others stacked visually on top of it carries them along as a group, including any tokens attached to them. |
| Click a pile (2+ stacked cards) | Draw the top card into your hand |
| Drag a pile | Peel off just the top card |
| Alt + drag a pile | Move the whole pile; dropped on your hand, every card is dealt into it |
| Pile's shuffle button | Shuffle the pile and turn every card face-down |
| Click a player's avatar | Practice games: act as that seat |
| Mouse wheel over the table | Zoom in/out around the cursor |
| Tab + drag on the table | Draw an arrow everyone can see (fades after 5 seconds) |
| Right-click | Context menu (see below) |

**Dropping a dragged card**

- On your hand: adds it to your hand, or reorders it (the drop position decides where).
- On one of your zones: puts it on top of the zone; hold **Alt** to put it on the bottom.
- On a shared pile on the table: stacks onto it.
- Near another loose card with **Alt** held: stacks onto it.
- Anywhere else: moves it on the table.

Opponents' cards, piles and zones are read-only: you can hover them (for the Space preview) but not draw, drag, shuffle or flip them.

### Keyboard

Hotkeys act on the card under the cursor and fire once per key press (holding a key doesn't repeat).

| Key | Effect | Applies to |
|-----|--------|------------|
| Space (hold) | Large preview of the hovered card, showing exactly what you can see of it | Any card |
| F | Flip face-up/face-down | Your table cards, your hand, a shared zone's top card (not your own zones' cards) |
| Q / E | Rotate the card's stack 90° counter-clockwise / clockwise | Your cards on the table |
| X | Send to your discard zone | Your cards on the table, if the game defines a discard pile |
| Z | Bring the card's stack to the front | Your cards on the table |
| 1–9 | Draw that many cards into your hand (1 on a table card moves just that card to hand) | Your piles, your zones and shared zones |
| W / A / S / D (hold) | Pan your own camera | Only your view moves |
| Home or H | Reset camera pan and zoom | |
| F1 | Show/hide the ownership border on every card | This session only |
| F2 | Toggle zone/hand backgrounds between player-color tint and black | This session only |
| F12 | Cycle through the game's playmats | |
| L | Open/close the Game Log (with a Save Log button) | |
| Esc | Open/close the Game Menu (save game, settings, kick a player, leave/end game) | |
| Ctrl (while dropping a token) | Duplicate the token instead of moving it | Token widgets |

### Right-click menus

| Target | Menu |
|--------|------|
| Empty table | **Widgets** (Simple Counter, Token, Pack Generator, Deck Widget when the game has deck-building zones) and **Card Library** |
| Your card | **Send to...** Hand / Discard / a zone (Top, Shuffle Into, Bottom); on the table also **Give to** a player and **Remove Ownership** |
| Your pile | Same as a card, plus **Search...** |
| A zone | **Search...**; an empty zone that deals a built deck also offers **Load Deck...** |
| Simple Counter | Increment / Decrement / Set Value / Set Colors / Delete |
| Token | Set Color / Delete |
| Pack Generator | Open a pack from one of the game's sets / Delete |
| Your Deck Widget | Delete |

### Board widgets

- Drag any widget to move it.
- **Token:** drop it on a card to attach it (it then travels with the card); drop it on empty table to detach it. Hold **Ctrl** while dropping to duplicate it.
- **Simple Counter:** double-click the right half to add 1, the left half to subtract 1.

## Deck Editor

| Action | Effect |
|--------|--------|
| Left-click a card in the pool | Add one copy to the deck |
| Right-click a card in the pool | Remove one copy |
| Click a card in the deck list | Remove one copy |
| Hover | Preview the card |
