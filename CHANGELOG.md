# Changelog

## 0.2.0

- Changed the backup flow to process one item at a time.
- Added repository discovery through GitHub CLI.
- Added one-repository-at-a-time backup using `github-backup --repository`.
- Added separate cleanup units for account metadata, repositories, gists, and optional starred repository clones.
- Added automatic local staging deletion after each successful Restic upload.
- Added `list-repos` command.
- Added staging-related environment variables.

## 0.1.0

- Initial WSL-friendly GitHub to Cloudflare R2 backup wrapper.
