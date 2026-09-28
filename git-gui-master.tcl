#!/bin/sh
# Tcl ignores the next line -*- tcl -*- \
exec wish "$0" -- "$@"

# git-gui-master --------------------------------------------------------------
#
# A hub window for working with several repositories at once. The Home tab
# launches recent or browsed repositories; each open repository gets its own
# tab that tracks the running git-gui and can close it.
#
# By default each repository runs in its own git-gui window (reliable on
# Windows). "View -> Embed repositories in tabs" enables experimental in-tab
# embedding via Tk's -use/-container reparenting; this only renders correctly
# on X11, so it is off by default on Windows.
# -----------------------------------------------------------------------------

package require Tk

set SELF   [file normalize [info script]]
set HERE   [file dirname $SELF]
set GITGUI [file join $HERE git-gui.sh]
set WISH   [info nameofexecutable]

# tab-frame path -> dict{pid path name mode opened}
array set TAB {}
set TAB_SEQ 0

# path -> {branch upstatus}; lazily computed, cleared when a repo's tab closes.
array set BRANCH_CACHE {}

# Live remote-check queue state (opt-in; hits the network).
set LIVE_QUEUE {}
set LIVE_TOTAL 0
set LIVE_DONE 0

# Pull-behind queue state, and the branches that "pull behind" is willing to
# fast-forward automatically.
set PULL_QUEUE {}
set PULL_TOTAL 0
set PULL_DONE 0
set PULLABLE {trunk master main production}

# One persistent overlay daemon manages all docked windows via this command file.
set OVERLAY_CMD {}
set OVERLAY_DAEMON 0

# Never block a background fetch on an interactive credential prompt.
set ::env(GIT_TERMINAL_PROMPT) 0

# How each repository is presented:
#   separate = its own git-gui window (reliable everywhere; keeps its menu bar)
#   dock     = git-gui window reparented into the tab via Win32 SetParent
#   embed    = Tk -use/-container embedding (X11 only; blank on Windows)
set MODE dock

# Experimental: pull git-gui's tool windows (blame/browser/console) into tabs.
set TAB_TOOLS 1

set IS_WINDOWS [expr {$::tcl_platform(platform) eq {windows}}]

# -- git / repository helpers -------------------------------------------------

proc is_git_repo {path} {
	# Worktree (.git dir or file) or a bare/plain git dir.
	if {[file exists [file join $path .git]]} { return 1 }
	if {[file isdirectory [file join $path objects]] \
		&& [file exists [file join $path HEAD]]} { return 1 }
	return 0
}

proc recent_repos {} {
	if {[catch {exec git config --global --get-all gui.recentrepo} out]} {
		return {}
	}
	set seen [dict create]
	set res {}
	# git stores oldest first; show most-recent first without duplicates.
	foreach line [lreverse [split $out \n]] {
		set p [string trim $line]
		if {$p eq {}} { continue }
		set n [file normalize $p]
		if {[dict exists $seen $n]} { continue }
		dict set seen $n 1
		if {[is_git_repo $n]} { lappend res $n }
	}
	return $res
}

proc remember_recent {path} {
	set path [file normalize $path]
	catch {exec git config --global --add gui.recentrepo $path}
	refresh_recent
}

proc pinned_repos {} {
	if {[catch {exec git config --global --get-all guimaster.pinned} out]} {
		return {}
	}
	set seen [dict create]
	set res {}
	foreach line [split $out \n] {
		set p [string trim $line]
		if {$p eq {}} { continue }
		set n [file normalize $p]
		if {[dict exists $seen $n]} { continue }
		dict set seen $n 1
		if {[is_git_repo $n]} { lappend res $n }
	}
	return $res
}

proc is_pinned {path} {
	set n [file normalize $path]
	expr {[lsearch -exact [pinned_repos] $n] >= 0}
}

proc pin_repo {path} {
	set n [file normalize $path]
	if {![is_pinned $n]} { catch {exec git config --global --add guimaster.pinned $n} }
	refresh_recent
}

proc unpin_repo {path} {
	set n [file normalize $path]
	regsub -all -- {([()\[\]{}.^$+*?\\])} $n {\\\1} pat
	catch {exec git config --global --unset-all guimaster.pinned "^$pat\$"}
	refresh_recent
}

# Returns the tab frame for an open repo, or {} if not open.
proc repo_open_tab {path} {
	global TAB
	set n [file normalize $path]
	foreach f [array names TAB] {
		if {[dict get $TAB($f) path] eq $n} { return $f }
	}
	return {}
}

# -- child process lifecycle --------------------------------------------------

proc pid_alive {pid} {
	global IS_WINDOWS
	if {$pid eq {}} { return 0 }
	if {$IS_WINDOWS} {
		if {[catch {exec tasklist /FI "PID eq $pid" /NH /FO CSV} out]} {
			return 1 ;# unable to tell, assume alive
		}
		return [expr {[string first "\"$pid\"" $out] >= 0}]
	}
	return [expr {![catch {exec kill -0 $pid}]}]
}

proc kill_pid {pid} {
	global IS_WINDOWS
	if {$pid eq {}} { return }
	if {$IS_WINDOWS} {
		catch {exec taskkill /PID $pid /T /F}
	} else {
		catch {exec kill $pid}
	}
}

proc launch_embedded {winid path} {
	global WISH GITGUI
	set save [pwd]
	cd $path
	set ::env(GIT_GUI_EMBEDDED) 1
	set rc [catch {exec $WISH -use $winid $GITGUI -- &} result]
	unset -nocomplain ::env(GIT_GUI_EMBEDDED)
	cd $save
	if {$rc} { error $result }
	return $result
}

