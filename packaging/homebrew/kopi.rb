# Template of the Homebrew cask. The release workflow drops these comment lines, fills in the
# version and the DMG's sha256, and pushes it to https://github.com/vodorod-11/homebrew-tap.
cask "kopi" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/vodorod-11/kopi/releases/download/v#{version}/Kopi-#{version}.dmg"
  name "Kopi"
  desc "Clipboard history manager inspired by Ditto"
  homepage "https://github.com/vodorod-11/kopi"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Kopi.app"

  uninstall quit: "io.github.vodorod-11.kopi"

  zap trash: [
    "~/Library/Application Support/Kopi",
    "~/Library/Preferences/io.github.vodorod-11.kopi.plist",
  ]

  caveats <<~EOS
    Kopi is not notarized by Apple. If macOS will not open it the first time, go to
    System Settings > Privacy & Security and click "Open Anyway" next to Kopi.

    Kopi also needs two permissions in System Settings > Privacy & Security:
      Paste from Other Apps: Always Allow (then relaunch Kopi)
      Accessibility: on, so Kopi can paste for you
  EOS
end
