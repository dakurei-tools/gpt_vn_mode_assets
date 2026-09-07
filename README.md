# ChatGPT VN Mode Assets

![Characters](badges/characters.svg)
![Backgrounds](badges/backgrounds.svg)
![Music](badges/music.svg)
![SFX](badges/sounds.svg)

A community library of images, music, and sound effects ready to be imported
into ChatGPT VN Mode.

This repository contains only the asset collection. The ChatGPT VN Mode source
code remains private and is not distributed here.

## Contributing

1. Fork the repository and create a branch for your contribution.
2. Add your files only to the appropriate directory under `assets/`.
3. Follow the directory structure and naming conventions below.
4. Open a pull request against `main`.

Do not edit the JSON files at the repository root. They are checked and
generated automatically from the contents of `assets/`.

### Organizing files

```text
assets/
├── characters/
├── backgrounds/
├── music/
└── sounds/
```

You may create as many categories and subcategories as needed under these four
directories. For example:

```text
assets/characters/Anime/Evangelion/
assets/backgrounds/Video_Games/Skyrim/
```

Use `_` instead of spaces in directory and file names. These underscores are
converted back to spaces in the gallery.

Images may use AVIF, GIF, JPEG, PNG, or WebP. Audio files may use MP3, WAV, or
WebM; a WebM file must contain exactly one Opus audio track.

### Characters and expressions

A character’s main image is used as their default expression:

```text
assets/characters/Anime/Evangelion/Asuka_Langley__e65a32.webp
```

The `__e65a32` suffix is optional. It defines a suggested default color using
six hexadecimal digits without the `#` prefix.

To add expressions, create a directory next to the main image with the exact
same name, minus the file extension:

```text
assets/characters/Anime/Evangelion/
├── Asuka_Langley__e65a32.webp
└── Asuka_Langley__e65a32/
    ├── happy.webp
    └── sad.webp
```

Recognized expressions are `happy`, `sad`, `mischievous`, `surprised`,
`embarrassed`, and `angry`. Do not place a `default` file in this directory:
the main image already serves that purpose.

### Music

The file name becomes the label shown in the gallery:

```text
Battle_Theme.mp3
```

If the title shown after import should be different, append it after a double
underscore:

```text
Boss_Battle__One_Winged_Angel.mp3
```

This track will appear as “Boss Battle” in the gallery and suggest “One Winged
Angel” as its title. The double underscore convention does not apply to
backgrounds or sound effects.

Names derived from files are used only to present assets in the gallery. They
do not rename characters, backgrounds, or sounds already configured in ChatGPT
VN Mode.
