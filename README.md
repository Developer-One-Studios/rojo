<div align="center">
    <img src="assets/brand_images/logo-512.png" alt="Rojo" height="217" />
</div>

<div>&nbsp;</div>

# Rojo for Team Create

This is Developer One Studios' version of [Rojo](https://github.com/rojo-rbx/rojo). It lets **several people sync into the same Team Create place at the same time**. Regular Rojo only allows one person at a time.

Each person runs `rojo serve` on their own copy of the project, as usual. When your files would overwrite something a teammate synced more recently, Rojo holds your change back and asks first, instead of quietly undoing their work. How that works is explained in [TEAM_CREATE.md](TEAM_CREATE.md).

This repository is private, and only for Developer One Studios developers.

## Setup

Everyone who syncs needs **both** parts from this repository: the `rojo` server you run in a terminal, and the Studio plugin. They only work together. Mixing them with regular Rojo is covered under [Working with regular Rojo](#working-with-regular-rojo).

### 1. Install the server

#### With Rokit (recommended)

This works once a release has been published on this repository's [Releases](https://github.com/Developer-One-Studios/rojo/releases) page.

1. Because the repository is private, Rokit needs a GitHub token to download it. Create a [personal access token](https://github.com/settings/tokens) that can read this repository: a classic token with the `repo` scope, or a fine-grained token with read access to **Contents** for `Developer-One-Studios/rojo`. Then run:

    ```bash
    rokit authenticate github --token YOUR_TOKEN
    ```

2. In your game project's `rokit.toml`, point `rojo` at this repository instead of `rojo-rbx/rojo`:

    ```toml
    [tools]
    rojo = "Developer-One-Studios/rojo@7.7.1-tc.1"
    ```

    Then install it:

    ```bash
    rokit install
    ```

    If your project doesn't have a `rokit.toml` yet, `rokit add Developer-One-Studios/rojo@7.7.1-tc.1 rojo` creates the entry for you.

3. Check that it worked. This should print a version ending in `-tc.1`:

    ```bash
    rojo --version
    ```

#### By building it yourself

You need [Rust](https://rustup.rs) 1.88 or newer. Clone with `--recursive`, since the plugin's dependencies are submodules:

```bash
git clone --recursive https://github.com/Developer-One-Studios/rojo
```

```bash
cargo install --path rojo --locked
```

This installs `rojo` into `$HOME/.cargo/bin`. If a game project pins Rojo in its `rokit.toml`, typing `rojo` in that project still runs the pinned version, so run this one by its full path:

```bash
$HOME/.cargo/bin/rojo serve
```

### 2. Install the Studio plugin

Use the server you just installed to install the matching plugin:

```bash
rojo plugin install
```

Then **restart Roblox Studio**. Studio only loads plugin changes when it starts.

If you also installed Rojo from the Creator Store, uninstall that one in **Plugins → Manage Plugins**, so you don't end up with two Rojo plugins. The Rojo panel should show a version ending in `-tc.1`.

## Using it

1. Open your game's Team Create place in Studio.
2. In your project folder, run:

    ```bash
    rojo serve
    ```

3. Click **Connect** in the Rojo panel.

Team Create mode turns on by itself when the place is open in Team Create. The panel lists anyone else who is syncing, under the project name.

### When Rojo asks you something

- **When you connect**, if your files are behind what teammates have synced, the connect dialog lists the changes that would undo their work:
  - **Accept** syncs everything else and keeps your teammates' versions.
  - **Overwrite** replaces them with your files.
- **While you're connected**, if you save a file that a teammate changed more recently, and you don't have their version, a notification appears:
  - **Keep Theirs** leaves their version in the place.
  - **Overwrite** syncs yours.

In both cases, the usual fix is to pull your teammates' changes with `git pull`, and keep working. Rojo notices when your files catch up, and stops asking.

### Tips

- **Pull often.** Rojo can only warn you about a conflict. Merging two people's edits to the same file still happens in Git.
- **Commit and push what you sync**, so teammates get your changes when they pull.
- **Don't delete `ServerStorage.__RojoTeamCreate`** in the place. It's how everyone's Rojo knows who synced what. It's small, and never reaches players.

### Settings

These are in the Rojo panel's settings.

- **Team Create Mode**
  - `Auto` (default): turns on when the place is open in Team Create.
  - `Always`: turns on in every place.
  - `Never`: makes this plugin behave exactly like regular Rojo, so only one person can sync at a time.
- **Teammate Conflicts** controls what happens to changes that would overwrite a teammate's newer work.
  - `Ask` (default): hold them back and ask.
  - `Skip`: always keep the teammate's version.
  - `Overwrite`: always use your files.

## Working with regular Rojo

People on regular Rojo can open the same place, but they can't sync at the same time as people using this version:

- **While anyone is syncing with this version,** regular Rojo plugins are blocked from connecting. One of you holds regular Rojo's one-person lock on everyone's behalf.
- **If someone with regular Rojo is already syncing when you connect,** you can still connect, and you'll get a warning. Their plugin doesn't take part in conflict checks, so their sync can undo your work, and yours can undo theirs.
- **This plugin won't connect to a regular Rojo server** in Team Create, because it can't protect your teammates' work without this server. Set **Team Create Mode** to `Never` if you need to.
- **The regular plugin can connect to this server**, and behaves like regular Rojo.

To sync at the same time safely, everyone needs this version.

## Updating

When a new version is released, change the version in your `rokit.toml` (or pull and rebuild), run `rojo plugin install` again, and restart Studio. Because this repository is private, the plugin can't check for updates itself, so keep an eye on the Releases page.

## About Rojo

Rojo lets Roblox developers work on their games with professional tools like **Visual Studio Code** and **Git**. Scripts and models live on the filesystem, in your favorite editor, and Rojo syncs them into Studio in real time. It can also build places and models from the command line, and pull instances from existing places back into a project with `rojo syncback`.

Everything regular Rojo does still works here. Its [documentation](https://rojo.space/docs) applies to this version too.

This version is based on Rojo 7.7.1. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

Rojo is available under the terms of the Mozilla Public License, Version 2.0. See [LICENSE.txt](LICENSE.txt) for details.
