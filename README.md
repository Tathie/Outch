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

## How it works

WoW Forever runs on the modern client, where addons can't read the combat log.
The satchel isn't used up; it goes on a 10 minute cooldown, and it makes you drink
the potion on the spot rather than giving you one.

Outch notices the satchel's cooldown starting (or you casting its spell), then
looks for the potion's effect within 5 seconds: you casting the potion's spell, or
as a backup the Swiftness speed buff appearing or a big jump (200+) in your mana or
health. If none of those happens, it counts an Outch and reads the damage from your
own health dropping (falling back to 216 if your health can't be read at that
moment).
