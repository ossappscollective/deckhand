#!/bin/bash
# Writes Casks/deckhand.rb for a published release.
#
#   update-cask.sh VERSION SHA256_OF_THE_ZIP
#
# The cask lives in this repository, so `brew tap ossappscollective/deckhand https://github.com/ossappscollective/deckhand`
# is all a user needs, and the release workflow needs no token for a second repository.
set -euo pipefail

version="${1:?usage: update-cask.sh VERSION SHA256}"
sha256="${2:?usage: update-cask.sh VERSION SHA256}"
root="$(cd "$(dirname "$0")/../.." && pwd)"

mkdir -p "$root/Casks"
cat > "$root/Casks/deckhand.rb" <<CASK
cask "deckhand" do
  version "$version"
  sha256 "$sha256"

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
CASK
echo "Casks/deckhand.rb -> $version"
