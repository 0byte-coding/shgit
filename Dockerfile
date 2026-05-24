FROM debian:13.5-slim

WORKDIR /app

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip xz-utils ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.02 to /opt/zig (matches nix devshell version)
RUN curl -fsSL "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz" \
        -o /tmp/zig.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /opt \
    && mv /opt/zig-x86_64-linux-0.15.2 /opt/zig \
    && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /app

CMD ["/bin/bash"]