proc launch_separate {path {embedflag 0}} {
	global WISH GITGUI
	set save [pwd]
	cd $path
	if {$embedflag} { set ::env(GIT_GUI_EMBEDDED) 1 }
	set rc [catch {exec $WISH $GITGUI -- &} result]
	unset -nocomplain ::env(GIT_GUI_EMBEDDED)
	cd $save
	if {$rc} { error $result }
	return $result
}

# Start the single overlay daemon (compiles Win32 interop once) if needed.
proc ensure_overlay_daemon {} {
	global OVERLAY_CMD OVERLAY_DAEMON HERE
	if {$OVERLAY_DAEMON} { return }
	set OVERLAY_CMD [file join [_temp_dir] overlaycmd-[pid].txt]
	catch {close [open $OVERLAY_CMD w]}
	set script [file nativename [file join $HERE overlay-daemon.ps1]]
	set vbs [file nativename [file join $HERE hidden-run.vbs]]
	exec [auto_execok wscript.exe] $vbs \
		powershell.exe -NoProfile -ExecutionPolicy Bypass \
		-File $script -CommandFile [file nativename $OVERLAY_CMD] \
		-OwnerHwnd [expr {[winfo id .]}] &
	set OVERLAY_DAEMON 1
}

proc attach_overlay {line} {
	global OVERLAY_CMD
	catch {set fh [open $OVERLAY_CMD a]; puts $fh $line; close $fh}
}

# Overlay a repo's main window (owned by its process's main window handle).
proc launch_overlay_helper {pid ownerhwnd hosthwnd statusfile} {
	ensure_overlay_daemon
	attach_overlay "pid $pid $hosthwnd 0 $statusfile"
}

# Overlay a specific tool window handle; close it when its host tab is gone.
proc launch_overlay_helper_hwnd {hwnd ownerhwnd hosthwnd statusfile} {
	ensure_overlay_daemon
	attach_overlay "hwnd $hwnd $hosthwnd 1 $statusfile"
}

# Poll a docked git-gui's request file; pull each newly reported tool window
# (blame/browser/console) into its own tab. Stops when the repo's tab closes.
proc watch_requests {mainf reqfile processed} {
	if {![info exists ::TAB($mainf)]} { return }
	set lines {}
	if {![catch {set fh [open $reqfile r]}]} {
		set data [read $fh]
		close $fh
		set lines [split [string trimright $data \n] \n]
	}
	set n [llength $lines]
	for {set i $processed} {$i < $n} {incr i} {
		set line [lindex $lines $i]
		if {$line eq {}} { continue }
		lassign [split $line \t] hwnd label
		if {$hwnd ne {}} { open_tool_tab $hwnd $label [dict get $::TAB($mainf) pid] }
	}
	after 200 [list watch_requests $mainf $reqfile $n]
}

proc short_tool_label {title} {
	set s $title
	regsub {^Git Gui \([^)]*\):\s*} $s {} s
	regsub {^Tool:\s*\S+\s*-\s*} $s {} s
	set s [string trim [lindex [split $s /] end]]
	if {[string length $s] > 22} { set s "[string range $s 0 20]\u2026" }
	if {$s eq {}} { set s "tool" }
	return $s
}

proc open_tool_tab {hwnd label pid} {
	global TAB TAB_SEQ
	foreach f [array names TAB] {
		if {[dict exists $TAB($f) hwnd] && [dict get $TAB($f) hwnd] eq $hwnd} { return }
	}
	incr TAB_SEQ
	set label [short_tool_label $label]
	set f .nb.tool$TAB_SEQ
	frame $f -width 1000 -height 640
	.nb add $f -text " $label "
	set host [frame $f.host -background gray85]
	pack $host -expand 1 -fill both
	# Do NOT select the new tab - keep focus on whatever the user was viewing;
	# the daemon keeps the tool hidden until its tab is chosen.
	update idletasks
	set status [file join [_temp_dir] dock-$TAB_SEQ.txt]
	catch {file delete $status}
	catch {launch_overlay_helper_hwnd $hwnd \
		[expr {[winfo id .]}] [expr {[winfo id $host]}] $status}
	set TAB($f) [dict create pid $pid path {} name $label \
		mode tool hwnd $hwnd status $status opened [clock milliseconds]]
}

# -- tabs ---------------------------------------------------------------------

proc open_repo {path {name {}} {select 1}} {
	global TAB TAB_SEQ MODE

	set path [file normalize $path]
	if {![is_git_repo $path]} {
		tk_messageBox -icon error -title "git-gui master" \
			-message "Not a Git repository:\n\n$path"
		return
	}

	# Already open? Just raise its tab.
	foreach f [array names TAB] {
		if {[dict get $TAB($f) path] eq $path} {
			.nb select $f
			return
		}
	}

	incr TAB_SEQ
	if {$name eq {}} { set name [file tail $path] }
	set f .nb.repo$TAB_SEQ
	set mode $MODE

	if {$mode eq {embed}} {
		frame $f -container 1 -width 1000 -height 640 -takefocus 0
	} else {
		frame $f -width 1000 -height 640
	}
	.nb add $f -text " $name "

	# Defer the actual git-gui launch until the tab is first viewed, so opening
	# several repos at once does not spawn every git-gui process up front.
	set TAB($f) [dict create pid 0 path $path name $name mode $mode \
		seq $TAB_SEQ opened [clock milliseconds] pending 1]
	remember_recent $path
	if {$mode ne {embed}} { build_pending_placeholder $f $path }

	if {$select} { .nb select $f ; after idle [list ensure_launched $f] }
}

