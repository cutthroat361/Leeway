# Leeway

Your Claude usage limits in the Mac menu bar, so you don't have to open claude.ai Settings > Usage to see how much you have left.

Leeway shows the same numbers as that page: the current 5-hour session and the weekly limit, each with its reset time. It also tells you when you're on pace to run out before a limit resets.

Runs on macOS 11 Big Sur and newer, on both Apple Silicon and Intel Macs (one universal app).

## What you get

- **Five menu bar styles.** `12% | 48%` used, `88% | 52% left`, two mini bars, `12% ↻ 3h 49m` (session plus time until it resets), or the session alone. Optional gauge icon. Numbers turn orange at 75% and red at 90%.
- **Three ways to connect.** Reuse the Claude Code login already on your Mac, sign in to claude.ai in a small built-in window, or paste a `sessionKey` cookie.
- **Pace tick.** Each bar has a thin tick showing how much of the window has passed. Fill to the left of the tick means you're under pace. If you're on track to run out early, the popover says when, for example "Runs out around Thu 3:10 PM".
- **Alerts.** At 75%, at 90%, when you hit a limit, when you're on pace to run out, and when your session resets after you hit 90%. Each fires once per limit window.
- **History chart.** Session and weekly usage over the last 24 hours, 7 days or 30 days.
- **Open at login**, refresh every 1 to 30 minutes, plus an extra refresh when your Mac wakes up. Right-click the menu bar item for Refresh, Settings and Quit.

## Install

You need Apple's command line tools. If you use Homebrew you already have them. If not, run `xcode-select --install` once.

In Terminal, from the Leeway folder:

```bash
bash build.sh --install
```

That compiles the app for Apple Silicon and Intel, copies it to `/Applications`, and opens it. Look for the gauge in your menu bar.

## Connect your account

The first time it opens, Leeway picks a method for you: your Claude Code login if it finds one, otherwise the sign-in window. Change it any time in Settings > Account.

**Use my Claude Code login.** If you've signed in to Claude Code on this Mac, there's nothing to do. Leeway reads the login Claude Code saved and never changes it, so Claude Code keeps working normally. If the login expires, run `claude` once and it renews.

**Sign in with a claude.ai window.** Click Sign in to Claude and sign in the way you normally do. The window closes by itself once you're in. If Google sign-in is blocked inside the window, choose Continue with email and type the code from the email.

**Paste a session key.** For people who prefer to copy it themselves:

1. Open claude.ai in your browser and sign in.
2. Open the developer tools with Cmd+Option+I. In Safari, first turn on Settings > Advanced > Show features for web developers.
3. Go to Application (Chrome, Edge) or Storage (Safari, Firefox), then Cookies, then `https://claude.ai`.
4. Copy the value of `sessionKey` and paste it into Settings > Account.

If your account belongs to more than one organization (for example a Team org and a personal one), Leeway uses the first one that has usage limits. You can switch in Settings > Account.

## Sharing it with other people

`build.sh` signs the app for your own Mac only. That's fine for you and for anyone who builds it themselves. If you send the built app to someone else, macOS will block it the first time. They can still open it from System Settings > Privacy & Security > Open Anyway, but it's not a smooth experience.

For a clean install on anyone's Mac, sign and notarize it with an Apple Developer ID (the Apple Developer Program costs $99 a year):

```bash
# one time: save your notarization login in the Keychain
xcrun notarytool store-credentials leeway --apple-id you@example.com --team-id TEAMID

# each release
VERSION=1.0.0 \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=leeway \
bash build.sh
```

The zip in `build/` is then ready to put on a website or a GitHub release.

### GitHub releases

`.github/workflows/release.yml` builds the universal app on GitHub's Macs. Push a tag such as `v1.0.0` and the zip is attached to a new release. Those builds are unsigned until you add your Developer ID to the workflow.

## Privacy

- Your claude.ai session is stored in the macOS Keychain. The Claude Code login is read from where Claude Code keeps it and is never copied or changed.
- Requests go only to `claude.ai` and `api.anthropic.com`.
- History stays on your Mac in `~/Library/Application Support/Leeway/history.json`. Clear it in Settings > General.
- No analytics and no tracking.

## Troubleshooting

**"Your claude.ai sign-in has expired."** Open Settings > Account and sign in again, or paste a fresh session key.

**"Claude Code's login has expired."** Run `claude` in Terminal once, then click refresh in Leeway.

**macOS asks Leeway for permission to use the Keychain.** Click Always Allow. When you build from source, this can come back after a rebuild because each build has a new signature.

**No notifications.** Open Settings > Alerts and click Send a test notification. If nothing shows up, turn on notifications for Leeway in System Settings > Notifications.

**Launch at login doesn't stick.** Make sure Leeway is in `/Applications`, then turn the option off and on again.

**The numbers stopped updating after an Anthropic update.** Leeway reads an unofficial endpoint, the same one the claude.ai usage page uses. If its format changes, Leeway needs an update.

## Credits

Ideas borrowed from two open-source projects: [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) by Hamed Elfayome (sign-in options, Keychain storage) and [Claude Usage Bar](https://github.com/Blimp-Labs/claude-usage-bar) by Blimp Labs (mini bars, history chart). Leeway's code is written from scratch.

## Disclaimer

Leeway isn't made by, affiliated with, or endorsed by Anthropic. Claude is a trademark of Anthropic PBC.

MIT License.
