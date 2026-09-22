# homebrew-clawdmeter

Homebrew tap for the macOS daemon of [Clawdmeter](https://github.com/ALVARR55/Clawdmeter) — a desk-side ESP32 display for Claude Code usage. This installs the host-side daemon and a flasher; the board itself is flashed separately (see below).

```bash
brew install ALVARR55/clawdmeter/clawdmeter
clawdmeter-daemon               # once, in the foreground: click Allow on the Bluetooth prompt, then Ctrl-C
brew services start clawdmeter  # login service from here on
```

Then pair the board in **System Settings → Bluetooth → Connect "Clawdmeter"**. The daemon reads your Claude Code login from the Keychain (so `claude` must be logged in on this Mac), polls usage every 60 s, and pushes it to the display over BLE. It posts a notification if the login expires.

Flash a board with the matching release firmware — no PlatformIO needed:

```bash
clawdmeter-flash                          # lists the board envs
clawdmeter-flash waveshare_amoled_216_c6  # downloads the release image and flashes it
```

Logs: `$(brew --prefix)/var/log/clawdmeter.log`. Config: `~/.config/claude-usage-monitor/config` (see `config.example` in the formula's libexec).

## How the formula stays current

`.github/workflows/update-formula.yml` checks the latest Clawdmeter release every 30 minutes (and on demand) and rewrites the formula's `url`, `version`, and `sha256`. Then `brew upgrade clawdmeter` picks it up. The Clawdmeter release workflow triggers the bump immediately when it has a `TAP_TOKEN` secret; without it the schedule handles it.
