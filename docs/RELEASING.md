# Releasing Glasstap

Steps 1 and 2 are one-time setup. After that, each release is one command (step 3), or one tag push if you set up GitHub Actions (step 4).

## 1. Developer ID certificate (once)

Developer ID is the certificate for apps distributed outside the App Store.

1. Open Xcode → **Settings → Accounts**, select your Apple ID, and click **Manage Certificates…**
2. Click **+** → **Developer ID Application**.

Check that it's installed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Only the Account Holder of a developer team can create this certificate. On a personal account, that's you.

## 2. Notarization credentials (once)

Apple notarizes (scans) every release. `notarytool` needs to sign in for that, and an app-specific password is the simplest way:

1. Go to [account.apple.com](https://account.apple.com) → **Sign-In and Security → App-Specific Passwords**, and create one named "Glasstap notarization".
2. Save it in your keychain under the profile name the release script uses:

```bash
xcrun notarytool store-credentials glasstap-notary --apple-id rohan.gdr@gmail.com --team-id B5526BNTDG
```

It prompts for the app-specific password.

## 3. Release from your Mac

```bash
scripts/release.sh 0.2.0
```

The script:

1. Archives a Release build signed with Developer ID, with the Hardened Runtime and a secure timestamp.
2. Checks the signature and entitlements (camera and microphone only, no debugging entitlement).
3. Notarizes and staples the app, so it opens without a network check even after it's dragged out of the DMG.
4. Builds the drag-to-Applications DMG, then signs, notarizes and staples that too.
5. Runs a Gatekeeper check.

It writes `dist/Glasstap-0.2.0.dmg` and prints the command to publish it:

```bash
gh release create v0.2.0 dist/Glasstap-0.2.0.dmg --title "Glasstap 0.2.0" --generate-notes
```

`brew install create-dmg` gives the DMG a tidier window. Without it, the script uses plain `hdiutil`.

To test the pipeline without notarizing, run `scripts/release.sh 0.2.0 --dry-run`. It signs with your development certificate. Don't publish that DMG.

The in-app update check compares the latest release's tag (`v0.2.0`) with the app's version, so always tag releases `v<version>`.

## 4. Release from GitHub Actions (optional)

`.github/workflows/release.yml` runs the same script whenever you push a `v*` tag, then attaches the DMG to a new GitHub Release. It needs five repository secrets, under **Settings → Secrets and variables → Actions**.

### Export the certificate

1. Open **Keychain Access → login → My Certificates**.
2. Right-click **Developer ID Application: Rohan Reddy Bandi** → **Export…**
3. Save it as `developer-id.p12` with a strong password.

Then add the secrets from the folder where you saved it (`gh secret set` prompts for each value or reads it from a pipe):

```bash
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R RohanReddyBandi/Glasstap
```

```bash
gh secret set DEVELOPER_ID_P12_PASSWORD -R RohanReddyBandi/Glasstap
```

```bash
openssl rand -base64 24 | gh secret set KEYCHAIN_PASSWORD -R RohanReddyBandi/Glasstap
```

```bash
gh secret set APPLE_ID -R RohanReddyBandi/Glasstap
```

```bash
gh secret set APPLE_APP_PASSWORD -R RohanReddyBandi/Glasstap
```

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The exported certificate, base64-encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The password you gave the .p12 |
| `KEYCHAIN_PASSWORD` | Any random string; it protects a throwaway keychain on the build machine |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APP_PASSWORD` | The app-specific password from step 2 |

Delete `developer-id.p12` once the secrets are saved.

### Ship a release

```bash
git tag v0.2.0
```

```bash
git push origin v0.2.0
```

Watch it under the repository's **Actions** tab. When it finishes, the release and its DMG are on the Releases page.

### Using an App Store Connect API key instead

Apple's recommended notarization login for CI is an API key, which doesn't depend on your Apple ID password:

1. Create a key in App Store Connect → **Users and Access → Integrations → Team Keys**.
2. Pass the key to the script as `NOTARY_KEY_PATH` (the `.p8` file), `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. In the workflow, decode the key from a secret into `$RUNNER_TEMP` first.

The script uses the API key whenever `NOTARY_KEY_ID` is set.
