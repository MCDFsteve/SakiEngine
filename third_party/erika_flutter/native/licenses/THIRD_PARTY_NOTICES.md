# Third-Party Notices

Erika's own source code is licensed under **MPL-2.0** (see `LICENSE`).

The prebuilt `erika_capi` binaries in this bundle **statically link** the
following third-party native libraries, built with Erika's `lgpl` dependency
profile. Their licenses apply to the corresponding portions of the binary.

| Component | Version | License |
|-----------|---------|---------|
| FFmpeg (libav*) | 8.1.2 | LGPL v3 (configured `--disable-gpl --enable-version3`) |
| dav1d | 1.5.x | BSD 2-Clause |
| libass | 0.17.5 | ISC |
| FreeType | 2.14.3 | FTL / GPLv2 (FTL used here) |
| HarfBuzz | 14.2.1 | MIT (Old) |
| FriBidi | 1.0.x | LGPL v2.1+ |
| zlib | 1.3.x | zlib |
| SoundTouch | 2.3.2 | LGPL v2.1 |

The Erika binary also embeds these assets:

| Asset | Copyright / author | License |
|-------|--------------------|---------|
| Droid Sans Fallback (`subfont.ttf`) | Digitized data copyright Google Corporation © 2006; designed by Steve Matteson / Ascender Corporation | Apache-2.0 |
| ArtCNN C4F16 / C4F32 model weights | Copyright © 2024 João Chrisóstomo | MIT |

The release archive includes the corresponding attribution and complete license
texts under `licenses/`.

This software is based in part on the work of the FreeType Team. Portions of
FFmpeg's DCT implementation derive from the Independent JPEG Group's work; see
`licenses/LICENSE.FFmpeg.md` for FFmpeg's complete licensing notes.

## LGPL compliance (FFmpeg, FriBidi, SoundTouch)

These binaries link LGPL components statically. To honor the LGPL's relinking
requirement, the complete corresponding source and the reproducible build
system that produced these binaries are publicly available:

- **Erika source** (this exact build): the Git tag named in the release / the
  commit recorded in the bundle's `MANIFEST.txt`, at
  <https://github.com/AimesSoft/Erika>.
- **Native dependency build**: `xtask deps build --all --profile lgpl` plus the
  per-target build described in `docs/building.md` in that source tree.

Anyone who receives these binaries can therefore rebuild `erika_capi` against a
modified version of FFmpeg (or any other LGPL component above) by checking out
that source and re-running the build with their replacement library.

SoundTouch 2.3.2 is bundled by the Cargo packages pinned in `Cargo.lock`
(`soundtouch` 0.5.4 and `soundtouch-ffi` 0.4.1). Its corresponding source ships
inside the `soundtouch-ffi` package downloaded by Cargo. SoundTouch is copyright
© Olli Parviainen 2001–2022. A recipient can patch or replace that dependency
and rebuild the complete Erika static library with Cargo to relink against a
modified SoundTouch. The LGPL v2.1 text is included at
`licenses/LICENSE.LGPL-2.1`.

The archive's `licenses/` directory contains the applicable FFmpeg LGPLv3/GPLv3
terms, the dav1d BSD 2-Clause license, the FreeType License, and the libass,
HarfBuzz, and zlib notices in addition to the asset and LGPLv2.1 texts. The same
upstream license files are also distributed with each library's source archive
(retrievable via `xtask deps fetch`).
