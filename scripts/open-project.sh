#!/bin/bash
# Open a project in Zed + Ghostty, tiled side by side.
# Called from macOS Shortcuts or directly from terminal.
export PATH="/opt/homebrew/bin:$PATH"

# Pick a folder
dir=$(/usr/bin/osascript <<'AS'
set b to POSIX file "/Users/klundstedt/github"
set c to choose folder with prompt "Select a project:" default location b
return POSIX path of c
AS
)
[ -z "$dir" ] && exit 0

# Get screen dimensions
screen=$(/usr/bin/osascript <<'AS'
tell app "Finder" to set _b to bounds of window of desktop
set _w to item 3 of _b
set _h to item 4 of _b
return ((_w div 2) as string) & " " & (_h as string)
AS
)
half=$(echo "$screen" | cut -d' ' -f1)
height=$(echo "$screen" | cut -d' ' -f2)
htrim=$((height - 25))

# Open Zed and position left
zed "$dir"
sleep 1
/usr/bin/osascript <<TILE1
tell app "System Events" to tell process "Zed"
  set position of window 1 to {0, 25}
  set size of window 1 to {$half, $htrim}
end tell
TILE1

# Open new Ghostty window in current space and position right
open -n -a Ghostty
sleep 2
/usr/bin/osascript <<TILE2
tell app "System Events" to tell (first process whose frontmost is true)
  keystroke "cd ${dir%/}" & return
  delay 0.3
  set position of window 1 to {$half, 25}
  set size of window 1 to {$half, $htrim}
end tell
TILE2
