# meetro — documentation

Everything about how this thing works and why it's built this way.

## Start here

**[ARCHITECTURE.md](ARCHITECTURE.md)** — the one to read first. Metro's API has no
train-position endpoint, so a live map of moving trains should be impossible. This
explains the trick that makes it work, why the server is stateful, and where the
estimates are wrong.

## How the code works

| | |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | The idea, the data flow, the honest limits |
| [SERVER.md](SERVER.md) | The Python backend, module by module |
| [ROUTING.md](ROUTING.md) | Fastest-route planning from live train waits |
| [APP.md](APP.md) | The Flutter client, module by module |
| [WIDGET.md](WIDGET.md) | The iOS home-screen widget |
| [LIVE_ACTIVITY.md](LIVE_ACTIVITY.md) | Active route on the lock screen / Dynamic Island |
| [API.md](API.md) | **Metro Lisboa's API** — live-verified reference, quirks and all |

## Running and shipping it

| | |
|---|---|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Setup from scratch, plus every failure we hit and why |
| [DEPLOY.md](DEPLOY.md) | Fly.io |
| [APP_STORE.md](APP_STORE.md) | Submission checklist |

## Risk

| | |
|---|---|
| [SECURITY.md](SECURITY.md) | Secrets, exposure, and **one open issue worth reading** |
| [LEGAL.md](LEGAL.md) | Unresolved: API terms, trademarks, tile licensing |
| [PRIVACY.md](PRIVACY.md) · [TERMS.md](TERMS.md) | Drafts, mirrored in `app/lib/legal.dart` |

## The shape of it

```
server/     FastAPI. Polls Metro every 12 s, estimates positions, streams over SSE
data/       Baked OSM tunnel geometry + the script that builds it
app/        Flutter client (lib/) + iOS widget (ios/MetroWidget/)
docs/       You are here
```

One repo, one product, three parts that only make sense together — which is why the
docs live here rather than in each folder.

## Things that are true and non-obvious

Collected because each one cost real time to learn:

- **The API never says where a train is.** Positions are inferred. See
  [ARCHITECTURE.md](ARCHITECTURE.md#the-trick).
- **`API_BASE` is compiled in.** No `--dart-define`, and the app talks to `localhost`
  — on a phone, that's the phone. It'll never connect.
- **The server must never scale to zero.** It learns the network's topology from the
  feed and holds it in memory. A cold start is a dumb start.
- **`server/app/models.py` and `app/lib/models.dart` are one contract in two files.**
  Nothing checks that they agree.
- **An empty map at 03:00 is correct** — the metro shuts at 01:00. The app now says so
  instead of showing "0 trains".
- **TLS verification is disabled by default**, including in production.
  [SECURITY.md](SECURITY.md#tls-verification-is-off-by-default).
- **Free-tier iOS signing expires every 7 days.** The app stopping isn't a bug.
