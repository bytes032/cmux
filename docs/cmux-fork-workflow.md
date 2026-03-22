# cmux Fork Workflow

This doc is only about the parent `cmux` repo.

Goal:

- keep using our own fork for day-to-day work
- keep pulling new changes from the source repo so we do not miss updates

The model is:

- `origin` = our fork
- `upstream` = the source repo

For this checkout, the intended layout is:

- `origin`: `https://github.com/bytes032/cmux.git`
- `upstream`: `https://github.com/manaflow-ai/cmux.git`

## One-time setup

If this checkout currently only has the source repo as `origin`, convert it to the fork model:

```bash
cd /Users/todor/Downloads/GitHub/cmux
git remote rename origin upstream
git remote add origin https://github.com/bytes032/cmux.git
git fetch upstream
git fetch origin
git branch --set-upstream-to=origin/main main
```

Verify:

```bash
git remote -v
git status --short --branch
```

You should see:

- `origin` pointing to your fork
- `upstream` pointing to `manaflow-ai/cmux`

## Normal update flow

Use this whenever you want the latest source changes from upstream:

```bash
cd /Users/todor/Downloads/GitHub/cmux
git fetch upstream
git checkout main
git rebase upstream/main
git push origin main
```

This does three things:

1. pulls the newest source changes from `manafow-ai/cmux`
2. reapplies your local/fork commits on top
3. updates your fork so it stays current

## Making local changes

Normal workflow:

```bash
cd /Users/todor/Downloads/GitHub/cmux
git checkout -b my-change
# edit files
git add .
git commit -m "feat(diff): improve diff viewer"
git push origin my-change
```

If you work directly on `main`, the sync flow is still the same:

```bash
git fetch upstream
git rebase upstream/main
git push origin main
```

## Safety rules

- Do not treat `origin` as the source of truth once this is set up. `upstream` is the source repo.
- Before rebasing onto `upstream/main`, either commit or stash local changes.
- If the repo is dirty, do not run a blind rebase.
- After syncing, push to `origin`, not `upstream`.

## Current local caveat

If `git status --short --branch` shows something like:

- `ahead`
- `behind`
- modified files

then do this before rebasing:

```bash
git add .
git commit -m "wip: save local work"
```

or:

```bash
git stash push -u
```

Then run the normal update flow.
