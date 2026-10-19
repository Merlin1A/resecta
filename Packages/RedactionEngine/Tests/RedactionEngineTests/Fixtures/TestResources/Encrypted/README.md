# Encrypted fixtures

Committed, deterministic test documents for the password-locked import path:
two plain seeds, a hidden-layer seed, their encrypted forms at the revisions
users meet, and two handler stubs. Produced once by `generate.sh` (qpdf
12.3.2 on a Mac; qpdf is a generator here, never a dependency, and nothing
runs it in a test or in CI). Every file is pinned by its sha256 below; a
regenerated encrypted file has different bytes (the key is salted), so the
committed bytes are the fixtures.

The passwords are throwaways: user password `user`, owner password `owner`;
the non-ASCII pair uses `pässwörd`, the CJK file `密码`.

| file | made from | how | what it carries |
|---|---|---|---|
| `seed-text.pdf` | `seeds.py` | one Helvetica line | the text `ENCRYPTED SEED 7731` |
| `seed-javascript.pdf` | `seeds.py` | the text seed + `/OpenAction` JavaScript | the active-content payload |
| `seed-hidden-ocg.pdf` | `seeds.py` | `/OCProperties /D /OFF` + marked content | `VISIBLE WORD 2210` and the hidden `HIDDENLAYER 4410` |
| `r3-rc4-128.pdf` | `seed-text.pdf` | `--bits=128 --use-aes=n` (R3, RC4) | user + owner passwords |
| `r4-aes-128.pdf` | `seed-text.pdf` | `--bits=128 --use-aes=y` (R4, AESV2) | user + owner passwords |
| `r6-aes-256.pdf` | `seed-text.pdf` | `--bits=256` (R6, AESV3) | user + owner passwords |
| `owner-only-r6.pdf` | `seed-text.pdf` | empty user password, `--print=none --modify=none` | opens with no prompt; printing and changes withheld |
| `owner-only-nocopy-r4.pdf` | `seed-text.pdf` | empty user password, `--extract=n` | opens with no prompt; copying withheld |
| `r4-nonascii.pdf` · `r6-nonascii.pdf` | `seed-text.pdf` | user password `pässwörd` | the non-ASCII arm |
| `r6-cjk.pdf` | `seed-text.pdf` | user password `密码` | the non-ASCII arm |
| `locked-javascript-r6.pdf` | `seed-javascript.pdf` | `--bits=256` | the JavaScript survives encryption (`qpdf --decrypt` shows it) |
| `locked-hidden-ocg-r6.pdf` | `seed-hidden-ocg.pdf` | `--object-streams=generate --bits=256` | the hidden layer inside object streams; the realistic shape of a layer a locked reader cannot see |
| `certificate-stub.pdf` | `seeds.py` | the text seed with an `/Encrypt` dictionary naming `/Adobe.PubSec` | the certificate-handler refusal arm; the strings are not encrypted |
| `unknown-handler-stub.pdf` | `seeds.py` | the same with `/Filter /Bogus` | the unknown-handler refusal arm |

## sha256

```
704c1e3a6a5a44567b449fd5ca028f82006e8e9b23392ae72cf1312bf6bead0c  certificate-stub.pdf
366e22c93f2da3844db76bbbd318c529a6c1c864d930ef4c3855518e59ea4dda  locked-hidden-ocg-r6.pdf
c5d054987acda3b8fdaa12aef4f5eb0935b5ad1cca6168341445c3346f0b9b95  locked-javascript-r6.pdf
2329ececa45aa2881e73b5a19bb15814d4a071275cdca26db688f9ed19652233  owner-only-nocopy-r4.pdf
557a914fd791c1885189f0434a6c897d19209c9af021e5773c5136cf219f8980  owner-only-r6.pdf
0af802de0dcc106dc96ceaf40c9b59db8e81004ba72a9aa8bdd9bbc5e15bf415  r3-rc4-128.pdf
102a0f3ebeab790294be22d7d863385c5d75de6f807451dfb6c9ebbf3c0f09d9  r4-aes-128.pdf
ddbd093444e4a1d0c32f9eb72c26e1a7b673ae01dc9579d8a7f9107e20efbec8  r4-nonascii.pdf
8bd55ecfce59c47f912bfba2db6680c4b059a353abb5a3a90b09dc2f7d00921a  r6-aes-256.pdf
2fdd09c0dfa039d1cdcba61619f63ccb1cf886c86c181af87ce10df105cf46bc  r6-cjk.pdf
b9eae6a4fd0b6c1e3434c6cc003bfc207ca2417917df22fef920e1a2ff062399  r6-nonascii.pdf
b5c43ad86f809d1c14bfb59e8d791eb601cf2cc62f5b01040029a989ce14b101  seed-hidden-ocg.pdf
6855231094eca6f63d86517bd017faa9344bfaf79062606e35239dda623f61d9  seed-javascript.pdf
8ec5ebb500ce2d6eee07e562edc798f3f2281f81965c9bcb7d7437aabf3bbcd1  seed-text.pdf
2e37b1bb3e66419282009c863312b8911d7885058679bf146fe8abb9fb6a896a  unknown-handler-stub.pdf
```

## What the readers do with them (iOS 26.4 simulator, recorded 2026-10-17)

- `PDFDocument.unlock(withPassword:)` with `user` opens R3, R4 and R6; afterwards
  `documentRef` is the same unlocked Core Graphics document (catalog, page
  count and page dictionaries readable, the JavaScript and the `/OFF` array
  seen), so the import's walks read one parser's view.
- Locked, `locked-hidden-ocg-r6.pdf` reads as zero pages in PDFKit and in
  Core Graphics; the hidden layer appears only after the unlock.
- `dataRepresentation()` of an unlocked R6 document emits decrypted bytes;
  of an unlocked R3 or R4 document it emits bytes that are still encrypted
  (the copy opens locked and reads no text until unlocked again). For the
  CJK-password R6 file it returns nil.
- The non-ASCII passwords: `pässwörd` is refused by PDFKit on R4 and R6 (Core
  Graphics accepts it on R6 only); `密码` opens the R6 file in both readers.
- The owner-only files open with no prompt in both readers, `isEncrypted`
  true, the withheld permissions reported by PDFKit.
- The two stubs open as plain, unencrypted documents in both readers: iOS
  does not treat the foreign `/Encrypt` dictionary as a lock.
- PDFKit's and Core Graphics' own encrypted writes (`dataRepresentation(options:)`,
  `CGContext` with a 128-bit key) both produce R4.
