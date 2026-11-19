# Outch

A World of Warcraft (WoW Forever) addon that tracks what you get from opening a
[Satchel of Potions](https://www.wowhead.com/forever/item=280766/satchel-of-potions).

Each use gives one of:

- [Greater Healing Potion](https://www.wowhead.com/forever/item=1710/greater-healing-potion)
- [Mana Potion](https://www.wowhead.com/forever/item=3827/mana-potion)
- [Swiftness Potion](https://www.wowhead.com/forever/item=2459/swiftness-potion)
- 216 fire damage to yourself (Outch!)

## Install

Copy the `Outch` folder into `World of Warcraft\_forever_\Interface\AddOns\` and `/reload`.

If the addon shows as out of date, run `/dump select(4, GetBuildInfo())` in game and
put that number on the `## Interface:` line of `Outch.toc`, or tick "Load out of date AddOns".

## Usage

- `/outch` prints how many times each outcome has happened:
  ```
  Potion of Healing: x
  Mana Potion: x
  Go fast potion: x
  Outch: x (y damage)
  ```
  `x` is the number of satchels that gave that result; `y` is the running total of
  damage taken from Outches.
- `/outch s` sends the same four lines in /say.
- `/outch p` sends the same four lines to your party.
- `/outch reset` sets all counters back to zero.
- `/outch debug` toggles debug messages showing what the addon sees after each use.

Counts are saved between sessions and shared across all characters on the account.
