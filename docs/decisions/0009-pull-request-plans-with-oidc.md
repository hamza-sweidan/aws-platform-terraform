# 0009. Pull request plans with OIDC and read-only identities

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

CI (`terraform-ci.yml`) checks the code with no cloud access at all. That
catches syntax, policy and logic errors, but not what a change would *do* to
the real accounts. A reviewer wants to see the plan on the pull request.

Running a plan in GitHub Actions needs cloud credentials. The classic answer,
an access key or client secret stored as a GitHub secret, is a long-lived
credential that can leak through a log, a compromised action or a
misconfigured workflow, and has to be rotated by hand.

The repository is public, which adds two constraints: plan output contains
account IDs, ARNs and subscription IDs, and anything a workflow prints is
world-readable.

## Decision

`.github/workflows/terraform-plan.yml` runs `terraform plan` for `envs/dev`
(AWS) and `azure/envs/dev` on every pull request, authenticating with
**GitHub's OIDC token** exchanged for short-lived cloud credentials.

| | AWS | Azure |
|---|---|---|
| Identity | IAM role `aws-platform-github-plan` + GitHub OIDC provider (`bootstrap/github_oidc.tf`) | User-assigned managed identity + federated credential (`azure/bootstrap/github_oidc.tf`) |
| Trust | `sub` = `repo:<owner>/<repo>:pull_request`, `aud` = `sts.amazonaws.com`, StringEquals | Same subject, audience `api://AzureADTokenExchange` |
| Read | `ReadOnlyAccess`, minus object reads outside the state bucket (explicit Deny) | Reader on the subscription, Storage Blob Data Reader on the state container |
| Write | Explicit Deny on state writes | Custom role: `storageAccounts/read` + `write` on the state account only (for the firewall, below) |

Choices:

- **`-lock=false`.** A plan is speculative, so the identities never take the
  state lock and never need write access to state.
- **Managed identity, not an app registration, on Azure.** It lives in the
  subscription next to the state and needs no Entra directory permissions to
  create.
- **The state firewall.** Runner IPs change every job, so the Azure job adds
  its own IP with `scripts/azure-state-firewall.sh allow` and removes it in an
  `always()` step. ARM can't grant "edit network rules" on its own, only
  `storageAccounts/write`. So two **built-in Deny policies** on the state
  resource group limit what that write can do: Shared Key must stay off and
  the firewall must stay default-Deny. RBAC grants the verb; policy limits the
  outcome.
- **Public-log hygiene.** The plan's full output stays in a file on the
  runner. The job summary gets only the `Plan:` line plus each changed
  resource's address and action (`scripts/ci-plan.sh`). Account identifiers
  live in GitHub *secrets*, not because they're credentials but so they're
  masked in logs.
- **Opt-in.** Each job runs only when its repository variable
  (`AWS_PLAN_ENABLED`, `AZURE_PLAN_ENABLED`) is `true`, so the workflow is
  harmless before the identities exist.

## Consequences

**Good**
- No stored credential anywhere. Tokens live about an hour and are bound to
  this repository's pull requests.
- Pushes to `main`, manual runs, other repositories and forks get a
  different token subject, or no token at all, and are refused.
- Reviewers see what would change in each cloud before merging.

**Costs and limits**
- A pull request can edit the workflow itself. Anyone who can push a branch
  to this repository can use the plan identities' read access. That's
  acceptable for a single-owner repository. With collaborators, use a
  protected environment with required reviewers, and bind the trust to the
  environment (`sub` = `repo:<owner>/<repo>:environment:<name>`) instead of
  `pull_request`.
- `ReadOnlyAccess` is broad (it can describe everything). The explicit Deny
  removes the part that matters most, reading S3 objects. A hand-written
  policy would be tighter but needs updating with every new resource type.
- If a job is killed before its `always()` step, the runner's IP stays in
  the firewall until `scripts/azure-state-firewall.sh reset`.
- Plans in CI need the state backends to exist (`bootstrap` applied) and the
  AWS plan needs the `envs/dev` inputs as secrets/variables.

## Alternatives considered

| Option | Why not |
|---|---|
| Access key / client secret in GitHub secrets | A long-lived credential: exactly what this avoids. |
| HCP Terraform or Atlantis | A good fit for teams, but another service to run and pay for; moves plans out of GitHub. |
| Self-hosted runner in the VNet/VPC | Fixed IP and private access to state, but it's a VM to run and patch around the clock. |
| Allow GitHub's published IP ranges in the storage firewall | Thousands of ranges; the storage firewall holds at most a few hundred rules. |
| Post the full plan as a PR comment | Leaks account identifiers in a public repository. |
