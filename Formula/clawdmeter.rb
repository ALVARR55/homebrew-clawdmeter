# Homebrew formula for the Clawdmeter macOS daemon.
#
# url / sha256 are rewritten by .github/workflows/update-formula.yml whenever
# ALVARR55/Clawdmeter publishes a new release — edit them by hand only to pin
# a specific version (Homebrew reads the version from the URL's tag). The
# tarball is the release's clawdmeter-daemon-macos.tar.gz (daemon + flasher;
# the firmware images are separate release assets that `clawdmeter-flash`
# downloads on demand).
class Clawdmeter < Formula
  include Language::Python::Virtualenv

  desc "Desk-side Claude Code usage monitor: BLE daemon for the Clawdmeter ESP32 display"
  homepage "https://github.com/ALVARR55/Clawdmeter"
  url "https://github.com/ALVARR55/Clawdmeter/releases/download/v0.1.0/clawdmeter-daemon-macos.tar.gz"
  sha256 "18d5f7e4d4044cbfbac63d783ad2bb00bef04d44f952a5388fc30c34d588b226"

  depends_on :macos
  depends_on "python@3.12"

  def install
    # bleak (CoreBluetooth via pyobjc) + httpx for the daemon, esptool for the
    # flasher. Resolved from PyPI at install time rather than pinned as
    # `resource` blocks: this is a personal tap and the daemon tracks current
    # bleak/httpx releases; pinning ~a dozen transitive pyobjc wheels here
    # would only make the formula go stale faster than the daemon.
    venv = virtualenv_create(libexec, "python3.12")
    venv.pip_install "bleak>=0.22"
    venv.pip_install "httpx>=0.27"
    venv.pip_install "esptool>=5"

    libexec.install "daemon/claude_usage_daemon.py", "daemon/config.example", "flash-release.sh"

    (bin/"clawdmeter-daemon").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/python" "#{libexec}/claude_usage_daemon.py" "$@"
    SH
    (bin/"clawdmeter-flash").write <<~SH
      #!/bin/bash
      # Point flash-release.sh at this formula's venv (it already has esptool).
      export CLAWDMETER_PYTHON="#{libexec}/bin/python"
      exec "#{libexec}/flash-release.sh" "$@"
    SH
    chmod 0755, bin/"clawdmeter-daemon"
    chmod 0755, bin/"clawdmeter-flash"
  end

  # Login service, same shape as the checkout install's LaunchAgent: start at
  # login, restart if it dies. Logs go to $(brew --prefix)/var/log/clawdmeter.log.
  service do
    run [opt_bin/"clawdmeter-daemon"]
    keep_alive true
    log_path var/"log/clawdmeter.log"
    error_log_path var/"log/clawdmeter.log"
    environment_variables PATH: std_service_path_env
  end

  def caveats
    <<~EOS
      macOS only shows the Bluetooth permission prompt for a foreground process,
      so run the daemon once by hand first, click Allow, then Ctrl-C:
        clawdmeter-daemon

      Then start it as a login service (auto-starts, restarts on failure):
        brew services start clawdmeter

      Pair the board: System Settings -> Bluetooth -> Connect "Clawdmeter".
      The daemon reads your Claude Code login from the Keychain, so `claude`
      must be logged in on this Mac; it posts a notification if that expires.

      Flash a board with the matching release firmware (no PlatformIO needed):
        clawdmeter-flash waveshare_amoled_216_c6      # run with no args to list boards

      If you previously installed from a checkout or the release tarball, stop
      that LaunchAgent so two daemons don't fight over the board:
        launchctl unload ~/Library/LaunchAgents/com.user.claude-usage-daemon.plist

      Optional: `brew install blueutil` lets the daemon recover a stale BLE bond
      by itself after a firmware reflash.
    EOS
  end

  test do
    system libexec/"bin/python", "-c", "import bleak, httpx, esptool"
    assert_match "Usage:", shell_output("#{bin}/clawdmeter-flash 2>&1", 1)
    assert_match "waveshare_amoled_216_c6", shell_output("#{bin}/clawdmeter-flash 2>&1", 1)
  end
end
