# luaboard marketplace

luaboard and its marketplace are a work in progress. For now luaboard runs
only in the simulator, and the release for the real board is near. Things
change and break without notice.

Apps for [luaboard](https://github.com/veikkos/luaboard), Lua 5.4 on the
M5Stack CoreS3, CoreS3 Lite and CoreS3 SE. Each folder is one app, with a
README that says what it does and how to set it up.

## Installing an app

On the board, open Marketplace in the home menu, pick an app and tap
Install. The board also offers updates of the apps it has.

From a computer, clone this repository, then install an app from its folder
with the luaboard studio (open the folder, then Install) or the command-line
tool. Commands in the app READMEs run from the root of the clone, except the
simulator's (`cmake ...`), which run from a luaboard checkout, where this
repository is `marketplace/`:

```sh
git clone https://github.com/veikkos/luaboard-marketplace
cd luaboard-marketplace
luaboard install clock --run
```

## Secrets and logins

Some apps need your own keys or a login, for example an API key for a
service. The app's README says what to get and where, and the app shows a
setup screen until it has them.

- Set each one from a computer, then open the app again:
  `luaboard secrets set <app> <name> <value>`. `luaboard secrets` lists
  what an app has (names only). This works however the app was installed.
- Working on an app from a clone: copy its `secrets.env.example` to
  `secrets.env` in the same folder and fill it in. Installing with the
  studio or `luaboard install` stores the values with the app, and
  `luaboard secrets push .` stores every app's `secrets.env` at once, for
  the apps the board has (from Marketplace too). `secrets.env` is never
  committed.
- Apps that log in to a service (Spotify, GitHub, Google Calendar) ask for
  it on the screen: log in from the studio's login window, or run
  `luaboard browser` on the computer.

Updating an app keeps its secrets and logins.

## Updates

`index.json` lists every app and the versions a board can install. It is
generated after every change, so don't edit it by hand.

## Licenses

Every app has its own license, in its `LICENSE` file and the `license` field
of its `app.json`. The files outside the app folders are MIT, see
[LICENSE](LICENSE).

## Contributing

New apps and fixes are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md).
