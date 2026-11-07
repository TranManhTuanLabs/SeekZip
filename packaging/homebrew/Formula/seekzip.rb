# Homebrew formula for the SeekZip CLI (M7).
#
# Lives in the tap repo TranManhTuanLabs/homebrew-seekzip as
# Formula/seekzip.rb (with Casks/seekzip.rb next to it for the app).
# Install with: brew tap TranManhTuanLabs/seekzip && brew install seekzip
#
# The sha256 below is a placeholder: fill it with the SHA-256 of the
# v0.2.0 source tarball after the GitHub release is created
# (see docs/RELEASE.md step 7). The formula builds the CLI + MCP
# server from source with SwiftPM — the GUI needs the Xcode project
# and ships in the cask, not here.
class Seekzip < Formula
  desc "Free native macOS archive manager (CLI)"
  homepage "https://github.com/TranManhTuanLabs/SeekZip"
  url "https://github.com/TranManhTuanLabs/SeekZip/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "MIT"

  depends_on xcode: ["16.0", :build]

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/seekzip"
    bin.install ".build/release/seekzip-mcp"
  end

  test do
    # `engines` exits 0 even on a machine with no engines installed.
    system bin/"seekzip", "engines"
  end
end
