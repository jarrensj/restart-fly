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

## 4. Give people the button

Add them under **Settings → Collaborators** (on an organization repo, give them
the **Write** role). Running a workflow needs write access, and that's all they
need: a GitHub account and an accepted invite. No Fly account or CLI.

Write access also lets them edit the workflow and use the token directly. That
is why the token can only restart.

## 5. Try it

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
  logs, deploys or SSH, is refused.
- **`IfPresent` with an empty `Commands` list:** `rC` alone still allows `exec`,
  which would let someone read every secret from the app's environment. This
  caveat applies only to exec requests and allows no commands, so exec is
  refused and nothing else changes.

### Rotating or revoking it

To rotate, run `./create-token.sh <your-fly-app>` again, then revoke the old
token. To revoke, find it by name (`restart-fly (restart only, no exec)` unless
you set `TOKEN_NAME`) in `fly tokens list -a <your-fly-app>`, then run
`fly tokens revoke <id>`.
