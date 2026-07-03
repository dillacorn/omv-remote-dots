````markdown
# NVIDIA Driver Installation

## Single command

```bash
sudo apt update && sudo apt install -y \
    dkms \
    build-essential \
    "linux-headers-$(uname -r)" \
    firmware-misc-nonfree \
    nvidia-driver \
    nvidia-smi \
    nvidia-container-toolkit \
    libcuda1 \
    libnvcuvid1 \
    libnvidia-encode1 \
    ffmpeg && \
sudo nvidia-ctk runtime configure --runtime=docker && \
sudo systemctl restart docker
````

Reboot:

```bash
sudo reboot
```

This installs the NVIDIA driver, Docker NVIDIA runtime, CUDA runtime library, NVDEC/NVENC libraries, and FFmpeg.
