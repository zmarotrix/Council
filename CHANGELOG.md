# Changelog

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
