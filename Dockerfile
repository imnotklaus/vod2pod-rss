# ---------- Build Stage ----------
FROM --platform=$BUILDPLATFORM rust:1.81 as builder

ARG BUILDPLATFORM
ARG TARGETPLATFORM

# Determine Rust target based on platform
RUN if [ "$TARGETPLATFORM" = "linux/arm/v7" ]; then \
        echo "armv7-unknown-linux-gnueabihf" > /rust_platform.txt; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        echo "aarch64-unknown-linux-gnu" > /rust_platform.txt; \
    elif [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        echo "x86_64-unknown-linux-gnu" > /rust_platform.txt; \
    else \
        rustup target list --installed | head -n 1 > /rust_platform.txt; \
    fi

# Install toolchains for ARM builds if needed
RUN if echo "$TARGETPLATFORM" | grep -q 'arm'; then \
        apt-get update && \
        apt-get install -y build-essential gcc gcc-arm* gcc-aarch* && \
        apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

RUN rustup target add $(cat /rust_platform.txt)

# Create dummy project to initialize dependencies
RUN cd /tmp && USER=root cargo new --bin vod2pod
WORKDIR /tmp/vod2pod

# Prepare build files
COPY Cargo.toml ./
RUN sed '/\[dev-dependencies\]/,/^$/d' Cargo.toml > Cargo.toml.tmp && mv Cargo.toml.tmp Cargo.toml
RUN cargo fetch

# Copy actual project files
COPY .cargo/ .cargo/
COPY src/ src/
COPY set_version.sh version.txt* ./
COPY templates/ templates/

RUN sh set_version.sh
RUN cargo build --release --target $(cat /rust_platform.txt)

# ---------- Runtime Stage ----------
FROM --platform=$TARGETPLATFORM debian:bookworm-slim as app

ARG BUILDPLATFORM
ARG TARGETPLATFORM

# Set non-interactive frontend
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        curl \
        ca-certificates \
        ffmpeg \
        redis-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp via pip (version should be pinned in requirements.txt)
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy app binary and templates from build stage
COPY --from=builder /tmp/vod2pod/target/*/release/app /usr/local/bin/vod2pod
COPY --from=builder /tmp/vod2pod/templates/ ./templates

# Validate binary
RUN vod2pod --version || (echo "vod2pod failed to run" && exit 1)

EXPOSE 8080
CMD ["vod2pod"]
