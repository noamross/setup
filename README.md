# setup

Bootstrap for Noam's dotfiles (private repo `noamross/cheznoam`, managed with chezmoi).

```sh
curl -fsSL https://raw.githubusercontent.com/noamross/setup/main/setup.sh | sh
```

It uses existing GitHub credentials if git already has them. Otherwise it asks to sign in through the browser (GitHub device code, via a GitHub App limited to read access on that one repo, tokens valid 8 hours) or to paste a fine-grained token. The token is never written to disk. Then it clones the repo to `~/.local/share/chezmoi`, installs a pinned, checksummed chezmoi, and applies.

To check the script before running it, download it from a commit URL, read it, then `sh setup.sh`.

Tests live in the private repo (`test/run.sh`, cases `*-bootstrap`), which includes this one as a submodule.
