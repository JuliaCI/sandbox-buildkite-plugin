#!/usr/bin/env bats

load "${BATS_PLUGIN_PATH:-$BATS_PATH}/load.bash"

# We always want verbose mode
export BUILDKITE_PLUGIN_SANDBOX_VERBOSE=true

@test "argument parsing" {
    # We need a rootfs URL
    run /plugin/hooks/pre-command
    assert_output --partial "Sandbox requires a rootfs tarball URL"
    assert_failure

    # We need a rootfs treehash
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_URL="https://github.com/staticfloat/Sandbox.jl/releases/download/julia-python3-77eae3ba/julia-python3.tar.gz"
    run /plugin/hooks/pre-command
    assert_output --partial "Sandbox requires a rootfs treehash"
    assert_failure

    # We need an actual treehash-like thing
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_TREEHASH="foo"
    run /plugin/hooks/pre-command
    assert_output --partial "Sandbox rootfs treehash not 40 hexadecimal characters"
    assert_failure
}

@test "bash wrapper" {
    dir="$(mktemp -d)"
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_URL="https://github.com/staticfloat/Sandbox.jl/releases/download/julia-python3-77eae3ba/julia-python3.tar.gz"
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_TREEHASH="c0f2c53b857189e1c8378bd37c3b620ea4843e07"
    export BUILDKITE_PLUGIN_SANDBOX_SHELL="${dir}/bash"
    export BUILDKITE_BUILD_PATH="${dir}"
    # The hook moves the shell it replaces aside
    cp "$(command -v bash)" "${dir}/bash"

    # Generate the bash wrapper
    run /plugin/hooks/pre-command
    assert_output --partial "--- Instantiating sandbox environment"
    assert_success

    # Use the bash wrapper to run something
    [[ -f "${dir}/bash" ]]
    run "${dir}/bash" -c "echo hello world; echo foo > ${dir}/foo"
    assert_output --partial "hello world"
    assert_success
    [[ -f "${dir}/foo" ]]
    [[ "$(cat ${dir}/foo)" == "foo" ]]

    # Test that we can extract the `--persist` directive
    [[ -n "$(sed -n -E 's/.*--persist ([^ ]+).*/\1/p' <"${dir}/bash")" ]]
}

# A small artifact the Pkg server serves (Attr_jll v2.6.0, x86_64-linux-gnu), used as a
# stand-in rootfs: these tests only exercise the download, not the sandbox.
ATTR_TREEHASH="cadce0dcecf495070a30b266c817c1f631d5bf24"
ATTR_URL="https://github.com/JuliaBinaryWrappers/Attr_jll.jl/releases/download/Attr-v2.6.0+0/Attr.v2.6.0.x86_64-linux-gnu.tar.gz"

# Point the hook at a scratch shell, record annotations, and download into an empty depot
# in front of the caller's, which keeps the installed packages but not the fixture
setup_download_test() {
    dir="$(mktemp -d)"
    export BUILDKITE_PLUGIN_SANDBOX_SHELL="${dir}/bash"
    export BUILDKITE_BUILD_PATH="${dir}"
    cp "$(command -v bash)" "${dir}/bash"
    mkdir "${dir}/bin"
    printf '#!/bin/sh\necho "$@" >> %s/annotations\n' "${dir}" > "${dir}/bin/buildkite-agent"
    chmod +x "${dir}/bin/buildkite-agent"
    export PATH="${dir}/bin:${PATH}"
    export JULIA_DEPOT_PATH="${dir}/depot:${JULIA_DEPOT_PATH:-}"
}

@test "rootfs from the Pkg server" {
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_URL="https://github.com/JuliaCI/sandbox-buildkite-plugin/releases/download/none/none.tar.gz"
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_TREEHASH="${ATTR_TREEHASH}"
    setup_download_test

    run /plugin/hooks/pre-command
    assert_success
    assert_output --regexp "Downloaded rootfs from [^ ]*/artifact/${ATTR_TREEHASH}"
}

@test "rootfs from the URL without a Pkg server" {
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_URL="${ATTR_URL}"
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_TREEHASH="${ATTR_TREEHASH}"
    export JULIA_PKG_SERVER=""
    setup_download_test

    run /plugin/hooks/pre-command
    assert_success
    refute_output --partial "/artifact/"
    assert_output --partial "Downloaded rootfs from ${ATTR_URL}"
}

@test "rootfs from the URL when the Pkg server doesn't have it" {
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_URL="${ATTR_URL}"
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_TREEHASH="${ATTR_TREEHASH}"
    # stands in for a Pkg server: answers 404 for `/artifact/<hash>`
    export JULIA_PKG_SERVER="https://github.com/JuliaCI/sandbox-buildkite-plugin/releases/download/none"
    setup_download_test

    run /plugin/hooks/pre-command
    assert_success
    assert_output --partial "Downloading rootfs from ${JULIA_PKG_SERVER}/artifact/${ATTR_TREEHASH}"
    assert_output --partial "Downloaded rootfs from ${ATTR_URL}"
}

@test "wrong rootfs treehash" {
    # the URL serves Attr, the Pkg server doesn't know this hash
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_URL="${ATTR_URL}"
    export BUILDKITE_PLUGIN_SANDBOX_ROOTFS_TREEHASH="cadce0dcecf495070a30b266c817c1f631d5bf25"
    setup_download_test

    run /plugin/hooks/pre-command
    assert_failure
    assert_output --partial "Tree Hash Mismatch"
    grep -q -- "- .*/artifact/${BUILDKITE_PLUGIN_SANDBOX_ROOTFS_TREEHASH}: " "${dir}/annotations"
    grep -q -- "- ${ATTR_URL}: .*Tree Hash Mismatch" "${dir}/annotations"
    # the real shell stays in place
    [[ -f "${dir}/bash" ]]
}
