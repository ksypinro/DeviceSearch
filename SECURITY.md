# Security policy

## Supported versions

Security fixes go into the latest release on `main`.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability reporting instead: the repository's **Security** tab → **Report a vulnerability**.

Include what you found, how to reproduce it, and the impact you expect. You'll get an acknowledgement within a week, and we'll agree on a disclosure date with you once a fix is ready.

## Scope

DeviceSearch runs entirely on the device and makes no network calls. Relevant reports include:

- device names, rooms or usage history leaking outside the app (logs, Spotlight items in the wrong protection class, model prompts)
- App Intents that switch a device without the confirmation the app promises (locks, cameras, doorbells and garage doors are never switched)
- crashes or hangs triggered by crafted device names or queries
