# Repository maintenance

This document contains the technical details needed to maintain the library.
They are not required when contributing new assets.

## Manifest generation

The Ruby generator has no external gem dependencies. It produces four manifests
at the repository root:

```text
characters.json
backgrounds.json
music.json
sounds.json
```

It also produces the four counters displayed at the top of the README under
`badges/`. Each manifest entry counts as one asset, so a character’s additional
expressions are not counted separately.

The same command maintains content-addressed gallery previews under `previews/`:

- character previews contain the default sprite of the base outfit and of each
  alternate outfit, converted to WebP and bounded to 512 by 512 pixels without
  upscaling or changing its aspect ratio;
- background previews are converted to WebP and bounded to 640 by 360 pixels
  under the same constraints;
- music previews contain the first 15 seconds encoded as a 96 kbit/s MP3;
- sound effects do not receive a separate preview.

The source digest and preview recipe version are part of each generated file
name. Unchanged sources are therefore not re-encoded, while obsolete generated
files are removed. Original assets are always retained and remain the files
downloaded by an import.

To regenerate every output:

```bash
bin/generate_manifests
```

To check that the committed outputs still match the contents of `assets/`:

```bash
bin/generate_manifests --check
```

The manifests are deterministic and contain no generation timestamp. Every
referenced file includes its relative path, MIME type, size, and an SRI digest
in the form `sha256-<base64>`. Web Crypto can recalculate this digest before the
Blob is stored in IndexedDB.

The generator also ensures that every source file is referenced exactly once.
Hidden files are not silently ignored; only the four empty `.gitkeep` files at
the root of the asset directories are reserved.

## Data semantics

`label` is used exclusively to present an entry in the gallery. It must never
replace the target record’s functional name or identifier because those values
act as keys in VN Mode.

Likewise, a manifest `id` identifies only an entry in the remote catalog.
Non-structural metadata such as a character’s `color` or a music track’s
display `title` may, however, be suggested for the target record during import.

## GitHub automation

### Pull request validation

The `.github/workflows/validate-assets.yml` workflow runs for pull requests
against `main`. It:

- rejects any change whose current or previous path is outside `assets/`;
- rejects symbolic links, submodules, and executable files;
- uses `ffprobe` to require exactly one Opus audio stream in every WebM file;
- runs the generator test suite;
- temporarily generates the manifests and verifies their consistency.

Generated manifests must therefore never be included in a contribution.

Preview generation requires FFmpeg and ImageMagick, so both packages are
installed explicitly by the validation and regeneration workflows. FFmpeg also
provides `ffprobe` for WebM codec validation, which can be run locally with:

```bash
bin/validate_webm_audio
```

Validation uses `pull_request_target` so the workflow is loaded from the base
branch. It checks the proposed paths before checking out the contribution and
retains read-only permissions.

### Regeneration after a merge

The `.github/workflows/generate-manifests.yml` workflow runs after an asset or
generator change reaches `main`. It reruns the tests, regenerates previews, the
four manifests and their badges, then creates a `github-actions[bot]` commit if
they have changed.

### Suggested ruleset

A single ruleset targeting `main` can require external contributors to use a
pull request and pass the `Validate asset contribution` check. The repository
owner and GitHub Actions should be added to the bypass list so direct
maintenance remains possible and the bot can publish regenerated outputs.

Force-push and deletion restrictions are intentionally not required for this
repository.

## Local verification

Before changing the generator or its automation, run:

```bash
ruby -Itest test/generator_test.rb
bin/validate_webm_audio
bin/generate_manifests
bin/generate_manifests --check
```

Local generation requires `ffmpeg` and either the `magick` or `convert`
ImageMagick executable.
