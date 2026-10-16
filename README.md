# Codex LB Menu Bar

A native macOS menu bar companion for [codex-lb](https://github.com/Soju06/codex-lb). It keeps the dashboard API contract and uses the same 384-point borderless panel, material, rounded cards, typography, and footer controls as Sonos Bar. The header and footer stay visible while long account lists scroll. Click outside or press Escape to dismiss the panel.

## What it shows

- The average 5-hour percentage in the menu bar itself (weekly average is shown in the menu).
- Every connected Codex LB account, including status and email/account identity.
- 5-hour, weekly, and monthly progress bars with colour-coded remaining capacity.
- Relative reset times such as `Reset in 2d 4h` rather than calendar dates.
- Warm-up state, optional attempt counts, and the latest warm-up result.
- Automatic refresh every 60 seconds and an immediate refresh button.
- Rounded account cards with hover states and account links that open the selected account in `/accounts?selected=…`.
- Footer buttons for Settings, Dashboard, Refresh, and Quit. Settings contains server configuration, launch-at-login, and update checks.
- GitHub Releases update checks with an install-and-relaunch action when a newer version is available.

The panel is read-only with respect to account state, so it cannot accidentally pause or mutate a connected account.

Dashboard passwords are stored per server in the user's macOS login Keychain,
never in preferences or ordinary files. When the server-side session expires,
the app uses the saved password to establish a new session automatically. The
saved password can be removed from **Config Server…** at any time.

## Build and run

Requires macOS 13 or later and Xcode command-line tools:

```bash
./script/build_and_run.sh
```

The default server is `http://127.0.0.1:2455`. Use **Settings → Config Server…** to change it or log in.

To open the panel immediately for UI inspection, launch the built app with:

```bash
./script/build_and_run.sh --show-panel
```

This inspection mode activates the app and shows a Dock icon. Normal launches remain menu-bar-only.

Run the logic and dropdown placement checks with:

```bash
swiftc StatusBarLogic.swift DropdownPlacement.swift CredentialStore.swift StatusBarLogicTests.swift -framework Security -o build/StatusBarLogicTests
./build/StatusBarLogicTests
```

## Publishing an update

The updater checks the latest release in the repository configured by
`CodexLBUpdateRepository` in `Info.plist` (currently
`benjamindell/codex-lb-menu-bar`). Each release must include an asset named
`CodexLBMenuBar.zip` containing `CodexLBMenuBar.app` at any level inside the
archive. The downloaded app must pass a macOS code-signature check before it
can replace the installed app.

To create the release asset:

```bash
./build.sh
./script/package_release.sh
```

Increase `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`,
then create a GitHub release whose tag is the new semantic version, such as
`v1.1.0`, and upload `dist/CodexLBMenuBar.zip`.
