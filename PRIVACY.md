# Privacy Policy

**Effective date:** 2026-07-10

Resecta is an on-device document-redaction app for iOS. This Privacy Policy
describes how Resecta handles information. It is written to satisfy Apple's
requirement for a privacy policy (App Store Review Guideline 5.1.1(i)), which
applies even to an app that collects no data.

## Summary

Resecta collects no personal data, makes no network connections, and uses no
third-party services, analytics, or advertising. Everything the app does
happens on your device.

## Information Resecta collects

Resecta does not collect, transmit, sell, or share personal information. In
particular, none of the following is collected by the developer or transmitted
off your device:

- the documents and images you open;
- the text, faces, barcodes, or other items the app detects in them;
- your Custom Terms (the always-flag and never-flag lists you create);
- your saved searches and saved-regex library;
- your settings and preferences; and
- how you use the app.

These are processed and stored only on your device.

## No network connections

Resecta is designed with no networking functionality: its source code contains
no `URLSession` or `NWConnection` usage, and the app is designed to function
with no network access (for example, in airplane mode). Because the app makes
no network requests of its own, it has no means of its own to upload your
documents.

The only links that leave the app — the Privacy Policy, End-User License
Agreement, Source Code, Report an Issue, and Send Feedback items in Settings —
open in Safari or Mail, each in its own process; Resecta itself makes no network
requests. Once you follow one of those links, the practices of the website or
mail provider you reach apply, not this policy.

## On-device storage

Some preferences and data you create are stored locally on your device using
the system `UserDefaults` store. This includes your Custom Terms, your
saved-search and saved-regex libraries, your detection preferences, recent
search queries you have entered, per-category detection priors the app
maintains and uses when ranking its suggestions, an export counter, and your acceptance of
the in-app agreement. Recent-search storage keeps the query text you typed, not
the contents of your documents.

This data stays on your device, is not transmitted anywhere, and is removed when
you delete the app. Storing it locally on your device is not the same as
collecting it: it never leaves the device, the developer never receives it, and
it is not associated with any identity. For that reason the app's App Store
privacy disclosure reports "Data Not Collected" for every category.

Documents you import are held only for the duration of your editing session and
are not retained by the app after you finish with them.

## What an exported file contains

When you export a redacted PDF, Resecta builds a fresh file. The exported PDF
omits the document's author, title, subject, keywords, and creator fields. For
accuracy rather than overstatement: the system PDF writer automatically adds a
generic producer tag and creation and modification timestamps when it builds the
file. The export therefore carries much less metadata than a typical PDF, but it
is not metadata-free; if a timestamp matters for your situation, account for it
before you share.

A separate note applies to photos. An image you import can carry its own
embedded metadata, such as EXIF or GPS location data. Resecta redraws imported
images from their pixels before they enter the document, so that embedded
metadata is not carried into the file Resecta produces.

## On-device detection

Resecta detects candidate sensitive information entirely on your device.
Detection combines pattern matching with structural validators (for example, a
checksum test on card numbers), the system Natural Language tagger (`NLTagger`)
for names, and the system Vision framework for optical character recognition,
faces, and barcodes or QR codes. Resecta ships no Core ML model and does not use
Apple Intelligence or the Foundation Models system; detection surfaces
candidates on your device for you to review and redact. Automated detection can
miss sensitive content; you are responsible for reviewing each page and
verifying your redactions before you share a document.

No face data, biometric data, or document content is created for, stored by, or
transmitted to the developer or any third party.

## No third-party services, advertising, or tracking

Resecta integrates no third-party software development kits for analytics,
advertising, crash reporting, or tracking. It sets no cookies and creates no
advertising or tracking identifiers. The app's only dependency is its own
open-source redaction engine, which also runs entirely on your device.

## Information Apple may receive as the platform

Because Resecta is distributed through the App Store, Apple — as the platform —
may receive certain information that the developer does not control and does not
itself collect:

- Standard app-download and App Store account information that Apple receives
  when you download or update any app.
- Crash diagnostics, but only if you choose to share them with developers
  through your device's Analytics & Improvements settings, which Apple mediates
  and anonymizes.
- A rating, if you respond to Apple's standard App Store rating prompt, which
  Resecta may present after a few successful exports. Any rating you submit goes
  to Apple's App Store, not to the developer, and the app transmits no data as
  part of that prompt. Resecta is free and contains no in-app purchases.

Resecta does not collect any of this information itself.

## Data retention and deletion

Because Resecta stores nothing off your device, there is nothing for the
developer to retain or delete. The data the app stores locally (described under
"On-device storage") remains on your device under your control and is removed
when you delete the app.

## Children's privacy

Resecta is not directed to children and collects no data from anyone, including
children under 13.

## Your choices and rights

Resecta collects no personal data, so there is no personal information for the
developer to access, correct, export, or delete on your behalf, and no profile
or identifier to opt out of. The on-device data described above is already in
your control and is removed when you delete the app.

This approach is intended to be consistent with data-protection frameworks such
as the EU GDPR, the UK GDPR, and the California Consumer Privacy Act (CCPA),
under which the rights that apply turn on data a service actually holds about
you — here, none.

## Changes to this policy

If this policy changes, the updated version will be posted at this address with
a revised effective date.

## Contact

Questions about this policy: **support@resecta.app**.
