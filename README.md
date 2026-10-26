# Codex LB Menu Bar

A native macOS menu bar companion for [codex-lb](https://github.com/Soju06/codex-lb). It keeps the dashboard API contract and uses the same 384-point borderless panel, material, rounded cards, typography, and footer controls as Sonos Bar. The header and footer stay visible while long account lists scroll. Click outside or press Escape to dismiss the panel.

## What it shows

- The average 5-hour percentage in the menu bar itself (weekly average is shown in the menu).
- Every connected Codex LB account, including status and email/account identity.
- 5-hour, weekly, and monthly progress bars with colour-coded remaining capacity.
- Compact quota rows with reset countdowns such as `Resets in 2d 4h` above each progress bar.
- Hovering over an account card shows `Next reset expires in …` for its soonest-expiring available reset. The usual quota countdown stays visible when no reset expiry is available and returns when the pointer leaves.
- A circular reset-count badge sits at the top left of each account avatar. It turns red when the next available reset expires within 72 hours; otherwise it is grey, turning blue on hover. Accounts without resets have no badge.
- An ellipsis menu on each card shows the reset count and opens the existing reset picker, including pending reset retries. It also offers **Pause account** or **Resume account** for paused accounts. Changes refresh the account status, prevent duplicate requests while running, and show failures on the card. Accounts requiring reauthentication or otherwise deactivated cannot be paused here. Clicking the rest of the card opens the account dashboard.
- A full-width **Use next reset** action, which changes to a red confirmation prompt on the first click and spends the soonest-expiring reset on the second click. After success, it shows a disabled green **Reset applied** state; close and reopen the dropdown to use another reset.
- Loading and applying indicators, plus safe retries that reuse the same request ID after a timeout or app restart.
- The latest warm-up result when provided by the server.
- Automatic refresh every 60 seconds and an immediate refresh button.
- Rounded account cards with hover states and account links that open the selected account in `/accounts?selected=…`.
- Footer buttons for Settings, Dashboard, Refresh, and Quit. Settings contains server configuration, launch-at-login, and update checks.
- GitHub Releases update checks with an install-and-relaunch action when a newer version is available.

Viewing reset credits is read-only. Applying a reset requires dashboard write access and explicit confirmation. The server selects the next available reset to expire; individual credits are informational rows. If a request times out, **Retry same reset** checks the original operation instead of spending another credit. Pending request IDs are stored per server and account in preferences; credentials remain in Keychain.

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

Run the logic, dropdown placement, reset-expiry, and mocked reset/account-action checks with:

```bash
./script/test.sh
```

The reset and account-action tests use fake APIs and never spend live credits or change live accounts.

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
