# Main ruleset handoff

`main.json` is an inert REST payload. No workflow applies it automatically.
Apply it only after this directory has merged to `main` and the
`product-version` context has run successfully at least once.

The payload requires pull requests, zero approving reviews, and the strict
`product-version` status (the PR must be up to date). Repository administrators
are the only emergency bypass actor. The bypass mode is `always`, not `exempt`,
so an explicit break-glass bypass remains visible in repository rules insights.

Before applying, confirm that no ruleset with the same name already exists:

```sh
test "$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')" = main
gh api "repos/{owner}/{repo}/rulesets" --paginate \
  --jq '.[] | [.id, .name, .enforcement] | @tsv'
```

Then, from a clean checkout of merged `main`, an administrator can perform the
single explicit write:

```sh
gh api --method POST "repos/{owner}/{repo}/rulesets" \
  --input .github/rulesets/main.json
```

Do not rerun that command if the named ruleset exists: creating a second
ruleset would stack duplicate policy. Read the returned ID back immediately and
verify `enforcement`, `bypass_actors`, `conditions`, and `rules` before relying
on the protection:

```sh
gh api "repos/{owner}/{repo}/rulesets/RULESET_ID"
```
