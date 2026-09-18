# Codex LB Status

A native macOS menu bar companion for [codex-lb](https://github.com/Soju06/codex-lb). It keeps the existing dashboard API contract and presents connected accounts in a native `NSMenu` hosted by the status item: grouped translucent cards, system typography, restrained colour, and clear hierarchy. AppKit owns menu anchoring, animation, keyboard handling, and dismissal.

## What it shows

- The average 5-hour percentage in the menu bar itself (weekly average is shown in the menu).
- Every connected Codex LB account, including status and email/account identity.
- 5-hour, weekly, and monthly progress bars with colour-coded remaining capacity.
- Relative reset times such as `Reset in 2d 4h` rather than calendar dates.
- Warm-up state, optional attempt counts, and the latest warm-up result.
- Automatic refresh every 60 seconds and an immediate refresh button.
- Native menu-row hover states and account links that open the selected account in `/accounts?selected=…`.
- Native bottom-menu commands for opening the dashboard, configuring the server (including optional password authentication), launch-at-login, and quit.

The menu also includes native AppKit commands for the dashboard, server URL configuration, login, and quit. It is read-only with respect to account state, so it cannot accidentally pause or mutate a connected account.

## Build and run

Requires macOS 13 or later and Xcode command-line tools:

```bash
./script/build_and_run.sh
```

The default server is `http://127.0.0.1:2455`. Use the ellipsis menu at the bottom of the status menu to change it or log in.
