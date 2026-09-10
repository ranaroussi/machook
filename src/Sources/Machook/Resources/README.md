# Resources

Bundled assets copied into `Contents/Resources/` of the `.app` at build time:

- `cloudflared` — Cloudflare Tunnel binary (downloaded per-arch by CI; falls back to system PATH in dev builds).
- `AppIcon.icns` — macOS app icon shown in Finder, Dock, app switcher, About panel. Multi-resolution `.icns` with all 10 sizes (16/32/128/256/512 at 1x and 2x). Source artwork lives at `assets/icon-app.png` (2048×2048); regenerate with `make icon`.
- `MenuBarIcon.png` + `@2x` + `@3x` — template (monochrome) icon used by `NSStatusItem` in the macOS menu bar.

This README is excluded from the Swift bundle via `Package.swift`.
