# FirmAE-pro

FirmAE-pro is an enhanced and extended version of FirmAE, an automated firmware emulation framework for firmware analysis, debugging, and research.

This repository contains a curated public source snapshot of the March 2026 release.

## Overview

Compared with the original FirmAE workflow, this customized version focuses on broader platform compatibility and more practical runtime analysis capabilities.

It is intended for firmware emulation, debugging, reverse engineering, and controlled security research workflows.

## Features

- Support for multiple kernel variants
- Added `arm64` firmware emulation support
- Support for firmware decryption workflows
- Support for patching and hook-based analysis
- Improved debugging-oriented emulation workflow
- Better suitability for emulation-assisted firmware reversing

## Supported Architectures

- `mipseb`
- `mipsel`
- `armel`
- `armhf`
- `aarch64`

## Repository Layout

- `scripts/` - emulation, setup, networking, and kernel build helpers
- `sources/` - helper sources such as console, extractor, scraper, and libnvram components
- `analyses/` - analyzer, fuzzer, and RouterSploit-related components
- `binaries/` - runtime helpers and selected prebuilt binaries used by the framework
- `core/` - helper tools used during setup and execution
- `database/` - database schema and related files
- `assets/` - README images and supporting media

## Quick Start

1. Install dependencies:

```bash
./download.sh
./install.sh
```

2. Initialize the environment:

```bash
./init.sh
```

3. Run firmware emulation:

```bash
sudo ./run.sh -c <brand> <firmware>
```

4. Use debug mode when needed:

```bash
sudo ./run.sh -d <brand> <firmware>
```

## Docker

This project can also run through Docker.

The repository includes:

- `core/Dockerfile` - container image definition
- `docker-init.sh` - builds the Docker image
- `docker-helper.py` - runs emulation, analysis, and debug workflows inside containers

### Docker prerequisites

- Docker installed on the host
- Host PostgreSQL initialized through the normal setup flow
- Privileged container support enabled

The Docker helper mounts the local repository into the container and relies on the host PostgreSQL service.

### Build the Docker image

```bash
./docker-init.sh
```

This builds the core image with the tag `fcore`.

### Run emulation in Docker

Check emulation:

```bash
python3 docker-helper.py -ec <brand> <firmware>
```

Run emulation and analysis:

```bash
python3 docker-helper.py -ea <brand> <firmware>
```

Run debug mode:

```bash
python3 docker-helper.py -ed <firmware>
```

Interactive run mode:

```bash
python3 docker-helper.py -er <firmware>
```

## Notes

- Local AI/session state, scratch data, heavyweight kernel source trees, and internal working metadata are intentionally excluded from the public repository layout.

## Disclaimer

This project is intended for authorized firmware research, debugging, security analysis, and educational use only.

Users are responsible for ensuring that all analysis, emulation, decryption, patching, and hooking activities comply with applicable laws, regulations, and authorization requirements.
