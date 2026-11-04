#!/usr/bin/env bash
# Publishes small CI log files to the ci-logs branch so they can be read without a GitHub login.
# usage: push-logs.sh <dir> <label>      (env: GITHUB_TOKEN, GITHUB_REPOSITORY)
set -u
SRC=$(cd "$1" && pwd) || { echo "no such dir: $1"; exit 0; }; LABEL=$2
W=$(mktemp -d); cd "$W" || exit 0
git init -q
git config user.name "iOXcode CI"; git config user.email "ci@users.noreply.github.com"
echo "pushing logs to ${GITHUB_REPOSITORY:-?} (token set: $([ -n "${GITHUB_TOKEN:-}" ] && echo yes || echo NO))"
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if git fetch -q --depth 1 origin ci-logs 2>/dev/null; then git checkout -q -b ci-logs FETCH_HEAD; else git checkout -q --orphan ci-logs; fi
mkdir -p "runs/$LABEL"; cp -R "$SRC"/. "runs/$LABEL"/
rm -rf latest; mkdir latest; cp -R "$SRC"/. latest/
# keep the 15 newest runs
ls -1d runs/* 2>/dev/null | sort -r | tail -n +16 | while read -r old; do rm -rf "$old"; done
git add -A
git commit -q -m "CI logs $LABEL" || { echo "nothing to commit"; exit 0; }
for i in 1 2 3; do git push origin HEAD:ci-logs 2>&1 | tail -3; [ "${PIPESTATUS[0]}" = 0 ] && { echo "logs pushed"; exit 0; }; git pull -q --rebase origin ci-logs 2>/dev/null; sleep 3; done
echo "could not push logs"; exit 0
