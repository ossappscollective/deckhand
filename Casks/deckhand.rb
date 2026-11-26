cask "deckhand" do
  version "1.1.1"
  sha256 "553e568c7af830105d0fbd47b73cb03c295964f473d0cb3a9089095f0b35eca0"

  url "https://github.com/ossappscollective/deckhand/releases/download/v#{version}/Deckhand-#{version}.zip"
  name "Deckhand"
  desc "Start, mirror, inspect and control iOS Simulators, Android Emulators and devices"
  homepage "https://ossappscollective.github.io/deckhand/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :tahoe"

  app "Deckhand.app"

  zap trash: [
    "~/Library/Application Support/Deckhand",
    "~/Library/Preferences/com.ossappscollective.Deckhand.plist",
    "~/Library/Saved Application State/com.ossappscollective.Deckhand.savedState",
  ]
end
