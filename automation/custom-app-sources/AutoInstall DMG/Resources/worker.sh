#!/bin/bash
# AutoInstall DMG — serialized background installer.
#
# The droplet's `on open` handler only ENQUEUES dropped .dmg paths (one file per
# job in the spool dir) and then launches this worker detached. All the slow and
# interactive work — hdiutil mount, the "already exists" dialog, the admin
# prompt, ditto, detach, trash — happens HERE, outside the Apple Event handler.
# A single worker drains the queue one DMG at a time (guarded by an atomic lock),
# so opening any number of DMGs at once can never stall or drop an install.
#
# Test hooks (env): AIDMG_SUPPORT_DIR, AIDMG_DEST_DIR (default /Applications),
#   AIDMG_NO_ADMIN=1, AIDMG_NO_TRASH=1, AIDMG_AUTO=Abort|Replace|KeepBoth, AIDMG_LOG.

set -u

SUPPORT_DIR="${AIDMG_SUPPORT_DIR:-$HOME/Library/Application Support/AutoInstall DMG}"
DEST_DIR="${AIDMG_DEST_DIR:-/Applications}"
SPOOL="$SUPPORT_DIR/queue"
LOCK="$SUPPORT_DIR/worker.lock"

mkdir -p "$SPOOL"

log() { [ -n "${AIDMG_LOG:-}" ] && printf '%s  %s\n' "$(/bin/date +%s.%N)" "$*" >> "$AIDMG_LOG"; return 0; }
q()   { printf '%q' "$1"; }

# --- single-worker lock (mkdir is atomic) -----------------------------------
if ! mkdir "$LOCK" 2>/dev/null; then
	log "another worker holds the lock; exiting"
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# --- GUI helpers (run in the user session; no TCC/Automation needed) ---------
ask_conflict() { # $1 = appName, $2 = destDir  -> prints Abort|Replace|Keep Both
	if [ -n "${AIDMG_AUTO:-}" ]; then
		case "$AIDMG_AUTO" in KeepBoth) echo "Keep Both";; *) echo "$AIDMG_AUTO";; esac
		return 0
	fi
	osascript - "$1" "$2" <<'OSA' 2>/dev/null
on run argv
	set appName to item 1 of argv
	set destDir to item 2 of argv
	tell me to activate
	try
		return button returned of (display dialog "An application named \"" & appName & "\" already exists in " & destDir & ". What would you like to do?" buttons {"Abort", "Replace", "Keep Both"} default button "Abort" with title "App Already Exists")
	on error
		return "Abort"
	end try
end run
OSA
}

run_admin() { # $1 = shell command string, run as root via the standard auth prompt
	osascript - "$1" <<'OSA'
on run argv
	do shell script (item 1 of argv) with administrator privileges
end run
OSA
}

trash_dmg() { # $1 = posix path; native NSFileManager trash (own file op, no Finder)
	[ "${AIDMG_NO_TRASH:-}" = "1" ] && return 0
	osascript - "$1" <<'OSA'
use framework "Foundation"
use scripting additions
on run argv
	set p to item 1 of argv
	set theURL to (current application's |NSURL|'s fileURLWithPath:p)
	set fm to current application's NSFileManager's defaultManager()
	(fm's trashItemAtURL:theURL resultingItemURL:(missing value) |error|:(missing value))
end run
OSA
}

show_error() { # $1 = message
	osascript - "$1" <<'OSA' 2>/dev/null
on run argv
	tell me to activate
	display dialog "AutoInstall DMG failed: " & (item 1 of argv) buttons {"OK"} default button "OK" with icon stop with title "Install Failed"
end run
OSA
}

# --- quit a running copy of the app we are about to replace ------------------
# Replacing a running app's bundle fails silently (rm/ditto race with the live
# process), so quit it first: graceful AppleScript quit by bundle id, then
# SIGTERM, then SIGKILL. Skippable in tests via AIDMG_NO_QUIT=1.
quit_running_app() { # $1 = app bundle path in DEST_DIR
	[ "${AIDMG_NO_QUIT:-}" = "1" ] && return 0
	local app="$1" bid="" i
	pids() { /usr/bin/pgrep -f "$app/Contents/MacOS/" 2>/dev/null; }
	[ -n "$(pids)" ] || return 0
	bid=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
	log "quitting running app '$app' (bid=${bid:-?})"
	if [ -n "$bid" ]; then
		osascript - "$bid" <<'OSA' >/dev/null 2>&1
on run argv
	try
		tell application id (item 1 of argv) to quit
	end try
end run
OSA
	fi
	for i in $(seq 1 20); do [ -n "$(pids)" ] || return 0; /bin/sleep 0.5; done
	pids | /usr/bin/xargs /bin/kill -TERM 2>/dev/null
	for i in $(seq 1 10); do [ -n "$(pids)" ] || return 0; /bin/sleep 0.5; done
	pids | /usr/bin/xargs /bin/kill -KILL 2>/dev/null
	/bin/sleep 1
	return 0
}

# --- install one app bundle into DEST_DIR (with admin escalation) ------------
install_app() { # $1 = appPath, $2 = destPath, $3 = replace(1/0) -> 0 ok, 1 fail
	local app="$1" dest="$2" replace="$3" cmd err
	cmd="/usr/bin/ditto $(q "$app") $(q "$dest") && { /usr/bin/xattr -dr com.apple.quarantine $(q "$dest") 2>/dev/null || true; }"
	[ "$replace" = "1" ] && cmd="/bin/rm -rf $(q "$dest") && $cmd"

	if [ "$replace" = "1" ]; then
		if [ "${AIDMG_NO_ADMIN:-}" = "1" ]; then eval "$cmd"; else run_admin "$cmd"; fi
		return
	fi
	# non-replace: try without admin, escalate only on a permission error
	if err=$(eval "$cmd" 2>&1); then return 0; fi
	case "$err" in
		*"Permission denied"*|*"Operation not permitted"*|*"not permitted"*)
			[ "${AIDMG_NO_ADMIN:-}" = "1" ] && { echo "$err" >&2; return 1; }
			run_admin "$cmd" ;;
		*) echo "$err" >&2; return 1 ;;
	esac
}

