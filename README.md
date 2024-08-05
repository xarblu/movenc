# MOVie ENCoder

Encode movies, shows and other media in a simple unified way.

## Features
- Tuned to give near lossless results (at acceptable speeds on a AMD Ryzen 7 7800X3D)
- Audio track auto-selection (optionally by language)
- Automatic deinterlacing (via bwdif)
- Automatic crop detection
- Profiles
  - Video
    - libx264
    - libx265
    - copy (default)
  - Audio
    - libfdk_aac
    - copy (default)

## Basic Usage
```
movenc.sh [<args>...] <infile> [<outfile>]
```

## Dependencies
- ffmpeg with codecs you want to use (all currently supported libx264, libx265, libfdk_aac)
- jq
- mkvpropedit (mkvtoolnix)
- mediainfo

## Roadmap
- [ ] [ntfy.sh](https://ntfy.sh/) integration
- [ ] More Profiles
  - [ ] Video
    - [ ] AV1
  - [ ] Audio
    - [ ] OPUS
- [ ] Subtitle track auto selection (can't rank these by quality; would likely only be by language)
