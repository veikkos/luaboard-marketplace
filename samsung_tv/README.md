# Samsung TV

A remote for a Samsung TV on your network: power, volume and mute, the
arrows with OK, home and back, source, playback, and the TV's apps. The top
line shows whether the TV is on and which app is on its screen.

It talks to the TV as Samsung's own phone app does, on your network only:
no account and no cloud. Volume and mute are the TV's remote keys, so with a
receiver or a soundbar they do what the TV's own remote does.

Tap a key, or hold the arrows and the volume keys to repeat them. Swipe to
the side (or tap APPS) for the apps: those of Netflix, YouTube, Prime Video,
Disney+, Apple TV, HBO Max, Spotify, Viaplay, Twitch and Plex that the TV
has, the one on the screen marked. On a board with buttons, A and C are
volume down and up, and B is mute.

## Setup

It needs firmware with Lua API 2, a Samsung TV with Tizen whose remote
channel uses Samsung's "SmartViewSDK Root CA G2" certificate, and the board
on the same network as the TV. It has been used with a 2023 model (S90C).
Older models may use another certificate: the app then says so.

Get it from Marketplace on the board. Or, with the app's folder on a computer
(this repository, cloned), use Install in the studio or
`luaboard install samsung_tv`.

The first time, the TV asks on its screen whether to allow "luaboard":
choose Allow with the TV's remote. The app keeps the token the TV gives it
as a secret, and isn't asked again. If the prompt went by unanswered, tap
the line at the bottom of the app to ask again.

Turning the TV on from off needs "Power On with Mobile" in the TV's network
settings (the app wakes the TV over the network).

If the TV isn't found (a network that doesn't pass discovery on), tell the
app its address, then open the app again:

```sh
luaboard secrets set samsung_tv host 192.168.1.30
```

## Development

To work on the app, clone this repository: `luaboard install samsung_tv
--run` in it (or Install in the studio) puts your copy of the folder on the
board and starts it. In the simulator with `--loopback`, set `host`: it
can't look for the TV there.

## Notes

The keys go over the TV's remote-control channel, a WebSocket with TLS on
port 8002 (`ws` and `cert_name` in the Lua API). The TV's certificate is
issued by Samsung's "SmartViewSDK Root CA G2" to the name "Samsung
SmartViewSDK Cert. G2", not to the TV's address. The app carries that root
certificate (SHA-256 fingerprint BB:9B:49:4C:2C:69:92:5F:29:25:4E:A6:E0:DE:
3D:64:35:D6:B4:10:2E:48:3C:01:6F:31:C6:45:C2:AF:DB:94) and checks both.

What the TV is doing comes from its plain HTTP interface on port 8001:
`/api/v2/` (name, power state) and `/api/v2/applications/<id>` (whether an
app is installed and on the screen, and a POST there starts it).

Samsung is a trademark of Samsung Electronics. This app is not made or
endorsed by Samsung.
