#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT/build"
RELEASE_ROOT="$BUILD_ROOT/release"
STAGED_APP="$RELEASE_ROOT/Kinetics.app"
STAGED_HELPER_APP="$STAGED_APP/Contents/Library/LoginItems/Kinetics Login Launcher.app"
INSTALL_APP="/Applications/Kinetics.app"
BACKUP_ROOT="/Users/YOUR_USERNAME/.local/state/kinetics-backups"

VERSION="0.1.5"
BUILD_NUMBER="6"
SIGNING_IDENTITY="12F05E96DC78DEF756913A2D574FF98F6C5BD485"
SIGNING_IDENTITY_LOWER="12f05e96dc78def756913a2d574ff98f6c5bd485"
SIGNING_NAME="Ivo Market Dev"
CERTIFICATE_SHA256="0B81FCF31A1B34E3EBA3966EDE1328EB38FD0A49439CBE8C2BC4497FBE0B997B"
MAIN_BUNDLE_ID="com.ivogundlach.Kinetics"
HELPER_BUNDLE_ID="com.ivogundlach.Kinetics.LoginLauncher"
MAIN_EXECUTABLE="$STAGED_APP/Contents/MacOS/Kinetics"
HELPER_EXECUTABLE="$STAGED_HELPER_APP/Contents/MacOS/Kinetics Login Launcher"
MAIN_REQUIREMENT="=designated => identifier \"$MAIN_BUNDLE_ID\" and certificate leaf = H\"$SIGNING_IDENTITY_LOWER\""
HELPER_REQUIREMENT="=designated => identifier \"$HELPER_BUNDLE_ID\" and certificate leaf = H\"$SIGNING_IDENTITY_LOWER\""

usage() {
    echo "usage: $0 [--install]" >&2
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_binaries() {
    local bin_dir="$1"
    MAIN_BIN="$bin_dir/Kinetics"
    HELPER_BIN="$bin_dir/KineticsLoginLauncher"
    [[ -n "$MAIN_BIN" && -x "$MAIN_BIN" ]] || die "release Kinetics binary not found under $ROOT/.build"
    [[ -n "$HELPER_BIN" && -x "$HELPER_BIN" ]] || die "release KineticsLoginLauncher binary not found under $ROOT/.build"
}

print_binary_paths() {
    echo "Kinetics main binary: $MAIN_BIN"
    echo "Kinetics login helper binary: $HELPER_BIN"
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print toupper($1)}'
}

plist_raw() {
    plutil -extract "$2" raw -o - "$1"
}

available_bytes() {
    df -Pk "$1" | awk 'NR == 2 { print $4; exit }'
}

preflight_install() {
    require_command swift
    require_command codesign
    require_command security
    require_command ditto
    require_command plutil
    require_command lipo
    require_command shasum
    require_command pgrep
    require_command pkill
    require_command python3
    [[ -x /usr/bin/openssl ]] || die "required command not found: /usr/bin/openssl"

    if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then
        [[ -d "$INSTALL_APP" && ! -L "$INSTALL_APP" ]] || die "installed path is not a canonical directory: $INSTALL_APP"
    fi
    [[ -d /Applications && -w /Applications ]] || die "/Applications is not writable"

    mkdir -p "$RELEASE_ROOT" "$BACKUP_ROOT"
    local build_free backup_free
    build_free="$(available_bytes "$BUILD_ROOT")"
    backup_free="$(available_bytes "$BACKUP_ROOT")"
    [[ "$build_free" =~ ^[0-9]+$ && "$build_free" -ge 65536 ]] || die "insufficient build-volume space"
    [[ "$backup_free" =~ ^[0-9]+$ && "$backup_free" -ge 65536 ]] || die "insufficient backup-volume space"

    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    grep -Fq " $SIGNING_IDENTITY \"$SIGNING_NAME\"" <<<"$identities" || \
        die "exact signing identity unavailable: $SIGNING_IDENTITY ($SIGNING_NAME)"

    local cert_dir cert_pem cert_file cert_sha1 cert_sha256 matched_sha256
    cert_dir="$(mktemp -d "${TMPDIR:-/tmp}/kinetics-cert.XXXXXX")"
    cert_pem="$cert_dir/all.pem"
    if ! security find-certificate -a -p -c "$SIGNING_NAME" >"$cert_pem" 2>/dev/null; then
        rm -rf "$cert_dir"
        die "certificate lookup failed for $SIGNING_NAME"
    fi
    awk -v outdir="$cert_dir" '
        /-----BEGIN CERTIFICATE-----/ {
            count++
            file=sprintf("%s/cert-%d.pem", outdir, count)
        }
        file != "" { print > file }
        /-----END CERTIFICATE-----/ {
            close(file)
            file=""
        }
    ' "$cert_pem"
    matched_sha256=""
    for cert_file in "$cert_dir"/cert-*.pem; do
        [[ -f "$cert_file" ]] || continue
        cert_sha1="$(/usr/bin/openssl x509 -in "$cert_file" -noout -fingerprint -sha1 2>/dev/null \
            | awk -F= 'NF > 1 { gsub(":", "", $2); print toupper($2); exit }')"
        cert_sha256="$(/usr/bin/openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null \
            | awk -F= 'NF > 1 { gsub(":", "", $2); print toupper($2); exit }')"
        if [[ "$cert_sha1" == "$SIGNING_IDENTITY" ]]; then
            matched_sha256="$cert_sha256"
            break
        fi
    done
    rm -rf "$cert_dir"
    [[ -n "$matched_sha256" ]] || die "certificate SHA-1 fingerprint mismatch (expected $SIGNING_IDENTITY)"
    [[ "$matched_sha256" == "$CERTIFICATE_SHA256" ]] || \
        die "certificate SHA-256 fingerprint mismatch (expected $CERTIFICATE_SHA256, got ${matched_sha256:-missing})"
}

