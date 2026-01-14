#!/bin/bash

# AUR Upload Script for shgit-bin
set -e

AUR_USERNAME="0_byte"
PACKAGE_NAME="shgit-bin"

echo "Setting up AUR package for ${PACKAGE_NAME}..."

# Check if SSH key is set up for AUR
if ! ssh -T aur@aur.archlinux.org 2>&1 | grep -q "Welcome"; then
    echo "Error: SSH keys not configured for AUR"
    echo "Please set up SSH keys for aur.archlinux.org"
    exit 1
fi

# Clone the AUR repository (if not already cloned)
if [ ! -d "${PACKAGE_NAME}" ]; then
    echo "Cloning AUR repository..."
    git clone "ssh://aur@aur.archlinux.org/${PACKAGE_NAME}.git"
fi

cd "${PACKAGE_NAME}"

# Copy PKGBUILD from project
cp ../PKGBUILD .

# Generate .SRCINFO (you'll need to update sha256sums after first release)
echo "Generating .SRCINFO..."
makepkg --printsrcinfo > .SRCINFO

# Show what will be committed
echo "Files to be committed:"
git status

echo ""
echo "Ready to upload to AUR!"
echo "Run these commands to complete the upload:"
echo "  cd ${PACKAGE_NAME}"
echo "  git add ."
echo "  git commit -m \"Initial import of shgit-bin v0.1.0\""
echo "  git push"
echo ""
echo "NOTE: You'll need to update the sha256sums in PKGBUILD after creating the first GitHub release"