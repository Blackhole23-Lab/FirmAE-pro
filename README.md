# FirmAE-pro

FirmAE-pro is an enhanced and extended version of FirmAE, an automated firmware emulation framework.

This customized build adds broader platform coverage and more practical analysis features for firmware research and debugging workflows.

## Overview

FirmAE-pro is a customized firmware emulation toolkit designed for practical device analysis, debugging, and research workflows.

Compared with the original FirmAE workflow, this version focuses on broader platform compatibility and stronger runtime analysis capabilities.

## Features

- Support for multiple kernel variants
- Added `arm64` firmware emulation support
- Support for firmware decryption workflows
- Support for patching and hook-based analysis
- Improved debugging-oriented emulation workflow
- Better suitability for emulation-assisted firmware reversing

## Supported Architectures

- `arm`
- `arm64`
- Additional architectures may be supported depending on the included kernels and runtime environment

## Usage

This repository currently serves as an archive distribution repository for the packaged FirmAE-pro release.

The main package included here is:

- `FirmAE-20260304.tar.zst`

Typical usage workflow:

1. Extract the package
2. Prepare the required emulation environment
3. Load the target firmware image
4. Run emulation, debugging, or analysis tasks such as decryption, patching, and hooking

## Screenshots

The screenshot below shows a successful emulation and debugger workflow in action.

![FirmAE-pro demo](assets/firmae-demo.jpg)

## Package Contents

- `FirmAE-20260304.tar.zst`
- `FirmAE-20260304.tar.zst.sha256`

## Integrity

SHA-256:

`8b108b2ec42f45ab29411e1a846e39ca1eae60db5efe213451c1ec32795443ba`

## Disclaimer

This project is intended for authorized firmware research, debugging, security analysis, and educational use only.

Users are responsible for ensuring that all analysis, emulation, decryption, patching, and hooking activities comply with applicable laws, regulations, and authorization requirements.
