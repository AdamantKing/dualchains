# Dual Chains

**NOT APPROVED FOR USE ON CATSEYEXI**

Two characters on one computer, both running Ashita, use weapon skills in order to make a skillchain. That is all it does. It does not engage enemies or use abilities. 

- One character is the **Leader**, the other the **Follower** (set it in the window or with `/dc role lead|follow`).
- When both are armed, engaged, in the same zone and have their set TP, the leader uses its weapon skill. The follower assists, sees the leader's TP drop, waits a configurable delay and uses its own weapon skill.
- The clients talk through small status files in `<Ashita>\config\addons\dualchains\` - no network setup. Both clients must run from the same Ashita install.

## Install

1. Make sure no older copy of the addon is loaded (`/addon unload dualchains`).
2. Clone (or download and unzip) this repository into your Ashita addons folder, **in a folder named `dualchains`**:
   ```
   cd <Ashita>\addons
   git clone https://github.com/Adamantking/dualchains.git dualchains
   ```
3. In game: `/addon load dualchains`  (add it to your default script to load it on startup).

> Everything here is tested to the best of my ability, changes/fixes will be made as necessary.
> Claude was used heavily in the creation of this addon.

Load it on **both** clients, give them opposite roles, pick each character's weapon skill and TP, and arm both. `/dc` opens the window.

## Commands

`/dc` (window), `/dc role`, `/dc ws <name>`, `/dc tp <1000-3000>`, `/dc on|off`, `/dc go`, `/dc delay <sec>`, `/dc assist on|off`, `/dc status`, `/dc help`.

## Notes

This automates actions on two clients, which some servers prohibit. Read your server's rules first. The shared-file idea follows [seekey13/Sidekick](https://github.com/seekey13/Sidekick) (MIT).

## 1.1.0 additions
- **Aurora look** and a **font scale slider** (25-150%) at the bottom right of the window. The scale is remembered in `config\addons\dualchains\ui.cfg`. Not tested in game.