# Perform the deferred git-gui launch for a pending tab the first time it is
# viewed. Idempotent: a no-op once the tab has been launched.
proc ensure_launched {f} {
	global TAB TAB_TOOLS
	if {![info exists TAB($f)]} { return }
	if {![dict get $TAB($f) pending]} { return }
	set d $TAB($f)
	dict set d pending 0
	set TAB($f) $d
	set path [dict get $d path]
	set mode [dict get $d mode]
	set seq  [dict get $d seq]
	catch {destroy $f.pending}
	update idletasks

	switch -- $mode {
	embed {
		if {[catch {launch_embedded [winfo id $f] $path} pid]} {
			unset -nocomplain TAB($f) ; _open_failed $f $pid ; return
		}
	}
	dock {
		set host [build_dock_frame $f $path]
		update idletasks
		set reqfile {}
		if {$TAB_TOOLS} {
			set reqfile [file join [_temp_dir] dockreq-$seq.txt]
			catch {file delete $reqfile}
			set ::env(GIT_GUI_DOCK_REQUESTS) $reqfile
		}
		if {[catch {launch_separate $path 1} pid]} {
			unset -nocomplain ::env(GIT_GUI_DOCK_REQUESTS)
			unset -nocomplain TAB($f) ; _open_failed $f $pid ; return
		}
		unset -nocomplain ::env(GIT_GUI_DOCK_REQUESTS)
		set status [file join [_temp_dir] dock-$seq.txt]
		catch {file delete $status}
		catch {launch_overlay_helper $pid \
			[expr {[winfo id .]}] [expr {[winfo id $host]}] $status}
		if {$TAB_TOOLS && $reqfile ne {}} {
			after 300 [list watch_requests $f $reqfile 0]
		}
	}
	default {
		set mode separate
		if {[catch {launch_separate $path} pid]} {
			unset -nocomplain TAB($f) ; _open_failed $f $pid ; return
		}
		build_separate_placeholder $f $path
	}
	}

	set d $TAB($f)
	dict set d pid $pid
	dict set d mode $mode
	dict set d opened [clock milliseconds]
	# Docked tabs are watched by the overlay daemon via this status file, so
	# poll_children can check it instead of spawning tasklist every cycle.
	if {[info exists status]} { dict set d status $status }
	set TAB($f) $d

	# Windows Tk does not send the freshly embedded child a size event on
	# attach, so it never paints. Nudge the toplevel geometry a few times to
	# force WM_SIZE down to the embedded git-gui and make it fill the tab.
	if {$mode eq {embed}} {
		foreach ms {600 1400 2600} { after $ms nudge_repaint }
	}
}

proc on_tab_changed {} {
	set cur [.nb select]
	if {$cur ne {} && [info exists ::TAB($cur)]} { ensure_launched $cur }
}

proc _open_failed {f msg} {
	catch {.nb forget $f}
	catch {destroy $f}
	tk_messageBox -icon error -title "git-gui master" \
		-message "Failed to launch git-gui:\n\n$msg"
}

proc _temp_dir {} {
	if {[info exists ::env(TEMP)]} { return $::env(TEMP) }
	if {[info exists ::env(TMP)]}  { return $::env(TMP) }
	return [pwd]
}

# Docked tab layout: a thin toolbar on top and a host frame below that the
# git-gui window is reparented into (via Win32 SetParent).
proc build_dock_frame {f path} {
	set tb [frame $f.tb]
	pack $tb -side top -fill x
	label  $tb.p -text $path -anchor w -fg gray40
	button $tb.x -text "Close" -command [list close_tab $f]
	pack $tb.x -side right -padx 4 -pady 2
	tooltip $tb.x "Close this repository tab and its git-gui window"
	pack $tb.p -side left -padx 6
	set host [frame $f.host -background gray85]
	pack $host -side top -expand 1 -fill both
	return $host
}

proc nudge_repaint {} {
	if {![regexp {^(\d+)x(\d+)} [wm geometry .] -> w h]} { return }
	wm geometry . "[expr {$w + 1}]x[expr {$h + 1}]"
	update idletasks
	wm geometry . "${w}x${h}"
}

# Lightweight placeholder shown in a tab until its git-gui is launched on first
# view. Not used for embed tabs (a -container frame cannot hold widgets).
proc build_pending_placeholder {f path} {
	set p [frame $f.pending]
	pack $p -expand 1 -fill both
	set c [frame $p.c]
	place $c -relx 0.5 -rely 0.45 -anchor center
	label $c.t -text [file tail $path] \
		-font [list [font actual TkDefaultFont -family] 13 bold]
	label $c.s -text "Loading\u2026" -fg gray40
	pack $c.t -pady {0 4}
	pack $c.s
	return $p
}

proc build_separate_placeholder {f path} {
	set box [frame $f.box]
	pack $box -expand 1 -fill both
	set c [frame $box.c]
	place $c -relx 0.5 -rely 0.45 -anchor center

	label $c.t -text [file tail $path] \
		-font [list [font actual TkDefaultFont -family] 14 bold]
	label $c.p -text $path -fg gray40
	label $c.s -text "" -fg gray30
	set note [frame $c.note]
	label $note.n -text "git-gui is running in its own window." -fg gray40

	set btns [frame $c.btns]
	button $btns.r -text "Refresh status" -command [list refresh_status $f]
	button $btns.e -text "Open in Explorer" -command [list open_explorer $path]
	button $btns.x -text "Close repository" -command [list close_tab $f]
	pack $btns.r $btns.e $btns.x -side left -padx 4
	tooltip $btns.r "Re-read this repo's branch and working-tree status"
	tooltip $btns.e "Open this repository folder in the file manager"
	tooltip $btns.x "Close this repository tab and its git-gui window"

	pack $c.t -pady {0 4}
	pack $c.p -pady {0 2}
	pack $c.s -pady {0 10}
	pack $note.n
	pack $note -pady {0 14}
	pack $btns

	refresh_status $f
}