assemble_staged_app() {
    rm -rf "$STAGED_APP"
    mkdir -p "$STAGED_APP/Contents/MacOS" \
             "$STAGED_APP/Contents/Resources" \
             "$STAGED_HELPER_APP/Contents/MacOS"

    cp "$MAIN_BIN" "$MAIN_EXECUTABLE"
    cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
    cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
    chmod +x "$MAIN_EXECUTABLE"

    cp "$HELPER_BIN" "$HELPER_EXECUTABLE"
    cp "$ROOT/Resources/LoginLauncher-Info.plist" "$STAGED_HELPER_APP/Contents/Info.plist"
    chmod +x "$HELPER_EXECUTABLE"

    plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
    plutil -lint "$STAGED_HELPER_APP/Contents/Info.plist" >/dev/null
}

verify_no_unexpected_executables() {
    local app="$1" expected_main="$2" expected_helper="$3" path
    while IFS= read -r -d '' path; do
        [[ "$path" == "$expected_main" || "$path" == "$expected_helper" ]] || \
            { echo "error: unexpected nested executable: $path" >&2; return 1; }
    done < <(find "$app/Contents" -type f -perm -111 -print0)
}

verify_leaf_fingerprint() {
    local app="$1" actual
    if ! actual="$(swift - "$app" <<'SWIFT'
import Foundation
import Security
import CryptoKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: certificate-sha256 <signed-code>\n", stderr)
    exit(64)
}

let path = CommandLine.arguments[1]
var staticCode: SecStaticCode?
let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
guard createStatus == errSecSuccess, let staticCode else {
    fputs("SecStaticCodeCreateWithPath failed\n", stderr)
    exit(1)
}

var signingInformation: CFDictionary?
let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation)
guard infoStatus == errSecSuccess, let signingInformation else {
    fputs("SecCodeCopySigningInformation failed\n", stderr)
    exit(1)
}

guard let info = signingInformation as? [String: Any],
      let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let leaf = certificates.first else {
    fputs("signing certificate chain missing\n", stderr)
    exit(1)
}

let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
print(digest.map { String(format: "%02X", $0) }.joined())
SWIFT
    )"; then
        echo "error: unable to read leaf certificate for $app" >&2
        return 1
    fi
    [[ "$actual" == "$CERTIFICATE_SHA256" ]] || {
        echo "error: leaf certificate fingerprint mismatch for $app (got $actual)" >&2
        return 1
    }
}

