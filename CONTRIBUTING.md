# Contributing to PortHole

Thanks for helping! PortHole is MIT-licensed. By contributing, you agree your contributions are released under the same license.

## Ways to help

- **Report a bug or a phone that doesn't work.** [Open an issue](https://github.com/arunesh-singh/PortHole/issues/new/choose). Include your macOS version, phone model and Android version, the connection method (MTP or ADB, USB or Wi-Fi), and the relevant log lines (see the [Developer Guide › Debugging](docs/DEVELOPMENT.md#debugging)).
- **Test on your hardware.** Run the [testing checklist](docs/DEVELOPMENT.md#testing) against your phone and report what passed.
- **Send a pull request.** Fixes, docs, translations of the user guide, new features.

## Pull requests

1. Fork the repo and create a branch: `git checkout -b fix/short-description`.
2. `make run` and make your change. Read the [Developer Guide](docs/DEVELOPMENT.md) first if you're touching transports or the extension.
3. Run the [testing checklist](docs/DEVELOPMENT.md#testing) for whatever you touched, and say in the PR what you tested and on which device.
4. Keep PRs focused: one change per PR, matching the surrounding code style.
5. Make sure CI is green.

For larger changes, like a new transport or a new UI area, please open an issue first so we can agree on the approach.
