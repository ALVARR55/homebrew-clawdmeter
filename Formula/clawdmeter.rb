# Homebrew formula for the Clawdmeter macOS daemon.
#
# url / sha256 are rewritten by .github/workflows/update-formula.yml whenever
# ALVARR55/Clawdmeter publishes a new release — edit them by hand only to pin
# a specific version (Homebrew reads the version from the URL's tag). The
# tarball is the release's clawdmeter-daemon-macos.tar.gz (daemon + flasher;
# the firmware images are separate release assets that `clawdmeter-flash`
# downloads on demand).
class Clawdmeter < Formula
  desc "Desk-side Claude Code usage monitor: BLE daemon for the Clawdmeter ESP32 display"
  homepage "https://github.com/ALVARR55/Clawdmeter"
  url "https://github.com/ALVARR55/Clawdmeter/releases/download/v0.3.0/clawdmeter-daemon-macos.tar.gz"
  sha256 "543d2df3170b1bea0979b43d60390ea1f47217c58ec897efdcb1358e0c6e510a"

  depends_on :macos
  depends_on "python@3.12"

  def install
    # bleak (CoreBluetooth via pyobjc) + httpx for the daemon, resolved from
    # PyPI at install time — a personal-tap tradeoff over pinning ~a dozen
    # transitive pyobjc `resource` blocks that would go stale faster than the
    # daemon does.
    #
    # Plain venv + pip on purpose, not Homebrew's virtualenv_create/pip_install:
    # that helper forces `--no-binary :all:` (build every package from sdist),
    # and bleak's build backend (uv_build, Rust) and the pyobjc CoreBluetooth
    # bindings aren't realistically buildable from source here. PyPI ships
    # them as wheels; use the wheels. opt_bin keeps the venv's interpreter
    # symlink valid across python@3.12 patch upgrades.
    #
    # truststore lets the daemon verify TLS against the macOS Keychain, so it
    # works behind corporate TLS-inspecting proxies (Zscaler etc.).
    #
    # esptool is deliberately NOT installed here: flash-release.sh pip-installs
    # it into this venv on first use. Its bitstring->tibs dependency ships a
    # Rust-built .so whose Mach-O header has no room for Homebrew's install-name
    # rewrite, so installing it at build time makes `brew install` print a
    # (harmless) "Failed changing dylib ID" error. A runtime install happens
    # after Homebrew's relocation pass, so it never trips that.
    python = formula_opt_bin("python@3.12")/"python3.12"
    system python, "-m", "venv", libexec
    system libexec/"bin/pip", "install", "--quiet", "--upgrade", "pip"
    system libexec/"bin/pip", "install", "--quiet", "bleak>=0.22", "httpx>=0.27", "truststore>=0.9",
           "pystray>=0.19", "pillow>=10"

    # menubar_macos.py + icon_assets.py + logo_80.png: the menu-bar status icon
    # (menubar = off in the config runs headless). All flat in libexec so the
    # daemon's sibling imports and logo lookup work.
    libexec.install "daemon/claude_usage_daemon.py", "daemon/menubar_macos.py",
                    "daemon/icon_assets.py", "daemon/config.example",
                    "assets/logo_80.png", "flash-release.sh"

    (bin/"clawdmeter-daemon").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" "#{libexec}/claude_usage_daemon.py" "$@"
    SH
    (bin/"clawdmeter-flash").write <<~SH
      #!/bin/bash
      # Point flash-release.sh at this formula's venv; it pip-installs esptool
      # there on first use (see the install step for why not at build time).
      export CLAWDMETER_PYTHON="#{libexec}/bin/python"
      exec "#{libexec}/flash-release.sh" "$@"
    SH
    # One-time setup after `brew install`: a formula can't start services or
    # prompt for permissions during install, so this script starts the login
    # service and watches its log for the Bluetooth outcome. The permission
    # belongs to the process macOS holds "responsible", and a launchd service
    # is responsible for itself — so the "Python may use Bluetooth?" prompt
    # appears here, as the service starts. (Running the daemon from Terminal
    # first would only grant Terminal.) Safe to re-run; it restarts the service.
    (bin/"clawdmeter-setup").write <<~SH
      #!/bin/bash
      set -u
      log="#{var}/log/clawdmeter.log"
      echo "Clawdmeter setup: starting the login service."
      echo "If macOS asks whether \"Python\" may use Bluetooth, click Allow (one time)."
      off=$(stat -f %z "$log" 2>/dev/null || echo 0)
      brew services restart clawdmeter >/dev/null
      verdict=""
      for _ in $(seq 1 45); do
        new=$(tail -c +$((off + 1)) "$log" 2>/dev/null || true)
        if printf '%s' "$new" | grep -qE "Found system-connected|Device not held by OS|Connected$"; then
          verdict=ok; break
        fi
        if printf '%s' "$new" | grep -q "CoreBluetooth unavailable"; then
          verdict=denied; break
        fi
        sleep 1
      done
      case "$verdict" in
        ok)     echo "Bluetooth OK." ;;
        denied) echo "Bluetooth is denied or switched off. Enable 'Python' under System Settings >"
                echo "Privacy & Security > Bluetooth (or turn Bluetooth on); the service retries by itself." ;;
        *)      echo "No Bluetooth response after 45 s. If a permission prompt is showing, click Allow;"
                echo "the service keeps retrying on its own. Log: $log" ;;
      esac
      echo ""
      echo "A Clawdmeter icon is now in the menu bar (amber until a board connects)."
      echo "Pair the board: System Settings -> Bluetooth -> Connect \"Clawdmeter\"."
      echo "Make sure Claude Code is logged in on this Mac (claude auth login)."
    SH
    chmod 0755, bin/"clawdmeter-daemon"
    chmod 0755, bin/"clawdmeter-flash"
    chmod 0755, bin/"clawdmeter-setup"
  end

  # Login service, same shape as the checkout install's LaunchAgent: start at
  # login, restart if it crashes — but NOT after a clean exit, so "Quit" in the
  # menu-bar icon actually stays quit until the next login.
  # Logs go to $(brew --prefix)/var/log/clawdmeter.log.
  service do
    run [opt_bin/"clawdmeter-daemon"]
    keep_alive successful_exit: false
    log_path var/"log/clawdmeter.log"
    error_log_path var/"log/clawdmeter.log"
    environment_variables PATH: std_service_path_env
  end

  def caveats
    <<~EOS
      Finish setup with one command — it starts the login service (auto-starts,
      restarts on failure) and reports whether Bluetooth is reachable. Click
      Allow when macOS asks whether "Python" may use Bluetooth:
        clawdmeter-setup

      A Clawdmeter icon appears in the menu bar: green = board receiving data,
      amber = waiting for the board, red = Claude Code not logged in. Set
      `menubar = off` in ~/.config/claude-usage-monitor/config to run headless.

      Pair the board: System Settings -> Bluetooth -> Connect "Clawdmeter".
      The daemon reads your Claude Code login from the Keychain, so `claude`
      must be logged in on this Mac; it posts a notification if that expires.

      Flash a board with the matching release firmware (no PlatformIO needed):
        clawdmeter-flash waveshare_amoled_216_c6 --name Ricardo   # no args lists boards
      --name gives the board a unique Bluetooth name (Clawdmeter-Ricardo); rename
      later with `clawdmeter-flash --name <suffix>`.

      If you previously installed from a checkout or the release tarball, stop
      that LaunchAgent so two daemons don't fight over the board:
        launchctl unload ~/Library/LaunchAgents/com.user.claude-usage-daemon.plist

      Optional: `brew install blueutil` lets the daemon recover a stale BLE bond
      by itself after a firmware reflash.
    EOS
  end

  test do
    system libexec/"bin/python", "-c", "import bleak, httpx, pystray, PIL, truststore"
    assert_predicate bin/"clawdmeter-setup", :executable?
    assert_predicate libexec/"menubar_macos.py", :exist?
    assert_predicate libexec/"logo_80.png", :exist?
    assert_match "Usage:", shell_output("#{bin}/clawdmeter-flash 2>&1", 1)
    assert_match "waveshare_amoled_216_c6", shell_output("#{bin}/clawdmeter-flash 2>&1", 1)
  end
end