proc git_status_line {path} {
	set save [pwd]
	if {[catch {cd $path}]} { return "" }
	set branch "?"
	catch {set branch [string trim [exec git rev-parse --abbrev-ref HEAD]]}
	set dirty 0
	if {![catch {exec git status --porcelain} out]} {
		foreach l [split $out \n] { if {[string trim $l] ne {}} { incr dirty } }
	}
	cd $save
	if {$dirty == 0} {
		return "On $branch \u2014 clean"
	}
	return "On $branch \u2014 $dirty change[expr {$dirty == 1 ? {} : {s}}]"
}

proc refresh_status {f} {
	global TAB
	if {![info exists TAB($f)] || ![winfo exists $f.box.c.s]} { return }
	$f.box.c.s configure -text [git_status_line [dict get $TAB($f) path]]
}

proc open_explorer {path} {
	global IS_WINDOWS
	if {$IS_WINDOWS} {
		catch {exec {*}[auto_execok start] "" [file nativename $path] &}
	} else {
		catch {exec xdg-open $path &}
	}
}

proc close_tab {f} {
	global TAB BRANCH_CACHE
	if {![info exists TAB($f)]} { return }
	if {[dict exists $TAB($f) pending] && [dict get $TAB($f) pending]} {
		catch {.nb forget $f}
		catch {destroy $f}
		unset TAB($f)
		catch {refresh_recent}
		return
	}
	if {[dict get $TAB($f) mode] eq {tool}} {
		# The overlay helper closes the tool window when its host is destroyed.
		catch {.nb forget $f}
		catch {destroy $f}
		unset TAB($f)
		return
	}
	catch {unset BRANCH_CACHE([dict get $TAB($f) path])}
	kill_pid [dict get $TAB($f) pid]
	catch {.nb forget $f}
	catch {destroy $f}
	unset TAB($f)
	catch {refresh_recent}
}

proc close_current_tab {} {
	set cur [.nb select]
	if {$cur ne {} && [info exists ::TAB($cur)]} {
		close_tab $cur
	}
}

# Poll child processes; drop tabs whose git-gui has exited.
proc poll_children {} {
	global TAB
	foreach f [array names TAB] {
		# Not yet launched (deferred until first viewed) — nothing to poll.
		if {[dict exists $TAB($f) pending] && [dict get $TAB($f) pending]} {
			continue
		}
		# Docked repo tabs and tool tabs are managed by the overlay daemon, which
		# writes "closed" to their status file when the window is gone (on normal
		# exit or early crash). Reading that file avoids a synchronous tasklist
		# spawn per tab every cycle.
		if {[dict exists $TAB($f) status]} {
			set closed 0
			if {![catch {set fh [open [dict get $TAB($f) status] r]}]} {
				set c [read $fh]
				close $fh
				if {[string match *closed* $c]} { set closed 1 }
			}
			if {$closed} {
				catch {.nb forget $f}
				catch {destroy $f}
				unset TAB($f)
				catch {refresh_recent}
			}
			continue
		}
		# Separate / embedded tabs have no daemon: fall back to a liveness check.
		set pid [dict get $TAB($f) pid]
		if {[pid_alive $pid]} { continue }
		set opened [dict get $TAB($f) opened]
		set mode   [dict get $TAB($f) mode]
		set quick  [expr {[clock milliseconds] - $opened < 4000}]
		catch {.nb forget $f}
		catch {destroy $f}
		unset TAB($f)
		catch {refresh_recent}
		if {$mode eq {embed} && $quick} {
			tk_messageBox -icon warning -title "git-gui master" \
				-message [join {
					"git-gui exited immediately, so embedding may not"
					"work here.\n\nTry turning off \"View -> Embed"
					"repositories in tabs\" and open the repository"
					"again to run it in a separate window."} " "]
		}
	}
	after 2000 poll_children
}

# -- tab close interactions ---------------------------------------------------

proc tab_under {x y} {
	if {[catch {.nb index @$x,$y} idx]} { return {} }
	return [lindex [.nb tabs] $idx]
}

proc on_tab_middle {x y} {
	set f [tab_under $x $y]
	if {$f ne {} && [info exists ::TAB($f)]} { close_tab $f }
}

proc on_tab_context {x y X Y} {
	set f [tab_under $x $y]
	if {$f eq {} || ![info exists ::TAB($f)]} { return }
	.tabmenu delete 0 end
	.tabmenu add command -label "Close [dict get $::TAB($f) name]" \
		-command [list close_tab $f]
	tk_popup .tabmenu $X $Y
}

# -- launcher (Home tab) ------------------------------------------------------

proc browse_open {} {
	set d [tk_chooseDirectory -title "Open Git repository" -mustexist 1]
	if {$d ne {}} { open_repo $d }
}

# Local (no-network) branch + ahead/behind vs the last-fetched upstream.
proc repo_branch_status {path} {
	set save [pwd]
	if {[catch {cd $path}]} { return [list ? {}] }
	set branch ?
	catch {set branch [string trim [exec git rev-parse --abbrev-ref HEAD]]}
	set status {}
	if {![catch {exec git rev-list --count --left-right {@{upstream}...HEAD}} lr]} {
		lassign [split [string trim $lr]] behind ahead
		if {$behind eq {}} { set behind 0 }
		if {$ahead eq {}} { set ahead 0 }
		if {$ahead == 0 && $behind == 0} {
			set status "\u2713 up to date"
		} elseif {$behind == 0} {
			set status "\u2191$ahead ahead"
		} elseif {$ahead == 0} {
			set status "\u2193$behind behind"
		} else {
			set status "\u2191$ahead \u2193$behind"
		}
	} else {
		set status ""
	}
	cd $save
	return [list $branch $status]
}

# --- on-demand live remote check (opt-in; hits the network) ------------------

proc _find_home_item {path} {
	set tv .nb.home.list.tv
	if {![winfo exists $tv]} { return {} }
	foreach it [$tv children {}] {
		if {[lindex [$tv item $it -values] 1] eq $path} { return $it }
	}
	return {}
}

