cask "deckhand" do
  version "1.1.2"
  sha256 "01bb28b98794d8802717bb17c08dbbc02222e5e7328669f4d2d2869ff2cdec27"

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
