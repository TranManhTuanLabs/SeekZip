# Homebrew cask for the SeekZip app (M7).
#
# Lives in the tap repo TranManhTuanLabs/homebrew-seekzip as
# Casks/seekzip.rb (with Formula/seekzip.rb next to it for the CLI).
# Install with: brew tap TranManhTuanLabs/seekzip && brew install --cask seekzip
#
# The sha256 below is a placeholder: fill it with the SHA-256 of the
# SeekZip-0.2.0.dmg printed by scripts/release.sh (see
# docs/RELEASE.md step 7). The DMG is built, signed and notarised by
# that script; the cask only downloads and installs it.
cask "seekzip" do
  version "0.2.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/TranManhTuanLabs/SeekZip/releases/download/v0.2.0/SeekZip-0.2.0.dmg"
  name "SeekZip"
  desc "Free native macOS archive manager"
  homepage "https://github.com/TranManhTuanLabs/SeekZip"

  app "SeekZip.app"
end