verify_signed_bundle() {
    local app="$1" expected_id="$2" expected_requirement="$3" expected_executable="$4" cert_prefix="$5"
    [[ -d "$app" && -x "$expected_executable" ]] || { echo "error: bundle/executable missing: $app" >&2; return 1; }
    [[ "$(plist_raw "$app/Contents/Info.plist" CFBundleIdentifier)" == "$expected_id" ]] || {
        echo "error: bundle identifier mismatch: $app" >&2
        return 1
    }
    [[ "$(plist_raw "$app/Contents/Info.plist" CFBundleExecutable)" == "$(basename "$expected_executable")" ]] || {
        echo "error: executable path mismatch: $app" >&2
        return 1
    }
    [[ "$(plist_raw "$app/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" ]] || {
        echo "error: short version mismatch: $app" >&2
        return 1
    }
    [[ "$(plist_raw "$app/Contents/Info.plist" CFBundleVersion)" == "$BUILD_NUMBER" ]] || {
        echo "error: build number mismatch: $app" >&2
        return 1
    }

    codesign --verify --verbose=2 --requirements "$expected_requirement" "$app" >/dev/null || {
        echo "error: designated requirement verification failed: $app" >&2
        return 1
    }
    codesign --verify --deep --strict --verbose=2 "$app" >/dev/null || {
        echo "error: deep strict verification failed: $app" >&2
        return 1
    }
    local requirement_text
    requirement_text="$(codesign --display --requirements - "$app" 2>&1 || true)"
    grep -Fq "designated =>" <<<"$requirement_text" || { echo "error: designated requirement text missing: $app" >&2; return 1; }
    grep -Fq "identifier \"$expected_id\"" <<<"$requirement_text" || { echo "error: designated requirement identifier missing: $app" >&2; return 1; }
    grep -Fq "certificate leaf = H\"$SIGNING_IDENTITY_LOWER\"" <<<"$requirement_text" || {
        echo "error: designated requirement certificate missing: $app" >&2
        return 1
    }
    if codesign --display --entitlements :- "$app" 2>/dev/null | grep -q '<'; then
        echo "error: unexpected entitlements: $app" >&2
        return 1
    fi
    local architectures
    architectures="$(lipo -archs "$expected_executable")"
    [[ -n "$architectures" ]] || { echo "error: architecture information missing: $expected_executable" >&2; return 1; }
    echo "Verified $app (architectures: $architectures; leaf SHA-256: $CERTIFICATE_SHA256)"
    verify_leaf_fingerprint "$app" "$cert_prefix" || return 1
}

backup_existing_app() {
    BACKUP_ARCHIVE=""
    BACKUP_EXTRACT=""
    if [[ ! -e "$INSTALL_APP" ]]; then return 0; fi

    local backup_dir
    backup_dir="$(mktemp -d "$BACKUP_ROOT/release-XXXXXX")"
    BACKUP_ARCHIVE="$backup_dir/Kinetics.app.zip"
    ditto -c -k --sequesterRsrc --keepParent "$INSTALL_APP" "$BACKUP_ARCHIVE"
    BACKUP_EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/kinetics-backup.XXXXXX")"
    ditto -x -k "$BACKUP_ARCHIVE" "$BACKUP_EXTRACT"
    [[ -d "$BACKUP_EXTRACT/Kinetics.app" ]] || die "backup extraction missing app"
    codesign --verify --deep --strict --verbose=2 "$BACKUP_EXTRACT/Kinetics.app" >/dev/null
    rm -rf "$BACKUP_EXTRACT"
    BACKUP_EXTRACT=""
    echo "Backup retained: $BACKUP_ARCHIVE"
}

terminate_running_processes() {
    pkill -x Kinetics 2>/dev/null || true
    pkill -x "Kinetics Login Launcher" 2>/dev/null || true
    local attempt
    for attempt in {1..50}; do
        if ! pgrep -x Kinetics >/dev/null 2>&1 && \
           ! pgrep -x "Kinetics Login Launcher" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    die "Kinetics processes did not terminate cleanly"
}

atomic_rename() {
    python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

libc = ctypes.CDLL(None, use_errno=True)
libc.rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
libc.rename.restype = ctypes.c_int
result = libc.rename(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]))
if result != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), sys.argv[2])
PY
}

atomic_swap() {
    python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

libc = ctypes.CDLL(None, use_errno=True)
libc.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
libc.renameatx_np.restype = ctypes.c_int
AT_FDCWD = -2
RENAME_SWAP = 0x00000002
result = libc.renameatx_np(AT_FDCWD, os.fsencode(sys.argv[1]), AT_FDCWD, os.fsencode(sys.argv[2]), RENAME_SWAP)
if result != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), sys.argv[1], sys.argv[2])
PY
}