# --- process a single DMG ----------------------------------------------------
process_dmg() {
	local dmg="$1" mountPoint="" appPath appName destPath doCopy=0 replace=0 choice base counter testPath

	[ -f "$dmg" ] || { log "skip missing $dmg"; return 0; }
	case "$dmg" in *.dmg) ;; *) log "skip non-dmg $dmg"; return 0;; esac
	log "process $dmg"

	{
		mountPoint=$(/usr/bin/hdiutil attach "$dmg" -nobrowse 2>/dev/null | /usr/bin/awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/")); exit}')
		if [ -n "$mountPoint" ]; then
			log "mounted at $mountPoint"
			appPath=$(/usr/bin/find "$mountPoint" -maxdepth 1 -name '*.app' | /usr/bin/head -n 1)
			if [ -n "$appPath" ]; then
				appName=$(/usr/bin/basename "$appPath")
				destPath="$DEST_DIR/$appName"
				doCopy=1
				if [ -e "$destPath" ]; then
					choice=$(ask_conflict "$appName" "$DEST_DIR")
					case "$choice" in
						Replace)
							replace=1
							quit_running_app "$destPath" ;;
						"Keep Both")
							base="${appName%.app}"; counter=2
							while :; do
								testPath="$DEST_DIR/$base $counter.app"
								[ -e "$testPath" ] || { destPath="$testPath"; break; }
								counter=$((counter+1))
							done ;;
						*) doCopy=0 ;;  # Abort / dialog error
					esac
				fi
				if [ "$doCopy" = "1" ]; then
					log "install '$appName' -> '$destPath' (replace=$replace)"
					install_app "$appPath" "$destPath" "$replace" || { show_error "could not install $appName"; doCopy=0; }
				fi
			else
				log "no .app found in $mountPoint"
			fi
		else
			log "no mount point (already mounted or needs EULA): $dmg"
		fi
	} || show_error "$?"

	# always try to unmount what we mounted
	[ -n "$mountPoint" ] && /usr/bin/hdiutil detach "$mountPoint" -force >/dev/null 2>&1

	# trash the DMG only if we actually installed
	[ "$doCopy" = "1" ] && trash_dmg "$dmg"
	return 0
}

# --- drain loop: keep going until the spool is empty -------------------------
while :; do
	shopt -s nullglob
	jobs=("$SPOOL"/*.job)
	shopt -u nullglob
	[ ${#jobs[@]} -eq 0 ] && break
	# FIFO-ish: sort by filename (timestamp-prefixed)
	IFS=$'\n' jobs=($(printf '%s\n' "${jobs[@]}" | sort)); unset IFS
	for jobf in "${jobs[@]}"; do
		dmg=$(/bin/cat "$jobf" 2>/dev/null)
		/bin/rm -f "$jobf"
		[ -n "$dmg" ] && process_dmg "$dmg"
	done
done

log "drain complete; releasing lock"
exit 0
