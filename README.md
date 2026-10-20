# restart-fly

A **Run workflow** button that restarts a [Fly.io](https://fly.io) app, for
people who shouldn't have full Fly access.

- **Who can press it:** anyone with write access to your copy of this repo.
  Add or remove people under **Settings → Collaborators**. They don't need a
  Fly account.
- **What the button can do:** restart the app's machines. The Fly token it
  uses can start, stop and restart machines, but can't deploy, read secrets or
  logs, SSH in, or run commands. With the
  [lock-down settings](./SETUP.md#4-lock-it-down-recommended), people with
  write access can't change the workflow or read its secrets either, so the
  button is all they get.
- **Who did it:** every run records who started it and why, and can post a card
  to Discord.

To set up your own copy, see [SETUP.md](./SETUP.md).

## How to restart the app

1. Open this repo on GitHub.
2. Click the **Actions** tab at the top of the page.
3. In the list of workflows on the left, click **Restart**.
4. On the right, above the list of past runs, click **Run workflow**.
5. Type a reason if you like (it shows up in the run and on Discord), leave the
   branch on `main`, and click the green **Run workflow** button.
6. The new run appears at the top of the list within a few seconds. Refresh
   if it doesn't. Click it to watch.

When the run gets a green check, the app is back up. A red X means it didn't
restart or didn't come back; click the run to see why.

On a phone, use the GitHub mobile app: open the repo, tap **Actions**, then
**Restart**, then **Run workflow**.

If there's no **Run workflow** button, you don't have write access to the repo.
Ask the repo's owner to add you as a collaborator.

### Other ways to run it

- **CLI:** `gh workflow run restart.yml -R <owner>/<repo> -f reason="stuck queue"`
- **API**, for a bot or script:

  ```
  POST https://api.github.com/repos/<owner>/<repo>/actions/workflows/restart.yml/dispatches
  Authorization: Bearer <GitHub token with actions:write on the repo>

  {"ref": "main", "inputs": {"reason": "stuck queue"}}
  ```

## What a restart does

1. It restarts each machine in the app's `app` process group, one at a time.
   Machines outside that group are left alone.
2. Each machine is stopped the way a deploy stops it: with the `kill_signal` and
   `kill_timeout` from your `fly.toml`, so the app gets its normal time to shut
   down cleanly.
3. A machine that's **stopped** (for example, Fly gave up restarting a process
   that kept crashing) is started instead.
4. It waits until the machine is running again, Fly's health checks pass, and
   `HEALTH_URL` answers (if you set one). If that takes more than 5 minutes,
   the run fails.
5. The run summary says what the machine is running now. If Discord is set up,
   a card says who restarted it, why, and whether it worked.

A machine in the middle of something else, such as a deploy, is not touched:
the run fails and asks you to try again in a minute. Only one restart runs at
a time, and a second click waits for the first to finish.

## Alerting your team on Discord (optional)

Set the `DISCORD_WEBHOOK_URL` secret to a Discord channel webhook, and every run
posts a card to that channel saying who restarted the app:

- **Green, "my-app restarted by @user":** the app is back up. Shows the reason
  and the version it's running.
- **Red, "my-app restart by @user failed":** it didn't restart, or didn't come
  back.

Both cards link to the run. Without the secret the step is skipped, and a
Discord problem never fails the restart. To set it up, see
[SETUP.md → Discord alerts](./SETUP.md#discord-alerts).

## Running it locally

`restart.sh` is the whole restart and only needs `curl`, `jq` and the token:

```bash
cp .env.example .env    # fill in FLY_API_TOKEN and FLY_APP at least
set -a; . ./.env; set +a
./restart.sh
```

## License

[MIT](./LICENSE)
