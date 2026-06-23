# Homebrew cask for VercelBar.
#
# This file belongs in your tap repository, NOT in the app repo:
#   RadnoK/homebrew-tap  ->  Casks/vercelbar.rb
#
# Once published there, users install with:
#   brew install --cask RadnoK/tap/vercelbar
#
# The `version` and `sha256` below are placeholders. They are filled in
# automatically by the "Bump Homebrew cask" step in .github/workflows/release.yml,
# or you can edit them by hand from the values printed in the release job summary.
cask "vercelbar" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/RadnoK/vercelbar/releases/download/v#{version}/VercelBar-#{version}.dmg"
  name "VercelBar"
  desc "Menu bar app for monitoring Vercel deployments"
  homepage "https://github.com/RadnoK/vercelbar"

  depends_on macos: :sonoma

  app "VercelBar.app"

  zap trash: [
    "~/Library/Application Support/io.eightlines.vercelbar.VercelBar",
    "~/Library/Caches/io.eightlines.vercelbar.VercelBar",
    "~/Library/Preferences/io.eightlines.vercelbar.VercelBar.plist",
  ]
end
