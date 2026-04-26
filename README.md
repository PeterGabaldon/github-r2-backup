# github-r2-backup

Simple Ubuntu/WSL/VPS-friendly backup wrapper for backing up a GitHub user or organization to Cloudflare R2.

It uses existing tools instead of a custom GitHub exporter:

- [`github-backup`](https://github.com/josegonzalez/python-github-backup) for GitHub data.
- [`gh`](https://cli.github.com/) for repository discovery.
- [`restic`](https://restic.net/) for encrypted, deduplicated, incremental upload to Cloudflare R2 via its S3-compatible API.

## How this version saves disk space

The script does **not** keep a full local backup tree.

Instead it works item by item:

1. Back up account-level metadata into a local staging directory.
2. Upload that staging directory to Cloudflare R2 through Restic.
3. Delete that staging directory after the Restic upload succeeds.
4. Discover repositories with `gh repo list`.
5. Back up one repository at a time using `github-backup --repository <name>`.
6. Upload that repository item to R2.
7. Delete that repository's local staging directory.
8. Back up owned and starred gists as a separate item.
9. Apply Restic retention and run an optional Restic check.

This means local disk usage is roughly the size of the largest single active item, plus temporary tool overhead, instead of the size of your whole GitHub account.

## What gets backed up

Repository items include:

- Public and private repositories.
- Forked repositories.
- Bare/mirror repository clones.
- Git LFS objects.
- Wikis.
- Issues, issue comments, and issue events.
- Pull requests, pull request comments, pull request commits, and pull request details.
- Labels and milestones.
- Hooks, when the token has enough permissions.
- Security advisories, when the token has enough permissions.
- Releases and release assets.
- User attachments from issues and pull requests.

Account metadata item includes:

- Starred repository metadata.
- Watched repositories metadata.
- Followers and following metadata.

Gist item includes:

- Owned gists.
- Starred gists.

Gists are user-owned on GitHub. If `GITHUB_ACCOUNT_TYPE=org`, the script skips the gist item.

By default, the script does **not** clone every starred repository because that can download a huge amount of third-party data. To enable that, set:

```bash
GITHUB_BACKUP_INCLUDE_STARRED_REPOSITORY_CLONES=true
```

Important: `github-backup` does not expose a per-starred-repo filter, so starred repository clones are handled as one cleanup unit.

## Important restore limitation

Git repositories, wikis, and gists can be restored by pushing the Git data back to GitHub.

Issues, PRs, comments, labels, milestones, hooks, release metadata, etc. are archived as JSON/files. GitHub does not allow a perfect recreation of some metadata such as original issue numbers, timestamps, authors, and cross-references.

## Requirements

This repository is intended for Ubuntu, including Ubuntu on WSL or a Linux VPS.

Install system dependencies:

```bash
sudo apt update
sudo apt install -y git git-lfs python3-pip pipx restic gh
pipx ensurepath
```

If your distribution does not provide a recent `gh` package, install GitHub CLI using the official instructions: <https://github.com/cli/cli/blob/trunk/docs/install_linux.md>

Close and reopen your shell, or run:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Install `github-backup`:

```bash
pipx install github-backup
```

Verify tools:

```bash
git --version
git lfs version
gh --version
github-backup --version
restic version
```

## GitHub token

For a complete personal-account backup including gists, use a **classic personal access token** with at least:

- `repo` for private repositories and repository metadata.
- `gist` for gists.
- `read:org` if backing up organization membership/private org resources.
- `admin:repo_hook` if you want to back up repository hooks and your account has permission.

Fine-grained tokens are supported by setting `GITHUB_TOKEN_TYPE=fine`, but they may not cover every endpoint needed for a full account backup, especially gists. For the “everything, even gist” requirement, prefer `classic`.

If the organization uses SAML SSO, authorize the token for that organization after creating it.

## Cloudflare R2 setup

1. Create a private R2 bucket.
2. Create an R2 access key that can read, write, list, and delete objects in that bucket.
3. Note your Cloudflare account ID.
4. Use this Restic repository format:

```bash
RESTIC_REPOSITORY=s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET_NAME>/github-restic
AWS_DEFAULT_REGION=auto
```

The `/github-restic` suffix is just a prefix inside the bucket. You can change it.

## Configure environment variables

Copy the example file:

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env`:

```bash
nano .env
```

Minimum values to set:

```bash
GITHUB_ACCOUNT=your-github-username
GITHUB_ACCOUNT_TYPE=user
GITHUB_TOKEN_TYPE=classic
GITHUB_TOKEN=ghp_replace_me

BACKUP_STAGING_ROOT=$HOME/github-r2-backup-stage
BACKUP_CLEANUP_AFTER_UPLOAD=true

RESTIC_REPOSITORY=s3:https://replace_with_account_id.r2.cloudflarestorage.com/replace_with_bucket_name/github-restic
AWS_ACCESS_KEY_ID=replace_me
AWS_SECRET_ACCESS_KEY=replace_me
AWS_DEFAULT_REGION=auto
RESTIC_PASSWORD=replace_with_a_long_random_password
```

For an organization backup:

```bash
GITHUB_ACCOUNT=your-org-name
GITHUB_ACCOUNT_TYPE=org
```

## First run

Initialize the Restic repository in R2 once:

```bash
./scripts/backup-github-to-r2.sh init
```

Optionally confirm repository discovery:

```bash
./scripts/backup-github-to-r2.sh list-repos
```

Run the backup:

```bash
./scripts/backup-github-to-r2.sh backup
```

List snapshots:

```bash
./scripts/backup-github-to-r2.sh snapshots
```

Check repository integrity:

```bash
./scripts/backup-github-to-r2.sh check
```

## Periodic execution on a VPS

Use cron:

```cron
30 3 * * * cd /home/YOUR_USER/github-r2-backup && ./scripts/backup-github-to-r2.sh backup >> logs/backup.log 2>&1
```

Create the log directory first:

```bash
mkdir -p logs
```

Or use a systemd timer if you prefer system-level scheduling.

## Local disk usage

The script deletes each staging directory only after this command succeeds:

```bash
restic backup <item-staging-directory> ...
```

If `github-backup` or `restic backup` fails, the script stops and keeps the current staging directory for inspection. On the next run, the default setting below removes stale staging before retrying the item:

```bash
BACKUP_DELETE_STALE_STAGE_BEFORE_ITEM=true
```

To keep local staging after successful upload for debugging, set:

```bash
BACKUP_CLEANUP_AFTER_UPLOAD=false
```

## Restic retention

The default retention policy is:

```bash
RESTIC_KEEP_DAILY=14
RESTIC_KEEP_WEEKLY=8
RESTIC_KEEP_MONTHLY=12
RESTIC_RUN_FORGET=true
```

Retention is applied after all item snapshots complete successfully.

Because the staging path for each item is stable, for example:

```text
$HOME/github-r2-backup-stage/repository__OWNER__REPO
$HOME/github-r2-backup-stage/gists__OWNER
```

Restic can group retention by item path across runs while the local directories are still deleted after upload.

## Restore examples

Create a restore directory:

```bash
mkdir -p ~/github-r2-restore
```

Restore the latest snapshot:

```bash
restic restore latest --target ~/github-r2-restore
```

Find repository backups after restore:

```bash
find ~/github-r2-restore -maxdepth 8 -type d -name '*.git'
```

For a bare/mirror repository, push it back to GitHub with:

```bash
cd ~/github-r2-restore/path/to/repository.git
git push --mirror git@github.com:OWNER/REPO.git
```

## WSL note

If you run this from WSL, prefer storing `BACKUP_STAGING_ROOT` under your WSL Linux filesystem, for example:

```bash
BACKUP_STAGING_ROOT=$HOME/github-r2-backup-stage
```

Avoid using `/mnt/c/...` for active Git backup staging unless necessary. Git-heavy workloads are usually more reliable and faster on the Linux filesystem.
