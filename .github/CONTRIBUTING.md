# Contributing

**Whoopsy is not accepting contributions yet.** Please don't send pull requests.

## Where the project is

Pre-alpha, one developer, and the app does not yet work end to end on a device:

- The BLE path has never been validated against real hardware. No strap has ever been connected,
  so `biometric_samples` holds zero rows in every database on the development machine.
- The historical flash drain — the path that would fill in a night the app slept through — is
  unimplemented. Four gaps remain open, and one of them (the missing `0x17` ACK loop) is left
  unbuilt deliberately: a drain this app cannot acknowledge makes the strap re-send the same batch
  forever.
- Signing is not configured, so the iOS target builds but cannot be installed on a device.
- The architecture is still moving. Screens and their data sources are being added, and domain
  entities gain and lose fields as the models settle.

An outside pull request right now would be built on a foundation that is still shifting, and the
review it needs is work better spent on the app itself.

## What is welcome

Bug reports and questions, as GitHub issues. Concrete detail helps: what you ran, what you
expected, what happened. If you are reporting something about a data figure, say which day and
where it came from — imported from a WHOOP export, or read off a strap.

## When this changes

Once strap sync works against real hardware and the base app is finished, this file becomes a real
guide and pull requests open up. The material for it already exists in the repository — `CLAUDE.md`
for the build and test commands and the architectural rules, `docs/ALGORITHMS.md` and `docs/BLE_PROTOCOL.md`
for the specs, and `docs/PATENTS.md` for what is and isn't WHOOP's own mathematics. Read those first if
you want to understand the design in the meantime.
