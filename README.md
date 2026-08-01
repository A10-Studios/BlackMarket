# BlackMarket

A custom replacement UI for the World of Warcraft **Black Market Auction House** (BMAH).

BlackMarket replaces Blizzard's cramped default frame with a wider, sortable, filterable
list, and adds the features the default UI is missing: persistent history, live time-left
estimates, collection tracking, and bid alerts.

## Features

- **Wide, sortable list** – see every auction at a glance with columns for item, time
  left, bid count, and current bid.
- **Time-left estimates** – the BMAH only reports vague brackets (Short / Medium / Long /
  Very Long). BlackMarket records each observation and narrows it into a real countdown
  range that ticks down second-by-second, including 5-minute snipe-protection handling.
- **Bid alerts** – get a sound and a taskbar flash when you're outbid or when you win an
  auction, even while tabbed out of the game.
- **Collection tracking** – icons show whether you already know an appearance/mount/pet,
  and whether it's Bind-on-Equip, Bind-on-Pickup, or Warbound.
- **Watch list** – star the auctions you care about.
- **Cross-session history** – auctions you've seen are remembered per realm, so you can
  review them later with `/bm` from anywhere.

## Slash Commands

| Command | Description |
| --- | --- |
| `/bm` | Open the BlackMarket window from anywhere |
| `/bmreset` | Reset the window position/size |
| `/bmreset history` | Wipe all saved auction history |

## Installation

1. Download the latest release.
2. Extract the `BlackMarket` folder into `World of Warcraft\_retail_\Interface\AddOns\`.
3. Restart the game or reload your UI (`/reload`).

## License

See [LICENSE](LICENSE).
