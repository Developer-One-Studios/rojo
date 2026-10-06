# Syncing with Rojo in Team Create

This fork lets several people sync into the same Team Create place at the same time. Upstream Rojo only allows one person at a time, because two people syncing different copies of a project would undo each other's work.

## Setup

Everyone on the team needs both halves of this fork:

1. **The server.** Build it with `cargo install --git https://github.com/Developer-One-Studios/rojo rojo`, or download it from this repository's releases. `rojo --version` should print a version ending in `-tc.N`.
2. **The plugin.** Run `rojo plugin install` with the fork's server, then restart Roblox Studio.

Then work as usual: clone the project's repository, run `rojo serve`, and connect from the plugin. In a Team Create place, the plugin turns on Team Create mode by itself.

If the plugin is connected to a regular Rojo server while in Team Create, it refuses to connect, because it can't protect your teammates' work without the fork's server.

## What it does

Each person's plugin keeps a ledger in the place, in `ServerStorage.__RojoTeamCreate`. It records who last synced each instance and a fingerprint of what they synced. Fingerprints come from the Rojo server and only depend on what the instance contains: its name, class, and properties. Line endings are ignored, so the same file gives the same fingerprint on everyone's computer, Windows or Mac.

The ledger is saved with the place, so the protection holds even if your teammates have closed Studio. It sits in ServerStorage, so it never reaches players' clients. Records older than 30 days are cleaned up over time.

### Connecting

When you connect, Rojo compares your files with the place as usual. Before applying anything, it checks the ledger. A change is held back when a teammate synced that instance more recently, and their version is different from anything you've synced or seen yourself:

| Rojo wants to... | ...but a teammate | So Rojo assumes |
| --- | --- | --- |
| change an instance | synced a different version | your files are behind theirs |
| remove an instance | synced it, or something inside it | it's new, and you haven't pulled it yet |
| add an instance | removed it | you haven't pulled the removal yet |
| add an instance | synced something else with that name, like their version with a different class | you haven't pulled their change yet |

Held back changes are listed in the connect dialog:

- **Accept** syncs everything else and keeps your teammates' versions.
- **Overwrite** also replaces the listed teammates' versions with your files. Anything a teammate synced while the dialog was open still gets checked.

Pull your teammates' changes (for example with `git pull`) to get your files up to date. Rojo notices when your files match what a teammate synced, and stops treating it as a conflict.

### While connected

Saving a file that a teammate changed more recently, without having their version, holds the change back and shows a notification:

- **Keep Theirs** leaves their version in the place. Pull their changes, then save again.
- **Overwrite** applies your version.

Held back changes also show up as changes that couldn't be applied in the Rojo panel.

Rojo also handles these situations:

- **A teammate already created what you're adding.** For example, you both pulled the same new file. Rojo takes over their instance instead of creating a duplicate.
- **Two people add the same thing at the same moment.** Both plugins briefly create a copy. Shortly after, the person with the higher Roblox user ID removes theirs, so exactly one copy is left.
- **A teammate removed something you're still editing.** Your change brings it back, after asking.

### Who's syncing

The Rojo panel lists everyone else syncing to the place. You get a notification when someone starts or stops syncing, or when someone is syncing a different project.

Unmodified Rojo plugins can't sync safely alongside other people. They only stay out of a place while someone holds their sync lock, so while anyone is syncing with this fork, one of you holds that lock. If someone was already syncing with an unmodified plugin before you connected, you get a warning, since their sync can still overwrite your work.

## Settings

- **Team Create Mode**
  - `Auto` (default): on whenever the place is open in Team Create.
  - `Always`: on in every place.
  - `Never`: behaves like upstream Rojo, so only one person can sync at a time.
- **Teammate Conflicts** controls what happens to changes that would overwrite a teammate's newer work.
  - `Ask` (default): hold them back and ask. If notifications are turned off, there's nowhere to ask, so it keeps your teammates' versions.
  - `Skip`: always keep the teammate's version.
  - `Overwrite`: always use your files, like upstream Rojo.

## Limitations

- **Pulled, then edited offline.** If you pull a teammate's change, edit the same file while disconnected, and then connect, Rojo can't tell your edit apart from an out-of-date file. It lists the file as a conflict, and you choose **Overwrite**.
- **Two-way sync.** If you have two-way sync on, changes your teammates sync into the place are also written into your files.
- **Duplicate names.** Instances that share a name with a sibling can't be told apart between computers, so they're synced like upstream Rojo, without conflict protection.
- **Everyone needs the fork.** Someone using an unmodified plugin when nobody else is connected can still sync over everyone's work. If their project syncs ServerStorage from files, they also delete the ledger.
