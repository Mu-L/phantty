# Tutorial screenshots

Captured from a real, visible WispTerm Windows window on 2026-09-11, built locally with `zig build` from commit `aca086115d20b12e3e0fee42c2ad14740a7f9875`.

The capture process follows the PowerShell/Win32 workflow in `docs/development.md`: activate the target window, navigate the UI, and capture pixels from its bounds. Form images capture only the observed dialog region. Images are not generated mockups or recolored to follow the website theme.

The application runs with an isolated APPDATA directory and Chinese UI, using illustrative SSH profiles (`gpu.example.com`, `cpu.example.com`), a blank API key, and explicitly labeled sample conversations and memories. No personal histories, private keys, or live server credentials are used. Forwarding rules remain stopped and no model API or SSH login is performed for these screenshots.

Images cover the session launcher, AI profile form, SSH form, Conversation Center, Memory Center, memory source settings, forwarding list and forwarding form. Full workbench captures are 1600 × 1000 pixels; dialog regions retain their original capture resolution. Every image is linked to its original PNG in the tutorial.
