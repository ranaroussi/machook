# Resources

Bundled assets copied into `Contents/Resources/` of the `.app` at build time:

- `cloudflared` — Cloudflare Tunnel binary (downloaded per-arch by CI; falls back to system PATH in dev builds).
- `AppIcon.icns` — macOS app icon shown in Finder, Dock, app switcher, About panel. Multi-resolution `.icns` with all 10 sizes (16/32/128/256/512 at 1x and 2x). Source artwork lives at `assets/icon-app.png` (1024×1024, the largest slice needed).
- `MenuBarIcon.png` + `@2x` + `@3x` — 22/44/66 px template icon used by `NSStatusItem`. Template means macOS keys off the alpha channel and recolours the glyph for light and dark menu bars, so the source is a black silhouette and any colour in it is discarded. Source artwork lives at `assets/icon-menubar.png`.

Both are generated from `assets/` by `make icons`, so edit the source artwork rather than these files.

This README is excluded from the Swift bundle via `Package.swift`.
