# Stored page images, one for each runtime

Each file is the one image stream of a page of an export, as the app's writer
stores it, read back through the system reader. The page is drawn by
`PageImageFixtures.madePage(width: 1275, height: 1650, mark: 2026)`: lines of
dark bars on white, made for testing. No found document and no real data.
It is encoded as the writer encodes a page (a JPEG at quality 0.92 through the
system encoder) and written through the writer's draw path on a Letter page.

`PageImageReadTests` pins each file's SHA-256, reads it whole, and makes the
broken inputs of its byte-edit cases from it.

| file | runtime | bytes | SHA-256 |
|---|---|---|---|
| `page-image-macos-27.2.jpg` | macOS 27.2 (26B123), the Mac host | 182,065 | `ad4cbdc71d4cc899bdc62a9dc0936f70df4ebdf36a131e4fb245b60e8529101d` |

The iOS simulator and phone files are added when those runs deliver them.
