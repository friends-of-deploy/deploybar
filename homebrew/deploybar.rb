# Homebrew cask for DeployBar.
#
# This file belongs in your tap repository, NOT in the app repo:
#   friends-of-deploy/homebrew-tap  ->  Casks/deploybar.rb
#
# Once published there, users install with:
#   brew install --cask friends-of-deploy/tap/deploybar
#
# The `version` and `sha256` below are placeholders. They are filled in
# automatically by the "Bump Homebrew cask" step in .github/workflows/release.yml,
# or you can edit them by hand from the values printed in the release job summary.
cask "deploybar" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/friends-of-deploy/deploybar/releases/download/v#{version}/DeployBar-#{version}.dmg"
  name "DeployBar"
  desc "Menu bar app for monitoring Vercel deployments"
  homepage "https://github.com/friends-of-deploy/deploybar"

  depends_on macos: :sonoma

  app "DeployBar.app"

  zap trash: [
    "~/Library/Application Support/io.eightlines.deploybar.DeployBar",
    "~/Library/Caches/DeployBar",
    "~/Library/Caches/io.eightlines.deploybar.DeployBar",
    "~/Library/Preferences/io.eightlines.deploybar.DeployBar.plist",
  ]
end