proc _home_set_status {path text} {
	set tv .nb.home.list.tv
	set it [_find_home_item $path]
	if {$it eq {}} { return }
	set vals [$tv item $it -values]
	$tv item $it -values [list [lindex $vals 0] $path [lindex $vals 2] $text]
}

proc _home_apply_cached {path} {
	global BRANCH_CACHE
	set tv .nb.home.list.tv
	set it [_find_home_item $path]
	if {$it eq {} || ![info exists BRANCH_CACHE($path)]} { return }
	lassign $BRANCH_CACHE($path) br st
	set vals [$tv item $it -values]
	$tv item $it -values [list [lindex $vals 0] $path $br $st]
}

# Fetch in the background; run done_cmd (global scope) when the process exits.
proc async_fetch {path done_cmd} {
	set cmd [list git -C $path fetch --quiet]
	if {[catch {set chan [open "|$cmd" r]}]} {
		after 0 $done_cmd
		return
	}
	fconfigure $chan -blocking 0
	fileevent $chan readable [list _fetch_drain $chan $done_cmd]
}

proc _fetch_drain {chan done_cmd} {
	catch {read $chan}
	if {[eof $chan]} {
		catch {close $chan}
		uplevel #0 $done_cmd
	}
}

proc check_remote {path} {
	_home_set_status $path "checking\u2026"
	async_fetch $path [list _check_remote_done $path]
}

proc _check_remote_done {path} {
	global BRANCH_CACHE
	set BRANCH_CACHE($path) [repo_branch_status $path]
	_home_apply_cached $path
}

# Bounded-concurrency live refresh of every listed repo.
proc check_all_remotes {} {
	global LIVE_QUEUE LIVE_TOTAL LIVE_DONE
	set tv .nb.home.list.tv
	if {![winfo exists $tv]} { return }
	set LIVE_QUEUE {}
	foreach it [$tv children {}] {
		set p [lindex [$tv item $it -values] 1]
		if {$p ne {}} { lappend LIVE_QUEUE $p }
	}
	set LIVE_TOTAL [llength $LIVE_QUEUE]
	set LIVE_DONE 0
	if {$LIVE_TOTAL == 0} { return }
	_live_progress
	for {set i 0} {$i < 4} {incr i} { _live_pump }
}

proc _live_pump {} {
	global LIVE_QUEUE
	if {$LIVE_QUEUE eq {}} { return }
	set path [lindex $LIVE_QUEUE 0]
	set LIVE_QUEUE [lrange $LIVE_QUEUE 1 end]
	_home_set_status $path "checking\u2026"
	async_fetch $path [list _live_done $path]
}

proc _live_done {path} {
	global BRANCH_CACHE LIVE_DONE
	set BRANCH_CACHE($path) [repo_branch_status $path]
	_home_apply_cached $path
	incr LIVE_DONE
	_live_progress
	_live_pump
}

proc _live_progress {} {
	global LIVE_TOTAL LIVE_DONE
	set lbl .nb.home.head.prog
	if {![winfo exists $lbl]} { return }
	if {$LIVE_DONE >= $LIVE_TOTAL} {
		$lbl configure -text ""
	} else {
		$lbl configure -text "Checking remotes\u2026 $LIVE_DONE / $LIVE_TOTAL"
	}
}

# --- pull behind (fast-forward only) -----------------------------------------

proc cached_branch_status {path} {
	global BRANCH_CACHE
	if {![info exists BRANCH_CACHE($path)]} {
		set BRANCH_CACHE($path) [repo_branch_status $path]
	}
	return $BRANCH_CACHE($path)
}

# True when the repo is on a pull-eligible branch and is strictly behind
# (fast-forwardable), per the last-known status.
proc repo_is_behind_ff {path} {
	global PULLABLE
	lassign [cached_branch_status $path] branch status
	if {[lsearch -exact $PULLABLE $branch] < 0} { return 0 }
	return [string match "\u2193*" $status]
}

proc async_pull {path done_cmd} {
	set cmd [list git -C $path pull --ff-only]
	if {[catch {set chan [open "|$cmd" r]}]} { after 0 [list {*}$done_cmd fail] ; return }
	fconfigure $chan -blocking 0
	fileevent $chan readable [list _pull_drain $chan $done_cmd]
}

# Classify the pull outcome from git's exit status / error text (surfaced by
# closing the pipe): ok | blocked (local changes) | fail.
proc _pull_drain {chan done_cmd} {
	catch {read $chan}
	if {![eof $chan]} { return }
	fileevent $chan readable {}
	set result ok
	if {[catch {close $chan} err]} {
		if {[string match -nocase {*local change*} $err] \
			|| [string match -nocase {*overwritten*} $err] \
			|| [string match -nocase {*commit your changes*} $err] \
			|| [string match -nocase {*stash*} $err]} {
			set result blocked
		} else {
			set result fail
		}
	}
	uplevel #0 [list {*}$done_cmd $result]
}

proc pull_repo {path} {
	_home_set_status $path "pulling\u2026"
	async_pull $path [list _pull_done $path]
}

proc _pull_apply {path result} {
	global BRANCH_CACHE
	lassign [repo_branch_status $path] br st
	if {$result eq {blocked}} {
		set st "\u26a0 local changes"
	} elseif {$result eq {fail}} {
		set st "\u26a0 pull failed"
	}
	set BRANCH_CACHE($path) [list $br $st]
	_home_apply_cached $path
}

proc _pull_done {path result} { _pull_apply $path $result }

