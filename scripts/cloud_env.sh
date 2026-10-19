#!/usr/bin/env bash
# Source this file in cloud shells; it never changes HOME or embeds credentials.
export MA3AK_TOOLING="${MA3AK_TOOLING:-/workspace/.tooling}"
export PUB_CACHE="${PUB_CACHE:-/workspace/.cache/pub}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/workspace/.cache/config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"
export ANALYZER_STATE_LOCATION_OVERRIDE="${ANALYZER_STATE_LOCATION_OVERRIDE:-/workspace/.cache/dart-server}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/workspace/.cache/gradle}"
export ANDROID_HOME="${ANDROID_HOME:-$MA3AK_TOOLING/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-/workspace/.cache/android}"
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/workspace/.cache/uv}"
export PATH="$MA3AK_TOOLING/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
if [[ -d "$MA3AK_TOOLING/jdk-17" ]]; then
  export JAVA_HOME="$MA3AK_TOOLING/jdk-17"
  export PATH="$JAVA_HOME/bin:$PATH"
fi
# Use the system-managed CA trust (including the cloud HTTPS proxy CA) while
# retaining certificate and hostname verification in the downloaded JDK.
if [[ -r /etc/ssl/certs/java/cacerts && "${JAVA_TOOL_OPTIONS:-}" != *javax.net.ssl.trustStore=* ]]; then
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts"
fi
if [[ -d "$MA3AK_TOOLING/lib" ]]; then
  export LD_LIBRARY_PATH="$MA3AK_TOOLING/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
