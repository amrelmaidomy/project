#!/usr/bin/env bash
set -euo pipefail

# Eclipse Temurin 17, official GitHub release and its published SHA-256.
# A full JDK is required: this cloud image's Java 21 installation is a JRE only.
task_jdk_dir="${JDK_INSTALL_DIR:-/workspace/.tooling/jdk-17}"
task_jdk_cache="${XDG_CACHE_HOME:-/workspace/.cache}/downloads"
task_jdk_filename="OpenJDK17U-jdk_x64_linux_hotspot_17.0.20.1_1.tar.gz"
task_jdk_url="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/$task_jdk_filename"
task_jdk_sha256="3808d1d15e3ec6bd5b84057fb5d84c33d8a1536a258146bcea2e603fc726e08e"

if [[ -x "$task_jdk_dir/bin/javac" && -x "$task_jdk_dir/bin/java" ]]; then
    "$task_jdk_dir/bin/javac" -version
    exit 0
fi
if [[ -e "$task_jdk_dir" ]]; then
    printf 'Refusing to overwrite an existing incomplete JDK at %s\n' "$task_jdk_dir" >&2
    exit 1
fi

mkdir -p "$task_jdk_cache" "$(dirname "$task_jdk_dir")"
task_jdk_archive="$task_jdk_cache/$task_jdk_filename"
if [[ ! -f "$task_jdk_archive" ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 --max-time 300 \
        "$task_jdk_url" --output "$task_jdk_archive.part"
    mv "$task_jdk_archive.part" "$task_jdk_archive"
fi
printf '%s  %s\n' "$task_jdk_sha256" "$task_jdk_archive" | sha256sum --check --status

task_jdk_staging="$(mktemp -d "$(dirname "$task_jdk_dir")/jdk-17-install.XXXXXX")"
trap 'rm -rf "$task_jdk_staging"' EXIT
tar --extract --gzip --file "$task_jdk_archive" --strip-components=1 --directory "$task_jdk_staging"
"$task_jdk_staging/bin/javac" -version
mv "$task_jdk_staging" "$task_jdk_dir"
printf 'Full JDK installed. Set JAVA_HOME=%s for SDK and Gradle commands.\n' "$task_jdk_dir"