proc pull_all_behind {} {
	global PULL_QUEUE PULL_TOTAL PULL_DONE
	set tv .nb.home.list.tv
	if {![winfo exists $tv]} { return }
	set PULL_QUEUE {}
	foreach it [$tv children {}] {
		set path [lindex [$tv item $it -values] 1]
		if {$path ne {} && [repo_is_behind_ff $path]} { lappend PULL_QUEUE $path }
	}
	set PULL_TOTAL [llength $PULL_QUEUE]
	set PULL_DONE 0
	set lbl .nb.home.head.prog
	if {$PULL_TOTAL == 0} {
		catch {$lbl configure -text "Nothing behind to pull"}
		after 2500 [list catch [list $lbl configure -text ""]]
		return
	}
	_pull_progress
	for {set i 0} {$i < 3} {incr i} { _pull_pump }
}

proc _pull_pump {} {
	global PULL_QUEUE
	if {$PULL_QUEUE eq {}} { return }
	set path [lindex $PULL_QUEUE 0]
	set PULL_QUEUE [lrange $PULL_QUEUE 1 end]
	_home_set_status $path "pulling\u2026"
	async_pull $path [list _pull_all_done $path]
}

proc _pull_all_done {path result} {
	global PULL_DONE
	_pull_apply $path $result
	incr PULL_DONE
	_pull_progress
	_pull_pump
}

proc _pull_progress {} {
	global PULL_TOTAL PULL_DONE
	set lbl .nb.home.head.prog
	if {![winfo exists $lbl]} { return }
	if {$PULL_DONE >= $PULL_TOTAL} {
		$lbl configure -text "Pulled $PULL_TOTAL"
		after 2500 [list catch [list $lbl configure -text ""]]
	} else {
		$lbl configure -text "Pulling\u2026 $PULL_DONE / $PULL_TOTAL"
	}
}

proc refresh_recent {} {
	set tv .nb.home.list.tv
	if {![winfo exists $tv]} { return }
	$tv delete [$tv children {}]
	set pinned [pinned_repos]
	set shown [dict create]
	set i 0
	foreach p $pinned {
		home_insert $tv $p 1 $i
		dict set shown $p 1
		incr i
	}
	foreach p [recent_repos] {
		if {[dict exists $shown $p]} { continue }
		home_insert $tv $p 0 $i
		incr i
	}
	home_autofit_repo
	after idle home_fill_status
}

# Size the repo column to the widest repo path plus a little padding, so it
# hugs the content and leaves the rest of the width to the branch column.
proc home_autofit_repo {} {
	set tv .nb.home.list.tv
	if {![winfo exists $tv]} { return }
	set fam [font actual TkDefaultFont -family]
	set sz  [font actual TkDefaultFont -size]
	set fnt [list $fam $sz bold]
	set maxw [font measure $fnt "Repository"]
	foreach it [$tv children {}] {
		set w [font measure $fnt [lindex [$tv item $it -values] 1]]
		if {$w > $maxw} { set maxw $w }
	}
	$tv column repo -width [expr {$maxw + 28}]
}

proc home_insert {tv path pinned i} {
	global BRANCH_CACHE
	set open [expr {[repo_open_tab $path] ne {}}]
	set glyph {}
	if {$pinned} { append glyph "\u2605" }
	if {$open} { append glyph [expr {$glyph eq {} ? "\u25CF" : " \u25CF"}] }
	set tags [list [expr {$i % 2 ? "odd" : "even"}]]
	if {$pinned} { lappend tags pinned }
	if {$open} { lappend tags isopen }
	if {[info exists BRANCH_CACHE($path)]} {
		lassign $BRANCH_CACHE($path) br st
	} else {
		set br "\u2026" ; set st {}
	}
	$tv insert {} end -values [list $glyph $path $br $st] -tags $tags
}

