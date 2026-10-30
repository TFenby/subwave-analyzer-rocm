# subwave-analyzer-rocm — upstream's heavy analyzer (CLAP + Demucs) with the
# CPU torch wheels swapped for AMD ROCm builds. Nothing else changes: the
# worker picks the GPU through torch.cuda.is_available(), which ROCm torch
# answers for AMD cards.
ARG UPSTREAM_TAG=latest
FROM ghcr.io/perminder-klair/subwave-analyzer-heavy:${UPSTREAM_TAG}

# PyTorch wheel index flavour. Bump when upstream's torch pin outgrows it.
ARG ROCM=6.3

# The venv is root-owned; the base image ends as UID 10001.
USER root
# Read upstream's torch pin from the image so an upstream bump needs no edit
# here. The "+rocm" local version is required: pip treats the installed
# "2.7.1+cpu" as already satisfying a bare "torch==2.7.1".
RUN set -eu; py=/opt/analyzer/venv/bin/python; \
    v=$($py -c 'from importlib.metadata import version; print(version("torch").split("+")[0])'); \
    $py -m pip install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/rocm${ROCM} \
      --extra-index-url https://pypi.org/simple \
      "torch==${v}+rocm${ROCM}" "torchaudio==${v}+rocm${ROCM}" && \
    $py -c "import torch, torchaudio, demucs, transformers; assert torch.version.hip, torch.__version__"
USER 10001:10001
# Links the ghcr package to this repo on push (so it shows under Packages and
# the publish workflow's GITHUB_TOKEN can write to it).
LABEL org.opencontainers.image.source=https://github.com/TFenby/subwave-analyzer-rocm
