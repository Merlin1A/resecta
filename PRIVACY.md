# Privacy Policy

**Effective date:** 2026-10-29

Resecta is an on-device document-redaction app for iOS. This Privacy Policy
describes how Resecta handles information. It is written to satisfy Apple's
requirement for a privacy policy (App Store Review Guideline 5.1.1(i)), which
applies even to an app that collects no data.

## Summary

Resecta collects no personal data, makes no network requests of its own, and
uses no third-party services, analytics, or advertising. Everything the app
does happens on your device; the two system services that can reach the
network on their own, Apple's rating prompt and the name-recognition model iOS
provides, are described under "On-device detection" and "Information Apple may
receive as the platform".

## Information Resecta collects

Resecta does not collect, transmit, sell, or share personal information. In
particular, none of the following is collected by the developer or transmitted
off your device:

- the documents and images you open;
- the text and other items the app detects in them;
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
Agreement, Source Code, Report an Issue, Send Feedback, and Rate Resecta on
the App Store items in Settings, and the Report an Issue link on the screen
shown when an import, a redaction run or an export fails — open in a Safari
view, your mail app or the App Store app, each running in its own process
outside Resecta; Resecta itself makes no network requests, and links inside a
document you import are not followed. Once you follow one of those links, the
practices of the website, mail provider or App Store you reach apply, not this
policy.

Resecta does not request access to your photo library: the system Photos picker
runs in its own process and gives the app only the photos you select. If a
photo you pick, or a file you choose in Files, is stored only in iCloud, iOS
may download it before handing it to Resecta; Resecta itself makes no network
requests.

## On-device storage

Some preferences and data you create are stored locally on your device. Your
Custom Terms and your saved-search and saved-regex libraries — the stores that
hold text you typed — are kept as files in the app's private container with
the iOS "complete" file-protection class applied and a system flag that
excludes them from device backups, so they are not copied into iCloud or
computer backups.
Your remaining preferences — your settings (export resolution, fill colour,
default redaction mode, detection sensitivity, appearance, and the automatic
verification and Paranoid Mode switches), the app version that last asked for
an App Store rating, the last search filter you used (its source, confidence
and sort order), and your acceptance of the in-app agreement — are stored in
the system `UserDefaults` store, which participates in your device backups the
way ordinary app preference data does. None of them holds document content or
text you typed. A snap-to-text value and an export counter that earlier
versions stored are deleted the first time the updated app opens.

This data is not transmitted anywhere by the app and is removed when you
delete the app; Custom Terms, the saved-regex library, and the saved-search and
saved-scan lists each have a delete-all control of their own, and each entry
can be removed individually. Storing it locally on your device is not the same
as collecting it: the app sends nothing off the device, the developer never
receives it, and it is not associated with any identity. For that reason the
app's App Store privacy disclosure reports "Data Not Collected" for every
category.

Documents you import are held for the duration of your editing session. If a
PDF needs a password to open, the password you enter is held in memory while
the document is open and is not stored; the app lets go of it when the editing
session closes. The redacted copy is not password-protected and carries none of
the original's usage restrictions; the app says so when you import such a
document and on the Share card. The redacted output is written to a per-session
workspace in the app's private container as the redaction run proceeds, and
that workspace is removed when the session closes; if the app is interrupted
before then, a sweep at the next launch and on each return to the foreground
removes what the interrupted session left behind once it is more than an hour
old. Nothing is retained by the app after that.

## What an exported file contains

When you export a redacted PDF, Resecta builds a fresh file. The exported PDF
omits the document's author, title, subject, keywords, and creator fields. For
accuracy rather than overstatement: the system PDF writer automatically adds a
producer tag, creation and modification timestamps, and a file identifier when
it builds the file. Resecta then replaces the producer tag in the finished file
with a fixed value ("Resecta") that identifies neither the operating system
version nor the build that wrote the file. The rest depends on the version. In
versions 1.0.0 and 1.1.0, the timestamps record when the file was written and
the file identifier is a per-export value the writer assigns, so if a
timestamp matters for your situation, account for it before you share. From
version 1.2.0, Resecta also replaces both timestamps with a constant date, so
they do not record the moment the file was written, and rewrites the file
identifier to a value derived from the file's own contents, so it carries
nothing about the device, the build or the moment of export, and two exports
of identical content carry the same identifier. These replacements patch the
finished file in place; if the writer's output is not in the shape a patch
expects, that value stays as the writer wrote it, the export still completes,
and the metadata check in the verification pass, when it runs, reports the value
that was not replaced. The export therefore carries much less metadata than
a typical PDF, but it is not metadata-free. The file name of a shared copy is
redacted- followed by a short code made from the redacted file itself (for
example redacted-3f9a1c07.pdf). It carries nothing from your document's name
and does not record when you exported it.

Resecta opens PDF files, and JPEG, PNG and HEIC images chosen in Files or in
the system Photos picker, or dropped onto an open document. Each image becomes
one page built from its redrawn pixels: the photo's own embedded metadata, such
as EXIF data or GPS location, is not carried into the file Resecta produces.
Images inside a PDF you open reach the exported file only as redrawn page
pixels.

Versions 1.0.0 and 1.1.0 also imported images and redrew them from their pixels
in the same way; version 1.2.0 opened PDF files only.

## On-device detection

Resecta detects candidate sensitive information entirely on your device. A scan
runs the app's search engine over the text of each page — the page's text layer
where it has one, and otherwise text recognized by the system Vision framework
(optical character recognition) — for seventeen categories of text: Social
Security, EIN and ITIN numbers; card, account and routing numbers; driver's
license, passport, license plate, medical record, NPI and DEA numbers; names,
dates of birth, phone numbers, email addresses and postal addresses. The engine
combines pattern matching with structural validators (for example, a checksum
test on card numbers), the system Natural Language tagger (`NLTagger`) for
names, and gazetteers, Bloom filters and a context scorer bundled inside the
app and built by its open-source data pipeline. The name tagger's model is
provided by iOS, which fetches it on its own; the app never requests that
download, and reports name detection by the tagger as unavailable until the
model is present. Resecta ships no Core ML model and does not use Apple
Intelligence or the Foundation Models system; detection surfaces candidates on
your device for you to review and redact. Automated detection can miss
sensitive content; you are responsible for reviewing each page and verifying
your redactions before you share a document.

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
  Resecta may present once per app version, after the first share of a document
  whose checks passed. Any rating you submit goes to Apple's App Store, not to
  the developer, and the app transmits no data as part of that prompt. Resecta
  is free and contains no in-app purchases.

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
