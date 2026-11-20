<p align="center"><img src="icon.png" width="256" alt="Pinax app icon"></p>

# homebrew-pinax

Homebrew tap for Pinax, a self-hosted image catalog for macOS.

```sh
brew install --cask gitkeniwo/pinax/pinax   # the app
brew install gitkeniwo/pinax/pinax          # the pinax command-line tool
```

Pinax is not notarized. macOS blocks the first open of every new version:
open System Settings › Privacy & Security and click "Open Anyway".

Pinax's source, issues and releases are at
[gitkeniwo/pinax](https://github.com/gitkeniwo/pinax). The release workflow
there renders `Casks/`, `Formula/` and this README and pushes them here; do not
edit them by hand. Versions up to 0.3.3 are attached to this repository's
GitHub Releases.
