# EntTester (Swift) — iOS entitlement functional tester

Pure Swift/SwiftUI. Every entitlement (except the removed / macOS-only ones) is
**actually exercised** with a real framework call — not just checked for presence.
Built on GitHub Actions (real Xcode + current iOS SDK), so Swift-only frameworks
(WeatherKit, FamilyControls, real Sign in with Apple sheet, App Attest, etc.) run
for real.

## What each status means
- ✅ functional — the operation actually ran
- 🔵 present — in the signature; exercised indirectly / config-only
- ⚙️ needs config — API reachable but needs external setup (iCloud on, a signed pass, a domain…)
- ❌ denied — API reachable, OS/user refused
- ⛔️ unavailable — not available on this device/OS
- ✖️ absent — not in the signature

⭐ = interactive (opens a system sheet). Skipped by **Run all**; tap the row to run.

## The one true exception
`associated-domains` cannot be verified from inside an app — it requires an
`apple-app-site-association` file hosted on the real domain. There is no app-side
API. Everything else does a real call.

## Build on GitHub Actions
1. Create a new GitHub repo and push this folder:
   ```
   git init && git add . && git commit -m "EntTester"
   git branch -M main
   git remote add origin git@github.com:<you>/enttester.git
   git push -u origin main
   ```
2. The **Build unsigned IPA** workflow runs automatically (or Actions tab → Run workflow).
3. Download the `EntTester-unsigned-ipa` artifact when it's green.

If the first run fails to compile, open the failed step's log and send it to me —
I can't compile Swift locally, so CI is the compiler.

## Sign & install
The artifact is **unsigned**. Sign it with your cert, then sideload (Feather):
- Easiest: drop `EntTester-unsigned.ipa` into **Feather** with your dev profile.
- Or `zsign -k dev.p12 -p <pass> -m dev.mobileprovision -o EntTester.ipa EntTester-unsigned.ipa`

Use the **development** profile (aps-environment=development, get-task-allow=YES)
so push tests hit the **sandbox** gateway and the memory screen can show a debugger.

## Push testing
Receiving needs only the app + a valid profile. **Sending** a push needs an APNs
**.p8 auth key** (Key ID + Team ID) — no signing cert can send. Open the Push
screen: Register → paste your .p8 → Send to myself. No .p8? Use "Fire local
notification" to prove the notification pipeline.

## Notes
- Deployment target iOS 16.0.
- Wi-Fi Aware needs the iOS 26 SDK; if the runner's Xcode lacks it, the app reports
  it as present-in-signature and skips the live call (guarded by `#if canImport`).
- The .p8 you paste is stored in the app's local defaults for convenience — fine for
  personal testing, don't ship a build with a key embedded.
