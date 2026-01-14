# Maintainer: 0_byte <0byte@archlinux.org>
pkgname=shgit-bin
pkgver=0.1.0
pkgrel=1
pkgdesc="A Zig CLI tool for managing personal project overlays with git"
arch=("x86_64")
url="https://github.com/0byte-coding/shgit"
license=("MIT")
provides=("shgit")
conflicts=("shgit")

source_x86_64=("${url}/releases/download/v${pkgver}/shgit-x86_64-linux-gnu.tar.gz")
sha256sums_x86_64=()

package() {
    install -Dm755 "shgit" "${pkgdir}/usr/bin/shgit"
    install -Dm644 "LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
    install -Dm644 "README.md" "${pkgdir}/usr/share/doc/${pkgname}/README.md"
}