install_staged_app() {
    local temp_dir temp_app old_exists=0
    [[ -e "$INSTALL_APP" ]] && old_exists=1
    temp_dir="$(mktemp -d /Applications/.Kinetics-release-XXXXXX)"
    temp_app="$temp_dir/Kinetics.new.app"
    ditto "$STAGED_APP" "$temp_app"

    local staged_main_hash staged_helper_hash
    staged_main_hash="$(sha256_file "$MAIN_EXECUTABLE")"
    staged_helper_hash="$(sha256_file "$HELPER_EXECUTABLE")"
    echo "Staged main executable SHA-256: $staged_main_hash"
    echo "Staged helper executable SHA-256: $staged_helper_hash"
    verify_signed_bundle "$temp_app" "$MAIN_BUNDLE_ID" "$MAIN_REQUIREMENT" \
        "$temp_app/Contents/MacOS/Kinetics" "main-cert"
    verify_signed_bundle "$temp_app/Contents/Library/LoginItems/Kinetics Login Launcher.app" \
        "$HELPER_BUNDLE_ID" "$HELPER_REQUIREMENT" \
        "$temp_app/Contents/Library/LoginItems/Kinetics Login Launcher.app/Contents/MacOS/Kinetics Login Launcher" "helper-cert"
    verify_no_unexpected_executables "$temp_app" \
        "$temp_app/Contents/MacOS/Kinetics" \
        "$temp_app/Contents/Library/LoginItems/Kinetics Login Launcher.app/Contents/MacOS/Kinetics Login Launcher"

    if [[ "$old_exists" == "1" ]]; then
        atomic_swap "$INSTALL_APP" "$temp_app"
    else
        atomic_rename "$temp_app" "$INSTALL_APP"
    fi

    local swapped=1
    rollback_install() {
        if [[ "$swapped" == "1" ]]; then
            if [[ "$old_exists" == "1" ]]; then
                atomic_swap "$INSTALL_APP" "$temp_app" || true
            else
                atomic_rename "$INSTALL_APP" "$temp_app" || true
            fi
            swapped=0
        fi
    }
    if ! verify_signed_bundle "$INSTALL_APP" "$MAIN_BUNDLE_ID" "$MAIN_REQUIREMENT" \
        "$INSTALL_APP/Contents/MacOS/Kinetics" "installed-main-cert"; then
        rollback_install
        die "installed bundle verification failed; rollback completed"
    fi
    if ! verify_signed_bundle "$INSTALL_APP/Contents/Library/LoginItems/Kinetics Login Launcher.app" \
        "$HELPER_BUNDLE_ID" "$HELPER_REQUIREMENT" \
        "$INSTALL_APP/Contents/Library/LoginItems/Kinetics Login Launcher.app/Contents/MacOS/Kinetics Login Launcher" "installed-helper-cert"; then
        rollback_install
        die "installed bundle verification failed; rollback completed"
    fi
    if ! verify_no_unexpected_executables "$INSTALL_APP" \
        "$INSTALL_APP/Contents/MacOS/Kinetics" \
        "$INSTALL_APP/Contents/Library/LoginItems/Kinetics Login Launcher.app/Contents/MacOS/Kinetics Login Launcher"; then
        rollback_install
        die "installed bundle verification failed; rollback completed"
    fi
    if [[ "$(sha256_file "$INSTALL_APP/Contents/MacOS/Kinetics")" != "$staged_main_hash" || \
          "$(sha256_file "$INSTALL_APP/Contents/Library/LoginItems/Kinetics Login Launcher.app/Contents/MacOS/Kinetics Login Launcher")" != "$staged_helper_hash" ]]; then
        rollback_install
        die "installed bundle verification failed; rollback completed"
    fi

    if [[ "$old_exists" == "1" ]]; then
        rm -rf "$temp_app"
    fi
    rmdir "$temp_dir" 2>/dev/null || true
    swapped=0
    echo "Installed: $INSTALL_APP"
}

main() {
    local mode="compile"
    case "${1:-}" in
        "") ;;
        --install) mode="install" ;;
        *) usage; exit 2 ;;
    esac

    cd "$ROOT"
    if [[ "$mode" == "compile" ]]; then
        echo "Building Kinetics $VERSION (release compile only)..."
        swift build -c release
        BIN_DIR="$(swift build -c release --show-bin-path)"
        resolve_binaries "$BIN_DIR"
        print_binary_paths
        return 0
    fi

    preflight_install
    echo "Building Kinetics $VERSION (release install)..."
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
    resolve_binaries "$BIN_DIR"
    print_binary_paths
    assemble_staged_app

    # Sign the nested helper first so the enclosing app signature covers the
    # final helper bytes. No ad-hoc or alternate identity fallback is allowed.
    codesign --force --sign "$SIGNING_IDENTITY" --requirements "$HELPER_REQUIREMENT" "$STAGED_HELPER_APP" >/dev/null
    codesign --force --sign "$SIGNING_IDENTITY" --requirements "$MAIN_REQUIREMENT" "$STAGED_APP" >/dev/null
    verify_signed_bundle "$STAGED_APP" "$MAIN_BUNDLE_ID" "$MAIN_REQUIREMENT" "$MAIN_EXECUTABLE" "staged-main-cert"
    verify_signed_bundle "$STAGED_HELPER_APP" "$HELPER_BUNDLE_ID" "$HELPER_REQUIREMENT" "$HELPER_EXECUTABLE" "staged-helper-cert"
    verify_no_unexpected_executables "$STAGED_APP" "$MAIN_EXECUTABLE" "$HELPER_EXECUTABLE"
    backup_existing_app
    terminate_running_processes
    install_staged_app
}

main "$@"
