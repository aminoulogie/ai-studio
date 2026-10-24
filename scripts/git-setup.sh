#!/usr/bin/env bash
# Run from any directory inside this checkout. Never puts credentials in a remote URL.
set -euo pipefail
trap 'printf "Git setup failed at line %s. Your files and commits were kept.\n" "$LINENO" >&2' ERR
command -v gh >/dev/null || { printf "Install GitHub CLI first: brew install gh\n" >&2; exit 1; }
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
branch_name=$(git symbolic-ref --quiet --short HEAD) || { printf "Check out a branch before configuring tracking.\n" >&2; exit 1; }
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git --hostname github.com
permission=$(gh repo view aminoulogie/ai-studio --json viewerPermission --jq .viewerPermission)
case "$permission" in ADMIN|MAINTAIN|WRITE) ;; *)
  printf "The signed-in GitHub account needs write access to aminoulogie/ai-studio.\n" >&2; exit 1;;
esac
if git remote get-url origin >/dev/null 2>&1; then
  origin_url=$(git remote get-url origin)
  case "$origin_url" in
    https://github.com/aminoulogie/ai-studio|https://github.com/aminoulogie/ai-studio.git|git@github.com:aminoulogie/ai-studio.git)
      git remote set-url origin https://github.com/aminoulogie/ai-studio.git ;;
    *) printf "Origin points to another repository. Inspect it locally before changing it.\n" >&2; exit 1;;
  esac
else
  git remote add origin https://github.com/aminoulogie/ai-studio.git
fi
if ! git config user.name >/dev/null; then
  git config --local user.name "$(gh api user --jq .login)"
fi
if ! git config user.email >/dev/null; then
  identity=$(gh api user --jq '(.id|tostring) + "+" + .login + "@users.noreply.github.com"')
  git config --local user.email "$identity"
fi
git config --local push.default simple
git config --local push.autoSetupRemote true
git config --local fetch.prune true
git config --local pull.ff only
git fetch origin --prune
if git show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
  git branch --set-upstream-to="origin/$branch_name" "$branch_name"
else
  printf "No remote branch yet. After committing, run: git push --set-upstream origin '%s'\n" "$branch_name"
fi
printf "Git authentication and local tracking configured. No files were staged or committed.\n"
