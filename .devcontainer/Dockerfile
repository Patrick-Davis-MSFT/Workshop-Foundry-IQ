FROM python:3.12.1-bookworm

ARG DEBIAN_FRONTEND=noninteractive

# Install base utilities and prerequisites for Microsoft package repos.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        apt-transport-https \
        gnupg \
        lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install PowerShell from Microsoft's Debian repository.
RUN curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# Install Azure CLI using Microsoft's install script.
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

WORKDIR /workspaces/Workshop-Foundry-AI
