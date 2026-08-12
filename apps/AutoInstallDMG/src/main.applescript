-- AutoInstall DMG (droplet)
--
-- IMPORTANT: this handler must return FAST. AppleScript applets are single
-- threaded and non-reentrant: if this handler blocks (mounting, a dialog, the
-- admin prompt, a big copy) while a SECOND .dmg is opened, that second Apple
-- Event is queued behind us or dropped by Launch Services — the old "opening two
-- DMGs at once" failure. So we only enqueue the dropped paths and kick a single
-- detached worker (Contents/Resources/worker.sh), which does all the real work
-- serially, out of band. Return immediately.

on open droppedItems
	set libDir to POSIX path of (path to library folder from user domain)
	set spoolDir to libDir & "Application Support/AutoInstall DMG/queue"
	do shell script "/bin/mkdir -p " & quoted form of spoolDir
	
	repeat with theItem in droppedItems
		set filePath to POSIX path of theItem
		if filePath ends with ".dmg" then
			-- atomically drop one job file per DMG into the spool
			do shell script "d=" & quoted form of spoolDir & "; p=" & quoted form of filePath & "; u=$(/bin/date +%s)-$$-$RANDOM; /usr/bin/printf '%s' \"$p\" > \"$d/.tmp-$u\" && /bin/mv -f \"$d/.tmp-$u\" \"$d/$u.job\""
		end if
	end repeat
	
	-- launch the worker detached; the lock inside it dedupes concurrent workers
	set workerPath to (POSIX path of (path to me)) & "Contents/Resources/worker.sh"
	do shell script "/usr/bin/nohup /bin/bash " & quoted form of workerPath & " >/dev/null 2>&1 &"
end open

on run
	-- launched with no documents; nothing to do
end run

