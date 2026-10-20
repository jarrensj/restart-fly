# Setup

This takes about five minutes. You need:

- a Fly app to restart, and [`flyctl`](https://fly.io/docs/flyctl/install/)
  logged in (`fly auth login`) as someone with access to it
- the [GitHub CLI](https://cli.github.com) logged in (`gh auth login`)
- `curl` and `jq`

## 1. Make your copy

Create a repo from this one (**Use this template**, or clone it and push to a
new repo), then clone your copy and `cd` into it. The scripts below save
settings to whichever repo you run them in.

Keep your copy **private** unless you want restart history public. On a public
repo anyone can read the run logs. The workflow masks the app name and health
URL, but who restarted and why are still visible.

## 2. Create the restart-only token

```bash
./create-token.sh <your-fly-app>
```

This:

1. Creates a deploy token for the app and narrows it so it can only read and
   restart machines (see [About the token](#about-the-token)).
2. Checks the narrowed token: listing machines must work, and running a
   command on a machine or reading secrets must be refused. If a check fails,
   nothing is saved.
3. Saves the token as the `FLY_RESTART_TOKEN` secret and the app name as the
   `FLY_APP` variable. The token is never printed.

## 3. Set the optional settings

Everything the workflow reads is listed in [`.env.example`](./.env.example).
On GitHub they go under **Settings → Secrets and variables → Actions**:
secrets on the **Secrets** tab, variables on the **Variables** tab.

| Name | Kind | Needed | What it is |
| --- | --- | --- | --- |
| `FLY_RESTART_TOKEN` | secret | yes | The restart-only token. Step 2 sets it. |
| `FLY_APP` | variable | yes | The Fly app to restart. Step 2 sets it. |
| `HEALTH_URL` | variable | no | A URL that must answer 2xx before a restart counts as done, e.g. `https://your-app.fly.dev/health`. Without it, the run waits for Fly's own health checks only. |
| `PROCESS_GROUP` | variable | no | The process group to restart. Leave unset for `app`, the group `fly deploy` uses. |
| `DISCORD_WEBHOOK_URL` | secret | no | A Discord channel webhook URL. When set, each run posts who restarted the app, why, and whether it worked. See [Discord alerts](#discord-alerts). |

From the CLI:

```bash
gh variable set HEALTH_URL --body "https://your-app.fly.dev/health"
```

### Discord alerts

To have every restart post who did it, and why, to a team channel:

1. In Discord, open the channel's settings, go to **Integrations → Webhooks →
   New Webhook**, give it a name, and click **Copy Webhook URL**.
2. Save the URL as a secret, not a variable, since anyone who has it can post
   to the channel:

   ```bash
   gh secret set DISCORD_WEBHOOK_URL    # paste the URL when asked
   ```

   Or on GitHub: **Settings → Secrets and variables → Actions → New repository
   secret**, named `DISCORD_WEBHOOK_URL`.

The next run posts a card. To turn alerts off, delete the secret.

## 4. Lock it down (recommended)

Running a workflow needs write access, and write access also lets someone edit
the workflow, on `main` or on a branch they push, and use its secrets directly.
The Fly token still only controls machines, but they could read the Discord
webhook URL and post anything to that channel, or change what the button does.
These settings leave the button as the only thing write access gets them.

On a private repo they need GitHub Pro or Team. They're free on public repos.

1. **Add a CODEOWNERS file** naming yourself, so every change needs your
   review:

   ```bash
   mkdir -p .github && echo "* @your-username" > .github/CODEOWNERS
   git add .github/CODEOWNERS && git commit -m "Add CODEOWNERS" && git push
   ```

2. **Protect `main` with a ruleset**, so changes need a pull request approved
   by a code owner and the branch can't be force-pushed or deleted. Go to
   **Settings → Rules → Rulesets → New ruleset → New branch ruleset**:

   - Name it `main` and set **Enforcement status** to **Active**.
   - Under **Target branches**, click **Add target → Include default branch**.
   - Under **Bypass list**, add **Repository admin** if you want to keep pushing
     to `main` yourself.
   - Leave **Restrict deletions** and **Block force pushes** on. Turn on
     **Require a pull request before merging**, with 1 required approval and
     **Require review from Code Owners**.

   Or from the CLI:

   ```bash
   gh api -X POST repos/{owner}/{repo}/rulesets --input - <<'EOF'
   {"name": "main", "target": "branch", "enforcement": "active",
    "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
    "bypass_actors": [{"actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "always"}],
    "rules": [
      {"type": "deletion"},
      {"type": "non_fast_forward"},
      {"type": "pull_request", "parameters": {
        "required_approving_review_count": 1, "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": false, "require_last_push_approval": false,
        "required_review_thread_resolution": false}}
    ]}
   EOF
   ```

   `actor_id` 5 is the Repository admin role. Drop `bypass_actors` if nobody
   should skip the review.

3. **Create a `restart` environment that only `main` can use.** The workflow
   already runs in it. Go to **Settings → Environments → New environment**,
   name it `restart`, then under **Deployment branches and tags** choose
   **Selected branches and tags** and add `main`. Or:

   ```bash
   gh api -X PUT repos/{owner}/{repo}/environments/restart --input - <<'EOF'
   {"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
   EOF
   gh api -X POST repos/{owner}/{repo}/environments/restart/deployment-branch-policies \
     -f name=main -f type=branch
   ```

   Naming `main` works whichever way you protect it.

4. **Move the secrets into the environment**, then delete the repo-wide copies
   and revoke the old token (see [Rotating or revoking it](#rotating-or-revoking-it)):

   ```bash
   ./create-token.sh <your-fly-app> restart
   gh secret set DISCORD_WEBHOOK_URL --env restart    # if you use Discord
   gh secret delete FLY_RESTART_TOKEN
   gh secret delete DISCORD_WEBHOOK_URL
   ```

After this, a run from any branch other than `main` can't read the secrets, and
`main` can't change without your approval. Each run also shows up under the
repo's **Deployments**, as a deployment to `restart`.

## 5. Give people the button

Add them under **Settings → Collaborators** (on an organization repo, give them
the **Write** role). Running a workflow needs write access, and that's all they
need: a GitHub account and an accepted invite. No Fly account or CLI.

## 6. Try it

Run it once at a quiet time: **Actions → Restart → Run workflow**. A good run
ends with the summary line `<machine> is back up, running <version>`, and posts
a green card if Discord is set up.

Private repos use GitHub Actions minutes. A restart takes a minute or two, well
inside the free allowance.

## About the token

`create-token.sh` adds two caveats to a deploy token:

```json
[
  {"type": "Machines", "body": {"machines": {"": "rC"}}},
  {"type": "IfPresent", "body": {"ifs": [{"type": "Commands", "body": []}], "else": "rwcdC"}}
]
```

- **`Machines` `rC`:** machines can be read (`r`) and controlled (`C`: start,
  stop, restart, signal) but not changed, created or deleted. The `""` key means
  every machine in the app. Anything that isn't a machine, such as secrets,
  logs, deploys or SSH, is refused. Fly has no separate permission for restart
  alone, so whoever holds the token can also stop a machine. If your
  `fly.toml` has `auto_start_machines = true`, Fly starts it again on the next
  request.
- **`IfPresent` with an empty `Commands` list:** `rC` alone still allows `exec`,
  which would let someone read every secret from the app's environment. This
  caveat applies only to exec requests and allows no commands, so exec is
  refused and nothing else changes.

### Rotating or revoking it

To rotate, run `./create-token.sh <your-fly-app>` again (add `restart` if your
secrets live in the environment), then revoke the old token. To revoke, find it by name (`restart-fly (restart only, no exec)` unless
you set `TOKEN_NAME`) in `fly tokens list -a <your-fly-app>`, then run
`fly tokens revoke <id>`.
