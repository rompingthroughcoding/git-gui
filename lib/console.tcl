# git-gui console support
# Copyright (C) 2006, 2007 Shawn Pearce

class console {

field t_short
field t_long
field w
field w_t
field console_cr
field is_toplevel    1; # are we our own window?
field fit_pending    0; # is a resize already queued?
field fit_placed     0; # have we positioned ourselves yet?
field fit_scanned    0; # last line measured for its width
field fit_cols       0; # widest line seen so far

constructor new {short_title long_title} {
	set t_short $short_title
	set t_long $long_title
	_init $this
	return $this
}

constructor embed {path title} {
	set t_short {}
	set t_long $title
	set w $path
	set is_toplevel 0
	_init $this
	return $this
}

method _init {} {
	global M1B

	if {$is_toplevel} {
		make_dialog top w -autodelete 0
		wm title $top "[appname] ([reponame]): $t_short"
	} else {
		ttk::frame $w
	}

	set console_cr 1.0
	set w_t $w.m.t

	ttk::frame $w.m
	ttk::label $w.m.l1 \
		-textvariable @t_long  \
		-anchor w \
		-justify left \
		-font font_uibold
	text $w_t \
		-background white \
		-foreground black \
		-borderwidth 1 \
		-relief sunken \
		-width 80 -height 10 \
		-wrap none \
		-font font_diff \
		-state disabled \
		-xscrollcommand [cb _sb_set $w.m.sbx h] \
		-yscrollcommand [cb _sb_set $w.m.sby v]
	label $w.m.s -text [mc "Working... please wait..."] \
		-anchor w \
		-justify left \
		-font font_uibold
	pack $w.m.l1 -side top -fill x
	pack $w.m.s -side bottom -fill x
	pack $w_t -side left -fill both -expand 1
	pack $w.m -side top -fill both -expand 1 -padx 5 -pady 10

	menu $w.ctxm -tearoff 0
	$w.ctxm add command -label [mc "Copy"] \
		-command "tk_textCopy $w_t"
	$w.ctxm add command -label [mc "Select All"] \
		-command "focus $w_t;$w_t tag add sel 0.0 end"
	$w.ctxm add command -label [mc "Copy All"] \
		-command "
			$w_t tag add sel 0.0 end
			tk_textCopy $w_t
			$w_t tag remove sel 0.0 end
		"

	if {$is_toplevel} {
		ttk::button $w.ok -text [mc "Close"] \
			-state disabled \
			-command [list destroy $w]
		pack $w.ok -side bottom -anchor e -pady 10 -padx 10
		bind $w <Visibility> [list focus $w]
	}

	bind_button3 $w_t "tk_popup $w.ctxm %X %Y"
	bind $w_t <$M1B-Key-a> "$w_t tag add sel 0.0 end;break"
	bind $w_t <$M1B-Key-A> "$w_t tag add sel 0.0 end;break"
}

# Largest area {x y width height} this window may occupy while the diff
# file name header and the commit message box of the main window stay
# visible underneath it.
method _fit_area {} {
	set pad 10
	set hdr .vpane.lower.diff.header
	set cmt .vpane.lower.commarea

	if {[winfo exists $hdr] && [winfo ismapped $hdr]
	 && [winfo exists $cmt] && [winfo ismapped $cmt]} {
		set x [expr {[winfo rootx .] + $pad}]
		set y [expr {[winfo rooty $hdr] + [winfo height $hdr] + $pad}]
		return [list $x $y \
			[expr {[winfo width .] - 2 * $pad}] \
			[expr {[winfo rooty $cmt] - $pad - $y}]]
	}

	set sw [winfo screenwidth .]
	set sh [winfo screenheight .]
	set width [expr {$sw * 3 / 4}]
	set height [expr {$sh * 3 / 4}]
	return [list \
		[expr {($sw - $width) / 2}] \
		[expr {($sh - $height) / 2}] \
		$width $height]
}

method _fit {} {
	set fit_pending 0
	if {!$is_toplevel || ![winfo exists $w_t]} return

	set top [winfo toplevel $w_t]
	set rows [expr {int([$w_t index {end - 1 c}])}]

	# Re-measure the last known line, \r rewrites may have changed it.
	for {set i [expr {$fit_scanned > 0 ? $fit_scanned : 1}]} \
		{$i <= $rows} {incr i} {
		set len [string length [$w_t get $i.0 "$i.0 lineend"]]
		if {$len > $fit_cols} {set fit_cols $len}
	}
	set fit_scanned $rows

	set cw [font measure font_diff -displayof $w_t 0]
	set lh [font metrics font_diff -displayof $w_t -linespace]
	if {$cw < 1} {set cw 1}
	if {$lh < 1} {set lh 1}

	set area [_fit_area $this]
	set over_w [expr {[winfo reqwidth $top] - [winfo reqwidth $w_t]}]
	set over_h [expr {[winfo reqheight $top] - [winfo reqheight $w_t]}]
	if {$over_w < 0} {set over_w 0}
	if {$over_h < 0} {set over_h 0}
	# Allowance for the window manager's title bar and borders.
	incr over_h 40

	set max_cols [expr {([lindex $area 2] - $over_w) / $cw}]
	set max_rows [expr {([lindex $area 3] - $over_h) / $lh}]
	if {$max_cols < 80} {set max_cols 80}
	if {$max_rows < 10} {set max_rows 10}

	set cols [expr {$fit_cols + 1}]
	if {$cols < 80} {set cols 80}
	if {$cols > $max_cols} {set cols $max_cols}
	if {$rows < 10} {set rows 10}
	if {$rows > $max_rows} {set rows $max_rows}

	if {$cols == [$w_t cget -width] && $rows == [$w_t cget -height]} return
	$w_t conf -width $cols -height $rows

	if {!$fit_placed} {
		set fit_placed 1
		wm geometry $top +[lindex $area 0]+[lindex $area 1]
	}
} ifdeleted {return}

method _sched_fit {} {
	if {!$is_toplevel || $fit_pending} return
	set fit_pending 1
	after idle [cb _fit]
}

method exec {cmd {after {}}} {
	if {[lindex $cmd 0] eq {git}} {
		set fd_f [git_read [lrange $cmd 1 end] [list 2>@1]]
	} else {
		set fd_f [safe_open_command $cmd [list 2>@1]]
	}
	fconfigure $fd_f -blocking 0 -translation binary -encoding [encoding system]
	fileevent $fd_f readable [cb _read $fd_f $after]
}

method _read {fd after} {
	set buf [read $fd]
	if {$buf ne {}} {
		if {![winfo exists $w_t]} {_init $this}
		$w_t conf -state normal
		set c 0
		set n [string length $buf]
		while {$c < $n} {
			set cr [string first "\r" $buf $c]
			set lf [string first "\n" $buf $c]
			if {$cr < 0} {set cr [expr {$n + 1}]}
			if {$lf < 0} {set lf [expr {$n + 1}]}

			if {$lf < $cr} {
				$w_t insert end [string range $buf $c $lf]
				set console_cr [$w_t index {end -1c}]
				set c $lf
				incr c
			} else {
				$w_t delete $console_cr end
				$w_t insert end "\n"
				$w_t insert end [string range $buf $c [expr {$cr - 1}]]
				set c $cr
				incr c
			}
		}
		$w_t conf -state disabled
		$w_t see end
		_sched_fit $this
	}

	fconfigure $fd -blocking 1
	if {[eof $fd]} {
		if {[catch {close $fd}]} {
			set ok 0
		} else {
			set ok 1
		}
		if {$after ne {}} {
			uplevel #0 $after $ok
		} else {
			done $this $ok
		}
		return
	}
	fconfigure $fd -blocking 0
}

method chain {cmdlist {ok 1}} {
	if {$ok} {
		if {[llength $cmdlist] == 0} {
			done $this $ok
			return
		}

		set cmd [lindex $cmdlist 0]
		set cmdlist [lrange $cmdlist 1 end]

		if {[lindex $cmd 0] eq {exec}} {
			exec $this \
				[lrange $cmd 1 end] \
				[cb chain $cmdlist]
		} else {
			uplevel #0 $cmd [cb chain $cmdlist]
		}
	} else {
		done $this $ok
	}
}

method insert {txt} {
	if {![winfo exists $w_t]} {_init $this}
	$w_t conf -state normal
	$w_t insert end "$txt\n"
	set console_cr [$w_t index {end -1c}]
	$w_t conf -state disabled
	_sched_fit $this
}

method done {ok} {
	if {$ok} {
		if {[winfo exists $w.m.s]} {
			bind $w.m.s <Destroy> [list delete_this $this]
			$w.m.s conf -background green -foreground black \
				-text [mc "Success"]
			if {$is_toplevel} {
				$w.ok conf -state normal
				focus $w.ok
			}
		} else {
			delete_this
		}
	} else {
		if {![winfo exists $w.m.s]} {
			_init $this
		}
		bind $w.m.s <Destroy> [list delete_this $this]
		$w.m.s conf -background red -foreground black \
			-text [mc "Error: Command Failed"]
		if {$is_toplevel} {
			$w.ok conf -state normal
			focus $w.ok
		}
	}

	bind $w <Key-Escape> "destroy $w;break"
}

method _sb_set {sb orient first last} {
	if {![winfo exists $sb]} {
		if {$first == $last || ($first == 0 && $last == 1)} return
		if {$orient eq {h}} {
			ttk::scrollbar $sb -orient h -command [list $w_t xview]
			pack $sb -fill x -side bottom -before $w_t
		} else {
			ttk::scrollbar $sb -orient v -command [list $w_t yview]
			pack $sb -fill y -side right -before $w_t
		}
	}
	$sb set $first $last
}

}