# Parse the first line of `git status -sb --porcelain` into {branch status}.
# Example lines:
#   ## master...origin/master [ahead 1, behind 2]
#   ## master...origin/master            (up to date)
#   ## master                            (no upstream)
#   ## HEAD (no branch)                  (detached)
proc parse_status_sb {line} {
	if {![string match {## *} $line]} { return [list ? {}] }
	set rest [string range $line 3 end]
	set ab {}
	set idx [string first { [} $rest]
	if {$idx >= 0} {
		set ab [string trimright [string range $rest [expr {$idx+2}] end] {]}]
		set rest [string range $rest 0 [expr {$idx-1}]]
	}
	set hasup 0
	set branch $rest
	set dots [string first {...} $rest]
	if {$dots >= 0} {
		set branch [string range $rest 0 [expr {$dots-1}]]
		set hasup 1
	}
	if {[string match {HEAD (no branch)*} $branch]} { set branch HEAD }
	set ahead 0 ; set behind 0
	regexp {ahead (\d+)} $ab -> ahead
	regexp {behind (\d+)} $ab -> behind
	if {!$hasup} { return [list $branch {}] }
	if {$ahead == 0 && $behind == 0} { return [list $branch "\u2713 up to date"] }
	if {$behind == 0} { return [list $branch "\u2191$ahead ahead"] }
	if {$ahead == 0} { return [list $branch "\u2193$behind behind"] }
	return [list $branch "\u2191$ahead \u2193$behind"]
}

# Local (no-network) branch + ahead/behind in a single async git process.
proc async_branch_status {path done_cmd} {
	set cmd [list git -C $path status -sb --porcelain]
	if {[catch {set chan [open "|$cmd" r]}]} {
		after 0 [list {*}$done_cmd [list ? {}]]
		return
	}
	fconfigure $chan -blocking 0
	set ::_bs_buf($chan) {}
	fileevent $chan readable [list _bs_drain $chan $done_cmd]
}

proc _bs_drain {chan done_cmd} {
	append ::_bs_buf($chan) [read $chan]
	if {![eof $chan]} { return }
	fileevent $chan readable {}
	catch {close $chan}
	set data $::_bs_buf($chan)
	unset -nocomplain ::_bs_buf($chan)
	set first [lindex [split $data \n] 0]
	uplevel #0 [list {*}$done_cmd [parse_status_sb $first]]
}

# Fill branch/status with bounded concurrency (4 git processes at a time) so a
# large recent list populates in parallel without blocking the UI.
proc home_fill_status {{items {}}} {
	global FILL_QUEUE FILL_ACTIVE
	set tv .nb.home.list.tv
	if {![winfo exists $tv]} { return }
	if {$items eq {}} { set items [$tv children {}] }
	set FILL_QUEUE {}
	foreach item $items {
		if {![$tv exists $item]} { continue }
		set path [lindex [$tv item $item -values] 1]
		if {$path ne {}} { lappend FILL_QUEUE $path }
	}
	set FILL_ACTIVE 0
	if {$FILL_QUEUE eq {}} { return }
	for {set i 0} {$i < 4} {incr i} { _fill_pump }
}

proc _fill_pump {} {
	global FILL_QUEUE FILL_ACTIVE
	if {$FILL_QUEUE eq {}} { return }
	set path [lindex $FILL_QUEUE 0]
	set FILL_QUEUE [lrange $FILL_QUEUE 1 end]
	incr FILL_ACTIVE
	async_branch_status $path [list _fill_done $path]
}

proc _fill_done {path bs} {
	global BRANCH_CACHE FILL_ACTIVE FILL_QUEUE
	set BRANCH_CACHE($path) $bs
	_home_apply_cached $path
	incr FILL_ACTIVE -1
	_fill_pump
	if {$FILL_ACTIVE <= 0 && $FILL_QUEUE eq {}} { save_status_cache }
}

# --- persist branch/status across sessions -----------------------------------

proc status_cache_file {} {
	if {[info exists ::env(USERPROFILE)]} {
		set base $::env(USERPROFILE)
	} elseif {[info exists ::env(HOME)]} {
		set base $::env(HOME)
	} else {
		set base [pwd]
	}
	return [file join $base .git-gui-master-status]
}

proc save_status_cache {} {
	global BRANCH_CACHE
	if {[catch {open [status_cache_file] w} ch]} { return }
	fconfigure $ch -encoding utf-8
	foreach k [array names BRANCH_CACHE] {
		catch {puts $ch [list $k $BRANCH_CACHE($k)]}
	}
	catch {close $ch}
}

proc load_status_cache {} {
	global BRANCH_CACHE
	set f [status_cache_file]
	if {![file exists $f]} { return }
	if {[catch {open $f r} ch]} { return }
	fconfigure $ch -encoding utf-8
	set data [read $ch]
	catch {close $ch}
	foreach line [split $data \n] {
		if {[string trim $line] eq {}} { continue }
		if {[catch {llength $line}]} { continue }
		set k [lindex $line 0]
		if {$k ne {}} { set BRANCH_CACHE($k) [lindex $line 1] }
	}
}

proc home_refresh_all {} {
	global BRANCH_CACHE
	array unset BRANCH_CACHE
	refresh_recent
}

proc open_selected_recent {} {
	set tv .nb.home.list.tv
	set sel [$tv selection]
	if {$sel eq {}} { return }
	set path [lindex [$tv item [lindex $sel 0] -values] 1]
	if {$path ne {}} { open_repo $path }
}

proc home_context {x y X Y} {
	set tv .nb.home.list.tv
	set row [$tv identify row $x $y]
	if {$row eq {}} { return }
	$tv selection set $row
	set path [lindex [$tv item $row -values] 1]
	.homemenu delete 0 end
	if {[is_pinned $path]} {
		.homemenu add command -label "Unpin" -command [list unpin_repo $path]
	} else {
		.homemenu add command -label "Pin to top" -command [list pin_repo $path]
	}
	if {[repo_open_tab $path] ne {}} {
		.homemenu add command -label "Jump to tab" -command [list open_repo $path]
	} else {
		.homemenu add command -label "Open" -command [list open_repo $path]
	}
	.homemenu add separator
	.homemenu add command -label "Check remote" -command [list check_remote $path]
	.homemenu add command -label "Pull (fast-forward)" -command [list pull_repo $path]
	tk_popup .homemenu $X $Y
}

# --- simple hover tooltips ---------------------------------------------------

proc tooltip {w text} {
	global TIP
	set TIP($w) $text
	bind $w <Enter> [list _tip_schedule %W]
	bind $w <Leave> [list _tip_hide]
	bind $w <ButtonPress> [list _tip_hide]
}

proc _tip_schedule {w} {
	global TIP
	if {![info exists TIP($w)]} { return }
	_tip_hide
	set ::_TIP_AFTER [after 600 [list _tip_show $w]]
}

proc _tip_hide {} {
	if {[info exists ::_TIP_AFTER]} {
		after cancel $::_TIP_AFTER
		unset ::_TIP_AFTER
	}
	catch {destroy .tip}
}

proc _tip_show {w} {
	global TIP
	catch {unset ::_TIP_AFTER}
	if {![winfo exists $w] || ![info exists TIP($w)]} { return }
	catch {destroy .tip}
	set t [toplevel .tip -borderwidth 0]
	wm overrideredirect $t 1
	catch {wm attributes $t -topmost 1}
	label $t.l -text $TIP($w) -background #ffffe0 -foreground black \
		-borderwidth 1 -relief solid -padx 5 -pady 2 -justify left
	pack $t.l
	set x [expr {[winfo pointerx $w] + 12}]
	set y [expr {[winfo pointery $w] + 18}]
	wm geometry $t +$x+$y
	raise $t
}

proc build_home {} {
	set h [frame .nb.home]
	.nb add $h -text " Home "

	set head [frame $h.head]
	pack $head -fill x -padx 12 -pady {12 6}
	label $head.title -text "Repositories" \
		-font [list [font actual TkDefaultFont -family] 14 bold]
	pack $head.title -side left
	button $head.open -text "Open Folder\u2026" -command browse_open
	pack $head.open -side right
	tooltip $head.open "Browse for a Git repository folder and open it in a tab"
	button $head.refresh -text "Refresh" -command home_refresh_all
	pack $head.refresh -side right -padx {0 6}
	tooltip $head.refresh "Reload the list and re-read each repo's branch and status (no network)"
	button $head.live -text "Check remotes" -command check_all_remotes
	pack $head.live -side right -padx {0 6}
	tooltip $head.live "Fetch every repo from its remote, then update ahead/behind status"
	button $head.pull -text "Pull behind" -command pull_all_behind
	pack $head.pull -side right -padx {0 6}
	tooltip $head.pull "Fast-forward pull every repo that is behind on trunk/master/main/production"
	label $head.prog -fg gray40 -text ""
	pack $head.prog -side right -padx {0 10}

	label $h.hint -fg gray40 -anchor w -text [join {
		"Double-click to open (or jump to its tab if already open)."
		"Right-click to pin.  \u2605 pinned  \u25CF open.  Status is vs your last fetch."} "  "]
	pack $h.hint -fill x -padx 12 -pady {0 6}

	set list [frame $h.list]
	pack $list -expand 1 -fill both -padx 12 -pady {0 12}
	set fam [font actual TkDefaultFont -family]
	set sz  [font actual TkDefaultFont -size]
	ttk::style configure Home.Treeview -rowheight 26
	ttk::style configure Home.Treeview.Heading -font [list $fam $sz bold]
	ttk::treeview $list.tv -columns {status repo branch upstat} -show headings \
		-selectmode browse -style Home.Treeview \
		-yscrollcommand [list $list.sb set]
	$list.tv heading status -text "" -anchor center
	$list.tv heading repo -text "Repository" -anchor w
	$list.tv heading branch -text "Branch" -anchor w
	$list.tv heading upstat -text "Status" -anchor w
	$list.tv column status -width 52 -minwidth 52 -stretch 0 -anchor center
	$list.tv column repo -width 200 -minwidth 120 -stretch 0 -anchor w
	$list.tv column branch -width 220 -minwidth 160 -anchor w -stretch 1
	$list.tv column upstat -width 120 -minwidth 100 -anchor w -stretch 0
	$list.tv tag configure even -background #ffffff
	$list.tv tag configure odd -background #eef2f7
	$list.tv tag configure pinned -font [list $fam $sz bold]
	$list.tv tag configure isopen -foreground #0a7d28
	scrollbar $list.sb -command [list $list.tv yview]
	pack $list.sb -side right -fill y
	pack $list.tv -side left -expand 1 -fill both
	bind $list.tv <Double-Button-1> open_selected_recent
	bind $list.tv <Return> open_selected_recent
	bind $list.tv <ButtonPress-3> {home_context %x %y %X %Y}

	menu .homemenu -tearoff 0
	refresh_recent
}

# -- menus & window -----------------------------------------------------------

proc build_menu {} {
	menu .mbar -tearoff 0
	. configure -menu .mbar

	.mbar add cascade -label "File" -menu .mbar.file
	menu .mbar.file -tearoff 0
	.mbar.file add command -label "Open Folder\u2026" -accelerator "Ctrl+O" \
		-command browse_open
	.mbar.file add command -label "Close Tab" -accelerator "Ctrl+W" \
		-command close_current_tab
	.mbar.file add separator
	.mbar.file add command -label "Quit" -accelerator "Ctrl+Q" -command do_quit

	.mbar add cascade -label "View" -menu .mbar.view
	menu .mbar.view -tearoff 0
	.mbar.view add radiobutton -label "Separate windows" \
		-variable MODE -value separate
	.mbar.view add radiobutton \
		-label "Dock inside tabs (Win32, experimental)" \
		-variable MODE -value dock
	.mbar.view add radiobutton \
		-label "Embed inside tabs (Tk, X11 only)" \
		-variable MODE -value embed
	.mbar.view add separator
	.mbar.view add command -label "Applies to newly opened repositories" \
		-state disabled
}

proc do_quit {} {
	catch {save_status_cache}
	foreach f [array names ::TAB] {
		kill_pid [dict get $::TAB($f) pid]
	}
	exit 0
}

wm title . "git-gui master"
wm geometry . 1040x720

build_menu

ttk::notebook .nb
pack .nb -expand 1 -fill both
menu .tabmenu -tearoff 0

bind .nb <Button-2>       {on_tab_middle %x %y}
bind .nb <ButtonPress-3>  {on_tab_context %x %y %X %Y}
bind .nb <<NotebookTabChanged>> on_tab_changed
bind . <Control-w>        close_current_tab
bind . <Control-W>        close_current_tab
bind . <Control-o>        browse_open
bind . <Control-O>        browse_open
bind . <Control-q>        do_quit
bind . <Control-Q>        do_quit
wm protocol . WM_DELETE_WINDOW do_quit

load_status_cache
build_home
after 2000 poll_children

# Pre-warm the overlay daemon while the user looks at Home, so the first repo
# docks instantly instead of waiting for its one-time Win32 Add-Type compile.
if {$MODE eq {dock}} { after idle ensure_overlay_daemon }

# Open any repositories passed on the command line.
# Flags: --dock / --embed / --separate select the presentation mode.
set _first 1
foreach arg $argv {
	switch -- $arg {
		-- {}
		--dock     { set MODE dock }
		--embed    { set MODE embed }
		--separate { set MODE separate }
		default {
			if {[file isdirectory $arg]} {
				open_repo $arg {} $_first
				set _first 0
			}
		}
	}
}
