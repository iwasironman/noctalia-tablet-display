# Noctalia Tablet Display

A [Noctalia](https://noctalia.dev) plugin that turns an Android tablet or iPad
into an extended or mirrored display, streamed by Sunshine to Moonlight.

- [`tablet-display/`](tablet-display/) — the plugin; see its
  [README](tablet-display/README.md) for requirements, setup and usage.
- [`test/`](test/) — standalone tools used while developing the port method:
  an EDID generator and a script that forces a connector on and off by hand.

## Try it from this repo

```
noctalia msg plugins source add tablet-display git https://github.com/iwasironman/noctalia-tablet-display
noctalia msg plugins enable iwasironman/tablet-display
```

Ported from [omarchy-tablet-display](https://github.com/iwasironman/omarchy-tablet-display),
the Hyprland/Omarchy version.

## License

MIT
