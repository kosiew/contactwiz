# ContactWiz

A macOS app that turns a screenshot of contact details (business card, email
signature, profile page…) into a contact in **Google Contacts**.

1. **Drop, open, paste (⇧⌘V) or capture (⇧⌘R)** a screenshot.
2. Text is read on-device with the Vision framework.
3. Fields are extracted with **Apple Intelligence (Foundation Models)**, using
   guided generation into a contact schema. Rule-based extraction (data
   detectors and name tagging) fills gaps, and also drops any phone, email or
   URL the model returns that isn't actually in the screenshot. On Macs without
   Apple Intelligence, the rules alone are used.
4. Review and edit the fields, then click **Add to Google Contacts** (⌘↩). The
   contact is created through the People API, and its page opens in your
   browser, ready to edit.

Offline alternatives: **Export → Save vCard (.vcf)** (import it at
contacts.google.com → Import), **Copy vCard**, or **Open in Apple Contacts**.

## Build

Requires macOS 14+ (Apple Intelligence needs macOS 26+). Xcode isn't needed;
the Command Line Tools are enough.

```sh
scripts/build-app.sh          # → build/ContactWiz.app
open build/ContactWiz.app
```

Or run directly: `swift run ContactWiz`.

## Google setup (one time)

Creating contacts needs your own OAuth client:

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and
   enable the **People API**.
2. Configure the **OAuth consent screen** (External, Testing) and add your Google
   account as a test user.
3. **Credentials → Create credentials → OAuth client ID → Desktop app.**
4. In ContactWiz → **Settings (⌘,)**, paste the client ID and secret, then click
   **Sign In with Google**.

Sign-in uses the desktop loopback flow with PKCE. The refresh token and client
secret are stored in your Keychain. While the consent screen is in "Testing",
Google expires refresh tokens after 7 days, and ContactWiz asks you to sign in
again when that happens.

## CLI

```sh
swift run contactwiz-cli card.png               # print vCard
swift run contactwiz-cli card.png -o card.vcf   # write file
swift run contactwiz-cli card.png --no-ai --lines
swift run contactwiz-cli card.png --google      # create in Google (sign in via the app first)
```

## Checks

The Command Line Tools ship neither XCTest nor the Swift Testing macros, so the
checks are a plain executable:

```sh
swift run contactwiz-checks
```

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/ContactWizCore/TextRecognizer.swift` | Vision OCR |
| `Sources/ContactWizCore/ContactExtractor.swift` | Foundation Models extraction + merge with rules |
| `Sources/ContactWizCore/HeuristicParser.swift` | Rule-based extraction |
| `Sources/ContactWizCore/GoogleContacts.swift` | OAuth + People API `createContact` |
| `Sources/ContactWizCore/VCardWriter.swift` | vCard 3.0 export |
| `Sources/ContactWiz/` | SwiftUI app |

Build notes: the Command Line Tools also lack the `@Generable` and SwiftUI
`@State` macro plugins. That's why the model schema is a
`DynamicGenerationSchema` and view state lives in `AppModel`.
