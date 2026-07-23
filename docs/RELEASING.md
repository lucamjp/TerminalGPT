# Releasing

1. Update the version and build number in:
   - `AppConfiguration.swift`
   - `Info.plist`
   - `Info.Beta.plist`, if needed
2. Update `CHANGELOG.md`.
3. Run:

```sh
swift build
./scripts/typecheck.sh
./scripts/build.sh release main
./scripts/build.sh release beta
```

4. Commit and tag:

```sh
git tag v3.3.3
git push origin main --tags
```