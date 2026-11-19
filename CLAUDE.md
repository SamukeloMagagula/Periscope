# Project instructions — Periscope

## Never expose the developer's environment

This repo is published on GitHub for version control and is public (or may become public).
When writing, committing, or pushing anything in this repo:

- Never commit or push absolute file paths that reveal the developer's username, machine name,
  or local directory layout (e.g. `C:\Users\<name>\...`). Use relative paths or clearly marked
  placeholders (`<absolute-path-to-repo>`) in docs and example config instead.
- Never commit or push API keys, tokens, credentials, `.env` files, or other secrets — check
  file contents before `git add`, even for innocuous-looking filenames.
- Never commit or push real email addresses, personal names, or other personally identifying
  information belonging to the developer or anyone else, in code, commit messages, docs, or
  comments.
- Never commit screenshots, logs, or other artifacts captured from the developer's actual
  machine (e.g. output of the `screenshot` tool, window lists, clipboard contents) — these can
  leak what's on their screen, open files, installed apps, or browsing activity. Sample/demo
  images, if ever needed, must be synthetic or explicitly provided by the user for that purpose.
- Never hardcode or commit the developer's specific install location, home-network details, or
  other local-environment specifics in source, `.mcp.json`, launcher scripts, or README
  examples — keep the repo portable to any machine/user who clones it.

Before any `git add`/`git commit`/`git push` in this repo, re-check staged content against
these rules, not just the filenames.
