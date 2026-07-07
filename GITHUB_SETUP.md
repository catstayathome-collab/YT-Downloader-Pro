# GitHub Private Repository Setup

The local repository is ready for a private GitHub remote.

## Create the repository

Create a private repository named `YT-Downloader-Pro` under your GitHub account or organization.

If GitHub CLI is available:

```bash
gh repo create YT-Downloader-Pro --private --source . --remote origin --push
```

If creating from the GitHub website, add the remote after creation:

```bash
git remote add origin git@github.com:<owner>/YT-Downloader-Pro.git
git push -u origin main
git push origin release/1.8.1 develop/v2.0-swift
git push origin v1.8.0-original v1.8.1
```

## Release rhythm

- Use Git tags for every stable build.
- Attach the packaged `.app` or DMG to GitHub Releases.
- Keep release downloads private unless a public distribution channel is intentionally created.
