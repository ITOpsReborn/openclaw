---
summary: "Intel Arc B60 Pro GPU passthrough for Docker on WSL2: host setup, driver requirements, Compose profile, verification, and troubleshooting"
read_when:
  - Setting up Intel Arc GPU acceleration in Docker on WSL2
  - Enabling /dev/dri passthrough for Intel GPU containers
  - Troubleshooting Intel GPU visibility inside Docker
title: "Intel Arc GPU on WSL2"
---

OpenClaw can use Intel Arc and Intel integrated GPUs for hardware-accelerated workloads when running inside Docker on WSL2. This guide covers host prerequisites, driver setup, Docker Compose configuration, and how to verify that the GPU is visible and active inside the container.

## Prerequisites

### Windows host

- **Windows 11 22H2 or later** (recommended) or Windows 10 21H2 with the Intel GPU driver update.
- **Intel Arc GPU driver** — install the latest [Intel Arc & Iris Xe Graphics driver](https://www.intel.com/content/www/us/en/download/747001/intel-arc-iris-xe-graphics-whql-windows.html) from Intel's download center. The WHQL-signed driver includes the WSL DirectX / DXGI compute driver needed for `/dev/dri` passthrough.
- **WSL2** with a kernel that supports `/dev/dri` export — WSL2 kernel 5.10.43+ (ships with Windows 11 and the April 2021 Windows 10 update). Run `uname -r` inside WSL2 to confirm.

### Docker

- **Docker Desktop 4.x** with the WSL2 backend enabled (Settings → General → "Use the WSL 2 based engine").
- Docker Desktop automatically shares `/dev/dri` nodes from WSL2 into containers when they are present on the host WSL2 distro.

### WSL2 distro

Your WSL2 distro (e.g. Ubuntu 24.04) must have `/dev/dri` devices present after the driver is installed on the host. Verify from within WSL2:

```bash
ls -la /dev/dri
```

Expected output (device names and minor numbers may vary):

```
total 0
drwxr-xr-x  2 root root          80 Jul 16 10:00 .
drwxr-xr-x 18 root root        3680 Jul 16 10:00 ..
crw-rw----  1 root video 226,   0 Jul 16 10:00 card0
crw-rw----  1 root render 226, 128 Jul 16 10:00 renderD128
```

If `/dev/dri` is absent, install or reinstall the Intel Arc Windows driver, then restart WSL2:

```powershell
wsl --shutdown
```

## Build the Intel GPU image

The default OpenClaw Docker image does not include Intel GPU userspace libraries to keep the base image small. Build an Intel GPU-enabled variant with:

```bash
docker build \
  --build-arg OPENCLAW_INSTALL_INTEL_GPU=1 \
  -t openclaw:intel-gpu \
  .
```

This installs the following Debian packages into the runtime image (~30 MB added):

| Package | Purpose |
|---|---|
| `intel-media-va-driver-non-free` | Intel VA-API hardware acceleration driver |
| `libva2`, `libva-drm2` | VA-API runtime libraries |
| `intel-opencl-icd` | Intel OpenCL runtime (Compute Runtime) |
| `clinfo` | OpenCL diagnostics |
| `vainfo` | VA-API diagnostics |

## Compose configuration

The repository ships an `intel-gpu` Docker Compose profile in `docker-compose.yml`. It adds:

- **`devices: /dev/dri:/dev/dri`** — mounts all DRM/KMS nodes into the container.
- **`group_add`** — adds the container process to the host `render` (default GID 109) and `video` (default GID 44) groups so non-root users can open the render node.
- **`OPENCLAW_GPU_BACKEND=intel`** — signals the Gateway that Intel GPU acceleration is requested.

### Determine host group IDs

The group IDs for `render` and `video` vary by distro. Check from WSL2:

```bash
stat -c '%g' /dev/dri/renderD128   # RENDER_GID
stat -c '%g' /dev/dri/card0         # VIDEO_GID
```

Add the results to your `.env` file:

```bash
RENDER_GID=109
VIDEO_GID=44
```

### Launch with GPU acceleration

```bash
# Set the GPU image in .env
echo 'OPENCLAW_IMAGE=openclaw:intel-gpu' >> .env
echo 'OPENCLAW_GPU_BACKEND=intel' >> .env

# Start the Intel GPU-enabled Gateway service
docker compose --profile intel-gpu up -d openclaw-gateway-intel-gpu
```

The `intel-gpu` profile starts `openclaw-gateway-intel-gpu` instead of `openclaw-gateway`. The two services are otherwise equivalent (same image, same ports). You do not need to stop the default `openclaw-gateway` service before switching to the GPU variant — use only one at a time.

## Verify GPU acceleration

Use the bundled check script from inside a running container:

```bash
docker compose --profile intel-gpu exec openclaw-gateway-intel-gpu \
  bash /app/scripts/check-intel-gpu.sh
```

Or with `docker exec`:

```bash
docker exec <container-name> bash /app/scripts/check-intel-gpu.sh
```

Successful output looks like:

```
==> OpenClaw Intel GPU check

--- /dev/dri device nodes ---
  [PASS] /dev/dri directory exists
  [PASS] /dev/dri/renderD128 is readable

--- OPENCLAW_GPU_BACKEND ---
  [PASS] OPENCLAW_GPU_BACKEND=intel

--- VA-API (vainfo) ---
  [PASS] vainfo reports a working VA-API driver
    libva info: VA-API version 1.19.0
    libva info: Trying to open /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so
    ...

--- OpenCL (clinfo) ---
  [PASS] clinfo reports 1 OpenCL platform(s)
    Platform #0: Intel(R) OpenCL HD Graphics
    ...

==> Result: 5 passed, 0 failed
```

## GPU backend env var

Set `OPENCLAW_GPU_BACKEND` to signal GPU preference to the Gateway runtime:

| Value | Behavior |
|---|---|
| *(unset)* | CPU path; GPU code not activated |
| `intel` | Request Intel GPU acceleration via VA-API / OpenCL; falls back to CPU if `/dev/dri` is unavailable |
| `cpu` | Explicit CPU-only; disables any GPU detection |

The Gateway logs which path is active at startup. If `/dev/dri/renderD128` is not readable at startup, the Gateway logs a warning and falls back to CPU automatically.

## CPU fallback

The GPU path is **optional**. If `OPENCLAW_GPU_BACKEND` is not set, or if the requested GPU is unavailable at startup, OpenClaw falls back to its standard CPU path with no impact on correctness. The fallback is logged at startup:

```
[gpu] OPENCLAW_GPU_BACKEND=intel requested but /dev/dri/renderD128 is not accessible — falling back to CPU
```

Existing CPU-only Docker workflows, CI environments, macOS, and Windows-native setups are not affected by these changes.

## Troubleshooting

### `/dev/dri` is missing inside the container

Confirm that `/dev/dri` is present in the WSL2 distro first:

```bash
ls /dev/dri
```

If absent, the Intel Arc Windows driver is not installed or does not include the WSL compute extension. Install the latest [Intel Arc driver](https://www.intel.com/content/www/us/en/download/747001/intel-arc-iris-xe-graphics-whql-windows.html) from Intel's download center, then run `wsl --shutdown` from PowerShell and restart your distro.

### Permission denied on `/dev/dri/renderD128`

The container process is not in the `render` group. Find the correct GID:

```bash
stat -c '%g' /dev/dri/renderD128
```

Set `RENDER_GID=<value>` in `.env` and recreate the container:

```bash
docker compose --profile intel-gpu up -d --force-recreate openclaw-gateway-intel-gpu
```

### `vainfo` reports no driver

The Intel VA-API driver package (`intel-media-va-driver-non-free`) is not installed. Rebuild the image:

```bash
docker build --build-arg OPENCLAW_INSTALL_INTEL_GPU=1 -t openclaw:intel-gpu .
```

### `clinfo` reports no platforms

The Intel OpenCL ICD (`intel-opencl-icd`) is not installed, or the render device is not accessible. Rebuild with `OPENCLAW_INSTALL_INTEL_GPU=1` and verify render group membership.

### Docker Desktop does not pass through `/dev/dri`

Docker Desktop 4.x with the WSL2 backend automatically forwards `/dev/dri` from the WSL2 distro. If it does not:

1. Open Docker Desktop → Settings → Resources → WSL Integration and enable the integration for your distro.
2. Restart Docker Desktop.
3. Run `docker run --rm --device /dev/dri:/dev/dri ubuntu:24.04 ls /dev/dri` to test directly.

### WSL2 GPU passthrough on Windows 10

GPU passthrough for compute workloads (DirectX 12, DXGI) requires the **Windows 10 21H2** update and the Intel Arc GPU driver with WSL DirectX support. Older Windows 10 versions only export the D3D12 surface — OpenCL and VA-API will not work. Upgrade to Windows 11 for the best experience.

## Related

- [Windows setup](/platforms/windows)
- [Linux platform](/platforms/linux)
- [Docker install guide](/install/docker)
- [Gateway configuration](/gateway/configuration)
