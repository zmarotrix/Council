# Changelog

## 0.3.2 (2026-11-09)

- Asks for Norgannon Core 1.25 or newer, the first Core with everything it uses. An older Core now gets a clear "update Norgannon Core" message instead of errors.

## 0.3.1, 2026-11-07

- Add-on messages now go through NorgannonDB Core 1.21's `Core.Net`, which holds Council's own transport code. Nothing
  changes in game: the same prefix and messages, held through lockdown, and whispers to full names.

## 0.3.0, 2026-11-07

- Built on NorgannonDB Core 1.20: `Core:NewAddon` for the setup, Core's guild roster (read once for the whole suite
  instead of by Council too), `Core.Names` for first names, and Core's row list. Same commands, tabs and records;
  `/council help` now lists every command.
- A whisper to someone Council has only heard of by first name can now use the full name chat has shown.
- The "Show the minimap button" setting is gone: NorgannonDB > Minimap pins any add-on.
- Settings asked for in combat open when the fight ends.

## 0.2.4, 2026-11-06

- **Fixed: "No player named 'Tyrant'" in chat.** Sync whispered people by first name only, which the game can't deliver, so catching up from another
  member failed too. It now uses the full name the game gave it, and doesn't whisper anyone the roster shows as offline.

## 0.2.3, 2026-11-06

- **After the boss, it offers to switch back:** if Council switched you to master loot, then once a boss has died and everything's handed out, a small popup offers the method you had before. It only changes on a click.

## 0.2.2, 2026-11-06

- **Buttons to pick a roll:** Main spec, Off spec and Transmog in the roll popup, or just Roll on a reserved item or a tie, for anyone who can roll on it.
  They make a real `/roll`, so people without the add-on see nothing different.
- **Targeting a boss asks about master loot:** a small popup if you're leading a raid, or a party with a reserve list, and it isn't on. It only ever switches when you click.
- Settings for that question, for showing others' rolls, and for how long a roll lasts.
- The roll popup's item and text are centred.
- Fixed: the read-only roll popup clipped its last row.
- Fixed: a tie at off spec could become main spec, if the re-roll used `/roll`.

## 0.2.0, 2026-11-06

- **Loot runs from small popups now:** a loot list beside the game's loot window, a roll popup with a countdown, a
  player list by class, and a confirmation before giving. The Loot night tab is now Tonight, a read-only list.
- **One roll for everyone:** `/roll`, `/roll 99` and `/roll 98` for main spec, off spec and transmog, at once. It ends early when every reserver has rolled.
- **New:** top rolls win for identical items, raid roll, Say what dropped, "Everyone may roll", and `/council roll [item]` for items in your bags.
- **Fixed, found by /cprobe in a real dungeon:** names like "Arhara Dawnstrider" in loot lines didn't match "Arhara" on the roster, so reserves and witnesses couldn't line up.
- **Fixed, found the same way:** the "add-on chat restricted" flag turned sync off, though add-on messages clearly still arrive. A real test message decides now.
- **If an announcement never shows up in chat,** Council opens the chat box with it ready, so a press of Enter sends it.
- **Fixed:** importing a corrected reserve list mid-raid forgot who'd won, so a winner would earn SR+ at the close.

## 0.1.0, 2026-11-06

Stage 1, the loot night. Passes its harness. Not yet played in the game.

- **A shared record:** append-only, hash-chained per author, replayed the same way on every client. It syncs across the guild in the
  background, and comes back if you lose your files.
- **History:** who got what, by raid, boss or player, in raids and dungeons, with a count of the clients that saw each line.
- **Reserves and SR+:** paste a list, catch what's wrong with it before the pull, and set your guild's own rules.
- **Rolls and master loot:** who's in line and why, ties, the next rule, and giving an item with a click. Group loot is recorded.
- **Attendance and item counts** per player, from the record.
- **Records:** who wrote what, what's verified, what looks wrong, and export or import for a copy of your own.
