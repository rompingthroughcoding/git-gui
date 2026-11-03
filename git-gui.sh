#!/bin/sh
# Tcl ignores the next line -*- tcl -*- \
 if test "z$*" = zversion \
 || test "z$*" = z--version; \
 then \
	echo 'git-gui version @@GITGUI_VERSION@@'; \
	exit; \
 fi; \
 argv0=$0; \
 exec wish "$argv0" -- "$@"

set appvers {@@GITGUI_VERSION@@}
set copyright [string map [list (c) \u00a9] {
Copyright (c) 2006-2010 Shawn Pearce, et. al.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, see <https://www.gnu.org/licenses/>.}]

######################################################################
##
## Tcl/Tk sanity check

if {[catch {package require Tcl 8.6-} err]} {
	catch {wm withdraw .}
	tk_messageBox \
		-icon error \
		-type ok \
		-title "git-gui: fatal error" \
		-message $err
	exit 1
}

catch {rename send {}} ; # What an evil concept...

######################################################################
##
## Enabling platform-specific code paths

proc is_MacOSX {} {
	if {[tk windowingsystem] eq {aqua}} {
		return 1
	}
	return 0
}

proc is_Windows {} {
	if {$::tcl_platform(platform) eq {windows}} {
		return 1
	}
	return 0
}

set _iscygwin {}
proc is_Cygwin {} {
	global _iscygwin
	if {$_iscygwin eq {}} {
		if {[string match "CYGWIN_*" $::tcl_platform(os)]} {
			set _iscygwin 1
		} else {
			set _iscygwin 0
		}
	}
	return $_iscygwin
}

######################################################################
## Enable Tcl8 profile in Tcl9, allowing consumption of data that has
## bytes not conforming to the assumed encoding profile.

if {[package vcompare $::tcl_version 9.0] >= 0} {
	rename open _strict_open
	proc open args {
		set f [_strict_open {*}$args]
		chan configure $f -profile tcl8
		return $f
	}
	proc convertfrom args {
		return [encoding convertfrom -profile tcl8 {*}$args]
	}
} else {
	proc convertfrom args {
		return [encoding convertfrom {*}$args]
	}
}

######################################################################
##
## PATH lookup. Sanitize $PATH, assure exec/open use only that

if {[is_Windows]} {
	set _path_sep {;}
} else {
	set _path_sep {:}
}

set _path_seen [dict create]
foreach p [split $env(PATH) $_path_sep] {
	# Keep only absolute paths, getting rid of ., empty, etc.
	if {[file pathtype $p] ne {absolute}} {
		continue
	}
	# Keep only the first occurence of any duplicates.
	set norm_p [file normalize $p]
	dict set _path_seen $norm_p 1
}
set _search_path [dict keys $_path_seen]
unset _path_seen

set env(PATH) [join $_search_path $_path_sep]

if {[is_Windows]} {
	proc _which {what args} {
		global _search_path

		if {[lsearch -exact $args -script] >= 0} {
			set suffix {}
		} elseif {[string match *.exe [string tolower $what]]} {
			# The search string already has the file extension
			set suffix {}
		} else {
			set suffix .exe
		}

		foreach p $_search_path {
			set p [file join $p $what$suffix]
			if {[file exists $p]} {
				return [file normalize $p]
			}
		}
		return {}
	}

	proc sanitize_command_line {command_line from_index} {
		set i $from_index
		while {$i < [llength $command_line]} {
			set cmd [lindex $command_line $i]
			if {[llength [file split $cmd]] < 2} {
				set fullpath [_which $cmd]
				if {$fullpath eq ""} {
					throw {NOT-FOUND} "$cmd not found in PATH"
				}
				lset command_line $i $fullpath
			}

			# handle piped commands, e.g. `exec A | B`
			for {incr i} {$i < [llength $command_line]} {incr i} {
				if {[lindex $command_line $i] eq "|"} {
					incr i
					break
				}
			}
		}
		return $command_line
	}

	# Override `exec` to avoid unsafe PATH lookup

	rename exec real_exec

	proc exec {args} {
		# skip options
		for {set i 0} {$i < [llength $args]} {incr i} {
			set arg [lindex $args $i]
			if {$arg eq "--"} {
				incr i
				break
			}
			if {[string range $arg 0 0] ne "-"} {
				break
			}
		}
		set args [sanitize_command_line $args $i]
		uplevel 1 real_exec $args
	}

	# Override `open` to avoid unsafe PATH lookup

	rename open real_open

	proc open {args} {
		set arg0 [lindex $args 0]
		if {[string range $arg0 0 0] eq "|"} {
			set command_line [string trim [string range $arg0 1 end]]
			lset args 0 "| [sanitize_command_line $command_line 0]"
		}
		set fd [real_open {*}$args]
		fconfigure $fd -eofchar {}
		return $fd
	}

} else {
	# On non-Windows platforms, auto_execok, exec, and open are safe, and will
	# use the sanitized search path. But, we need _which for these.

	proc _which {what args} {
		return [lindex [auto_execok $what] 0]
	}
}

# Wrap exec/open to sanitize arguments

# unsafe arguments begin with redirections or the pipe or background operators
proc is_arg_unsafe {arg} {
	regexp {^([<|>&]|2>)} $arg
}

proc make_arg_safe {arg} {
	if {[is_arg_unsafe $arg]} {
		set arg [file join . $arg]
	}
	return $arg
}

proc make_arglist_safe {arglist} {
	set res {}
	foreach arg $arglist {
		lappend res [make_arg_safe $arg]
	}
	return $res
}

# executes one command
# no redirections or pipelines are possible
# cmd is a list that specifies the command and its arguments
# calls `exec` and returns its value
proc safe_exec {cmd} {
	eval exec [make_arglist_safe $cmd]
}

# executes one command in the background
# no redirections or pipelines are possible
# cmd is a list that specifies the command and its arguments
# calls `exec` and returns its value
proc safe_exec_bg {cmd} {
	eval exec [make_arglist_safe $cmd] &
}

proc safe_open_file {filename flags} {
	# a file name starting with "|" would attempt to run a process
	# but such a file name must be treated as a relative path
	# hide the "|" behind "./"
	if {[string index $filename 0] eq "|"} {
		set filename [file join . $filename]
	}
	open $filename $flags
}

# End exec/open wrappers

######################################################################
##
## locate our library

if { [info exists ::env(GIT_GUI_LIB_DIR) ] } {
	set oguilib $::env(GIT_GUI_LIB_DIR)
} else {
	set oguilib {@@GITGUI_LIBDIR@@}
}
set oguirel {@@GITGUI_RELATIVE@@}
if {$oguirel eq {1}} {
	set oguilib [file dirname [file normalize $argv0]]
	if {[file tail $oguilib] eq {git-core}} {
		set oguilib [file dirname $oguilib]
	}
	set oguilib [file dirname $oguilib]
	set oguilib [file join $oguilib share git-gui lib]
	set oguimsg [file join $oguilib msgs]
} elseif {[string match @@* $oguirel]} {
	set oguilib [file join [file dirname [file normalize $argv0]] lib]
	set oguimsg [file join [file dirname [file normalize $argv0]] po]
} else {
	set oguimsg [file join $oguilib msgs]
}
unset oguirel

######################################################################
##
## enable verbose loading?

if {![catch {set _verbose $env(GITGUI_VERBOSE)}]} {
	unset _verbose
	rename auto_load real__auto_load
	proc auto_load {name args} {
		puts stderr "auto_load $name"
		return [uplevel 1 real__auto_load $name $args]
	}
	rename source real__source
	proc source {args} {
		puts stderr "source    $args"
		uplevel 1 [linsert $args 0 real__source]
	}
	if {[tk windowingsystem] eq "win32"} { console show }
}

######################################################################
##
## Internationalization (i18n) through msgcat and gettext. See
## http://www.gnu.org/software/gettext/manual/html_node/Tcl.html

package require msgcat

# Check for Windows 7 MUI language pack (missed by msgcat < 1.4.4)
if {[tk windowingsystem] eq "win32"
	&& [package vcompare [package provide msgcat] 1.4.4] < 0
} then {
	proc _mc_update_locale {} {
		set key {HKEY_CURRENT_USER\Control Panel\Desktop}
		if {![catch {
			package require registry
			set uilocale [registry get $key "PreferredUILanguages"]
			msgcat::ConvertLocale [string map {- _} [lindex $uilocale 0]]
		} uilocale]} {
			if {[string length $uilocale] > 0} {
				msgcat::mclocale $uilocale
			}
		}
	}
	_mc_update_locale
}

proc _mc_trim {fmt} {
	set cmk [string first @@ $fmt]
	if {$cmk > 0} {
		return [string range $fmt 0 [expr {$cmk - 1}]]
	}
	return $fmt
}

proc mc {en_fmt args} {
	set fmt [_mc_trim [::msgcat::mc $en_fmt]]
	if {[catch {set msg [eval [list format $fmt] $args]} err]} {
		set msg [eval [list format [_mc_trim $en_fmt]] $args]
	}
	return $msg
}

proc strcat {args} {
	return [join $args {}]
}

::msgcat::mcload $oguimsg
unset oguimsg

######################################################################
##
## On Mac, bring the current Wish process window to front

if {[tk windowingsystem] eq "aqua"} {
	catch {
		safe_exec [list osascript -e [format {
			tell application "System Events"
				set frontmost of processes whose unix id is %d to true
			end tell
		} [pid]]]
	}
}

######################################################################
##
## read only globals

set _appname {Git Gui}
set _gitdir {}
set _gitworktree {}
set _isbare {}
set _githtmldir {}
set _reponame {}
set _shellpath {@@SHELL_PATH@@}

set _trace [lsearch -exact $argv --trace]
if {$_trace >= 0} {
	set argv [lreplace $argv $_trace $_trace]
	set _trace 1
	if {[tk windowingsystem] eq "win32"} { console show }
} else {
	set _trace 0
}

# variable for the last merged branch (useful for a default when deleting
# branches).
set _last_merged_branch {}

# for testing, allow unconfigured _shellpath
if {[string match @@* $_shellpath]} {
	if {[info exists env(SHELL)]} {
		set _shellpath $env(SHELL)
	} else {
		set _shellpath /bin/sh
	}
}

if {[is_Windows]} {
	set _shellpath [safe_exec [list cygpath -m $_shellpath]]
}

if {![file executable $_shellpath] || \
	!([file pathtype $_shellpath] eq {absolute})} {
	set errmsg "The defined shell ('$_shellpath') is not usable, \
		it must be an absolute path to an executable."
	puts stderr $errmsg

	catch {wm withdraw .}
	tk_messageBox \
		-icon error \
		-type ok \
		-title "git-gui: configuration error" \
		-message $errmsg
	exit 1
}


proc shellpath {} {
	global _shellpath
	return $_shellpath
}

proc appname {} {
	global _appname
	return $_appname
}

proc gitdir {args} {
	set dir [repoctx::field gitdir]
	if {$args eq {}} {
		return $dir
	}
	return [eval [list file join $dir] $args]
}

proc githtmldir {args} {
	global _githtmldir
	if {$_githtmldir eq {}} {
		if {[catch {set _githtmldir [git --html-path]}]} {
			# Git not installed or option not yet supported
			return {}
		}
		set _githtmldir [file normalize $_githtmldir]
	}
	if {$args eq {}} {
		return $_githtmldir
	}
	return [eval [list file join $_githtmldir] $args]
}

proc reponame {} {
	return [repoctx::field reponame]
}

proc is_enabled {option} {
	global enabled_options
	if {[catch {set on $enabled_options($option)}]} {return 0}
	return $on
}

proc enable_option {option} {
	global enabled_options
	set enabled_options($option) 1
}

proc disable_option {option} {
	global enabled_options
	set enabled_options($option) 0
}

######################################################################
##
## config

proc is_many_config {name} {
	switch -glob -- $name {
	gui.recentrepo -
	gui.sessionrepo -
	remote.*.fetch -
	remote.*.push
		{return 1}
	*
		{return 0}
	}
}

proc is_config_true {name} {
	global repo_config
	if {[catch {set v $repo_config($name)}]} {
		return 0
	}
	set v [string tolower $v]
	if {$v eq {} || $v eq {true} || $v eq {1} || $v eq {yes} || $v eq {on}} {
		return 1
	} else {
		return 0
	}
}

proc is_config_false {name} {
	global repo_config
	if {[catch {set v $repo_config($name)}]} {
		return 0
	}
	set v [string tolower $v]
	if {$v eq {false} || $v eq {0} || $v eq {no} || $v eq {off}} {
		return 1
	} else {
		return 0
	}
}

proc get_config {name} {
	global repo_config
	if {[catch {set v $repo_config($name)}]} {
		return {}
	} else {
		return $v
	}
}

proc is_bare {} {
	global _isbare
	global _gitdir
	global _gitworktree

	if {$_isbare eq {}} {
		if {[catch {
			set _bare [git rev-parse --is-bare-repository]
			switch  -- $_bare {
			true { set _isbare 1 }
			false { set _isbare 0}
			default { throw }
			}
		}]} {
			if {[is_config_true core.bare]
				|| ($_gitworktree eq {}
					&& [lindex [file split $_gitdir] end] ne {.git})} {
				set _isbare 1
			} else {
				set _isbare 0
			}
		}
	}
	return $_isbare
}

######################################################################
##
## handy utils

proc _trace_exec {cmd} {
	if {!$::_trace} return
	set d {}
	foreach v $cmd {
		if {$d ne {}} {
			append d { }
		}
		if {[regexp {[ \t\r\n'"$?*]} $v]} {
			set v [sq $v]
		}
		append d $v
	}
	puts stderr $d
}

#'"  fix poor old emacs font-lock mode

# This is for use with textconv filters and uses sh -c "..." to allow it to
# contain a command with arguments. We presume this
# to be a shellscript that the configured shell (/bin/sh by default) knows
# how to run.
proc open_cmd_pipe {cmd path} {
	set run [list [shellpath] -c "$cmd \"\$0\"" $path]
	set run [make_arglist_safe $run]
	return [open |$run r]
}

proc git {args} {
	git_redir $args {}
}

proc git_redir {cmd redir} {
	set fd [git_read $cmd $redir]
	fconfigure $fd -encoding utf-8
	set result [string trimright [read $fd] "\n"]
	close $fd
	if {$::_trace} {
		puts stderr "< $result"
	}
	return $result
}

proc safe_open_command {cmd {redir {}}} {
	set cmd [make_arglist_safe $cmd]
	_trace_exec [concat $cmd $redir]
	if {[catch {
		set fd [open [concat [list | ] $cmd $redir] r]
	} err]} {
		error $err
	}
	return $fd
}

proc git_read {cmd {redir {}}} {
	global _git
	set cmdp [concat [list $_git] $cmd]

	return [safe_open_command $cmdp $redir]
}

set _nice [list [_which nice]]
if {[catch {safe_exec [list {*}$_nice git version]}]} {
	set _nice {}
}

proc git_read_nice {cmd} {
	set cmdp [list {*}$::_nice $::_git {*}$cmd]
	return [safe_open_command $cmdp]
}

proc git_write {cmd} {
	global _git
	set cmd [make_arglist_safe $cmd]
	set cmdp [concat [list $_git] $cmd]

	_trace_exec $cmdp
	return [open [concat [list | ] $cmdp] w]
}

proc githook_read {hook_name args} {
	git_read [concat [list hook run --ignore-missing $hook_name --] $args] [list 2>@1]
}

proc kill_file_process {fd} {
	set process [pid $fd]

	catch {
		if {[is_Windows]} {
			safe_exec [list taskkill /pid $process]
		} else {
			safe_exec [list kill $process]
		}
	}
}

proc gitattr {path attr default} {
	if {[catch {set r [git check-attr $attr -- $path]}]} {
		set r unspecified
	} else {
		set r [join [lrange [split $r :] 2 end] :]
		regsub {^ } $r {} r
	}
	if {$r eq {unspecified}} {
		return $default
	}
	return $r
}

proc sq {value} {
	regsub -all ' $value "'\\''" value
	return "'$value'"
}

proc load_current_branch {} {
	global current_branch is_detached

	set current_branch [git branch --show-current]
	set is_detached [expr [string length $current_branch] == 0]
}

auto_load tk_optionMenu
rename tk_optionMenu real__tkOptionMenu
proc tk_optionMenu {w varName args} {
	set m [eval real__tkOptionMenu $w $varName $args]
	$m configure -font font_ui
	$w configure -font font_ui
	return $m
}

proc rmsel_tag {text} {
	$text tag conf sel \
		-background [$text cget -background] \
		-foreground [$text cget -foreground] \
		-borderwidth 0
	bind $text <Motion> break
	return $text
}

wm withdraw .
set root_exists 0
bind . <Visibility> {
	bind . <Visibility> {}
	set root_exists 1
}

if {[is_Windows]} {
	wm iconbitmap . -default $oguilib/git-gui.ico
	set ::tk::AlwaysShowSelection 1
	bind . <Control-F2> {console show}

	# Spoof an X11 display for SSH
	if {![info exists env(DISPLAY)]} {
		set env(DISPLAY) :9999
	}
} else {
	catch {
		image create photo gitlogo -width 16 -height 16

		gitlogo put #33CC33 -to  7  0  9  2
		gitlogo put #33CC33 -to  4  2 12  4
		gitlogo put #33CC33 -to  7  4  9  6
		gitlogo put #CC3333 -to  4  6 12  8
		gitlogo put gray26  -to  4  9  6 10
		gitlogo put gray26  -to  3 10  6 12
		gitlogo put gray26  -to  8  9 13 11
		gitlogo put gray26  -to  8 11 10 12
		gitlogo put gray26  -to 11 11 13 14
		gitlogo put gray26  -to  3 12  5 14
		gitlogo put gray26  -to  5 13
		gitlogo put gray26  -to 10 13
		gitlogo put gray26  -to  4 14 12 15
		gitlogo put gray26  -to  5 15 11 16
		gitlogo redither

		image create photo gitlogo32 -width 32 -height 32
		gitlogo32 copy gitlogo -zoom 2 2

		wm iconphoto . -default gitlogo gitlogo32
	}
}

######################################################################
##
## config defaults

set cursor_ptr arrow
font create font_ui
if {[lsearch -exact [font names] TkDefaultFont] != -1} {
	eval [linsert [font actual TkDefaultFont] 0 font configure font_ui]
	eval [linsert [font actual TkFixedFont] 0 font create font_diff]
} else {
	font create font_diff -family Courier -size 10
	catch {
		label .dummy
		eval font configure font_ui [font actual [.dummy cget -font]]
		destroy .dummy
	}
}
#font configure font_ui -size [expr {abs([font configure font_ui -size]) + 4}]

font create font_uiitalic
font create font_uibold
font create font_diffbold
font create font_diffitalic

foreach class {Button Checkbutton Entry Label
		Labelframe Listbox Message
		Radiobutton Spinbox Text} {
	option add *$class.font font_ui
}
if {![is_MacOSX]} {
	option add *Menu.font font_ui
	option add *Entry.borderWidth 1 startupFile
	option add *Entry.relief sunken startupFile
	option add *RadioButton.anchor w startupFile
}
unset class

if {[is_Windows] || [is_MacOSX]} {
	option add *Menu.tearOff 0
}

if {[is_MacOSX]} {
	set M1B M1
	set M1T Cmd
} else {
	set M1B Control
	set M1T Ctrl
}

proc bind_button3 {w cmd} {
	bind $w <Any-Button-3> $cmd
	if {[is_MacOSX]} {
		# Mac OS X sends Button-2 on right click through three-button mouse,
		# or through trackpad right-clicking (two-finger touch + click).
		bind $w <Any-Button-2> $cmd
		bind $w <Control-Button-1> $cmd
	}
}

proc apply_config {} {
	global repo_config font_descs

	foreach option $font_descs {
		set name [lindex $option 0]
		set font [lindex $option 1]
		if {[catch {
			set need_weight 1
			foreach {cn cv} $repo_config(gui.$name) {
				if {$cn eq {-weight}} {
					set need_weight 0
				}
				font configure $font $cn $cv
			}
			if {$need_weight} {
				font configure $font -weight normal
			}
			} err]} {
			error_popup [strcat [mc "Invalid font specified in %s:" "gui.$name"] "\n\n$err"]
		}
		foreach {cn cv} [font configure $font] {
			font configure ${font}bold $cn $cv
			font configure ${font}italic $cn $cv
		}
		font configure ${font}bold -weight bold
		font configure ${font}italic -slant italic
	}

	bind [winfo class .] <<ThemeChanged>> [list InitTheme]
	pave_toplevel .
	color::sync_with_theme

	global comment_string
	set comment_string [get_config core.commentstring]
	if {$comment_string eq {}} {
		set comment_string [get_config core.commentchar]
	}
}

set default_config(branch.autosetupmerge) true
set default_config(merge.tool) {}
set default_config(mergetool.keepbackup) true
set default_config(merge.diffstat) true
set default_config(merge.summary) false
set default_config(merge.verbosity) 2
set default_config(user.name) {}
set default_config(user.email) {}
set default_config(core.commentchar) "#"
set default_config(core.commentstring) {}

set default_config(gui.encoding) [encoding system]
set default_config(gui.matchtrackingbranch) false
set default_config(gui.textconv) true
set default_config(gui.pruneduringfetch) false
set default_config(gui.trustmtime) false
set default_config(gui.fastcopyblame) false
set default_config(gui.maxrecentrepo) 10
set default_config(gui.copyblamethreshold) 40
set default_config(gui.blamehistoryctx) 7
set default_config(gui.diffcontext) 5
set default_config(gui.diffwholefile) false
set default_config(gui.diffopts) {}
set default_config(gui.commitmsgwidth) 75
set default_config(gui.newbranchtemplate) {}
set default_config(gui.spellingdictionary) {}
set default_config(gui.browser) {}
set default_config(gui.fontui) [font configure font_ui]
set default_config(gui.fontdiff) [font configure font_diff]
# TODO: this option should be added to the git-config documentation
set default_config(gui.maxfilesdisplayed) 5000
set default_config(gui.usettk) 1
set default_config(gui.warndetachedcommit) 1
set default_config(gui.restoretabs) false
set default_config(gui.tabsize) 8
set font_descs {
	{fontui   font_ui   {mc "Main Font"}}
	{fontdiff font_diff {mc "Diff/Console Font"}}
}
set default_config(gui.stageuntracked) ask
set default_config(gui.displayuntracked) true
set default_config(gui.autosizefilelists) true

######################################################################
##
## find git

set _git  [_which git]
if {$_git eq {}} {
	catch {wm withdraw .}
	tk_messageBox \
		-icon error \
		-type ok \
		-title [mc "git-gui: fatal error"] \
		-message [mc "Cannot find git in PATH."]
	exit 1
}

######################################################################
##
## version check

set MIN_GIT_VERSION 2.36

if {[catch {set _git_version [git --version]} err]} {
	catch {wm withdraw .}
	tk_messageBox \
		-icon error \
		-type ok \
		-title [mc "git-gui: fatal error"] \
		-message "Cannot determine Git version:

$err

[appname] requires Git $MIN_GIT_VERSION or later."
	exit 1
}

if {![regsub {^git version } $_git_version {} _git_version]} {
	catch {wm withdraw .}
	tk_messageBox \
		-icon error \
		-type ok \
		-title [mc "git-gui: fatal error"] \
		-message [strcat [mc "Cannot parse Git version string:"] "\n\n$_git_version"]
	exit 1
}

proc get_trimmed_version {s} {
	set r {}
	foreach x [split $s -._] {
		if {[string is integer -strict $x]} {
			lappend r $x
		} else {
			break
		}
	}
	return [join $r .]
}
set _real_git_version $_git_version
set _git_version [get_trimmed_version $_git_version]

if {[catch {set vcheck [package vcompare $_git_version $MIN_GIT_VERSION]}] ||
	[expr $vcheck < 0] } {

	set msg1 [mc "Insufficient git version, require: "]
	set msg2 [mc "git returned:"]
	set message "$msg1 $MIN_GIT_VERSION\n$msg2 $_real_git_version"
	catch {wm withdraw .}
	tk_messageBox \
		-icon error \
		-type ok \
		-title [mc "git-gui: fatal error"] \
		-message $message
	exit 1
}
unset _real_git_version

######################################################################
##
## configure our library

set idx [file join $oguilib tclIndex]
if {[catch {set fd [safe_open_file $idx r]} err]} {
	catch {wm withdraw .}
	tk_messageBox \
		-icon error \
		-type ok \
		-title [mc "git-gui: fatal error"] \
		-message $err
	exit 1
}
if {[gets $fd] eq {# Autogenerated by git-gui Makefile}} {
	set idx [list]
	while {[gets $fd n] >= 0} {
		if {$n ne {} && ![string match #* $n]} {
			lappend idx $n
		}
	}
} else {
	set idx {}
}
close $fd

if {$idx ne {}} {
	set loaded [list]
	foreach p $idx {
		if {[lsearch -exact $loaded $p] >= 0} continue
		source [file join $oguilib $p]
		lappend loaded $p
	}
	unset loaded p
} else {
	set auto_path [concat [list $oguilib] $auto_path]
}
unset -nocomplain idx fd

# Multi-repo fork spike: per-repo context scaffolding (see lib/repoctx.tcl).
source [file join $oguilib repoctx.tcl]

######################################################################
##
## config file parsing

proc _parse_config {arr_name args} {
	upvar $arr_name arr
	array unset arr
	set buf {}
	catch {
		set fd_rc [git_read \
			[concat config \
			$args \
			--null --list]]
		fconfigure $fd_rc -encoding binary -translation binary
		set buf [encoding convertfrom utf-8 [read $fd_rc]]
		close $fd_rc
	}
	foreach line [split $buf "\0"] {
		if {[regexp {^([^\n]+)\n(.*)$} $line line name value]} {
			if {[is_many_config $name]} {
				lappend arr($name) $value
			} else {
				set arr($name) $value
			}
		} elseif {[regexp {^([^\n]+)$} $line line name]} {
			# no value given, but interpreting them as
			# boolean will be handled as true
			set arr($name) {}
		}
	}
}

proc load_config {include_global} {
	global repo_config global_config system_config default_config

	if {$include_global} {
		_parse_config system_config --system
		_parse_config global_config --global
	}
	_parse_config repo_config

	foreach name [array names default_config] {
		if {[catch {set v $system_config($name)}]} {
			set system_config($name) $default_config($name)
		}
	}
	foreach name [array names system_config] {
		if {[catch {set v $global_config($name)}]} {
			set global_config($name) $system_config($name)
		}
		if {[catch {set v $repo_config($name)}]} {
			set repo_config($name) $system_config($name)
		}
	}
}

######################################################################
##
## feature option selection

if {[regexp {^git-(.+)$} [file tail $argv0] _junk subcommand]} {
	unset _junk
} else {
	set subcommand gui
}
if {$subcommand eq {gui.sh}} {
	set subcommand gui
}
if {$subcommand eq {gui} && [llength $argv] > 0} {
	set a [lindex $argv 0]
	if {[file isdirectory $a]} {
		# One or more repository path arguments: open each in its own tab.
		# The first is the primary repo used for normal startup; the rest are
		# opened as extra tabs once the UI is ready.
		set _multi_repo_paths {}
		foreach p $argv {
			if {[file isdirectory $p]} {
				lappend _multi_repo_paths [file normalize $p]
			}
		}
		set argv {}
		# Explicit paths win over any GIT_DIR/GIT_WORK_TREE inherited from the
		# launching environment; point startup discovery at the first path.
		catch {unset env(GIT_DIR)}
		catch {unset env(GIT_WORK_TREE)}
		catch {cd [lindex $_multi_repo_paths 0]}
	} else {
		set subcommand $a
		set argv [lrange $argv 1 end]
	}
}

# Restore the previous tab session only for an ordinary launch. Explicit repo
# arguments and an inherited Git environment continue to select the startup repo.
set _restore_repo_paths {}
set _restore_active_repo {}
if {$subcommand eq {gui}} {
	_parse_config system_config --system
	_parse_config global_config --global
	set _restore_enabled 0
	set _restore_setting_exists 0
	set _restore_value false
	if {[info exists system_config(gui.restoretabs)]} {
		set _restore_setting_exists 1
		set _restore_value [string tolower $system_config(gui.restoretabs)]
	}
	if {[info exists global_config(gui.restoretabs)]} {
		set _restore_setting_exists 1
		set _restore_value [string tolower $global_config(gui.restoretabs)]
	}
	if {$_restore_setting_exists} {
		set _restore_enabled [expr {$_restore_value eq {} || $_restore_value in {true 1 yes on}}]
	}
	if {$_restore_enabled && [info exists global_config(gui.sessionrepo)]} {
		foreach _session_path $global_config(gui.sessionrepo) {
			if {[catch {set _session_path [file normalize $_session_path]}]
				|| ![file isdirectory $_session_path]
				|| ![file exists [file join $_session_path .git]]
				|| [lsearch -exact $_restore_repo_paths $_session_path] >= 0} continue
			if {[lsearch -exact $_restore_repo_paths $_session_path] < 0} {
				lappend _restore_repo_paths $_session_path
			}
		}
		if {[llength $_restore_repo_paths] > 0} {
			set _restore_active_repo [lindex $_restore_repo_paths 0]
			if {[info exists global_config(gui.sessionactive)]} {
				set _candidate [file normalize $global_config(gui.sessionactive)]
				if {[lsearch -exact $_restore_repo_paths $_candidate] >= 0} {
					set _restore_active_repo $_candidate
				}
			}
			if {![info exists _multi_repo_paths]
				&& ![info exists env(GIT_DIR)]
				&& ![info exists env(GIT_WORK_TREE)]} {
				catch {cd $_restore_active_repo}
			}
		}
	}
}

enable_option multicommit
enable_option branch
enable_option transport
disable_option bare

switch -- $subcommand {
browser -
blame {
	enable_option bare

	disable_option multicommit
	disable_option branch
	disable_option transport
}
citool {
	enable_option singlecommit
	enable_option retcode

	disable_option multicommit
	disable_option branch
	disable_option transport

	while {[llength $argv] > 0} {
		set a [lindex $argv 0]
		switch -- $a {
		--amend {
			enable_option initialamend
		}
		--nocommit {
			enable_option nocommit
			enable_option nocommitmsg
		}
		--commitmsg {
			disable_option nocommitmsg
		}
		default {
			break
		}
		}

		set argv [lrange $argv 1 end]
	}
}
}

######################################################################
##
## execution environment

# Suggest our implementation of askpass, if none is set
set argv0dir [file dirname [file normalize $::argv0]]
if {![info exists env(SSH_ASKPASS)]} {
	set env(SSH_ASKPASS) [file join $argv0dir git-gui--askpass]
}
if {![info exists env(GIT_ASKPASS)]} {
	set env(GIT_ASKPASS) [file join $argv0dir git-gui--askpass]
}
if {![info exists env(GIT_ASK_YESNO)]} {
	set env(GIT_ASK_YESNO) [file join $argv0dir git-gui--askyesno]
}
unset argv0dir

######################################################################
##
## repository setup

set picked 0
if {[catch {
		set _gitdir $env(GIT_DIR)
		set _prefix {}
		}]
	&& [catch {
		# beware that from the .git dir this sets _gitdir to .
		# and _prefix to the empty string
		set _gitdir [git rev-parse --git-dir]
		set _prefix [git rev-parse --show-prefix]
	} err]} {
	load_config 1
	apply_config
	choose_repository::pick
	if {![file isdirectory $_gitdir]} {
		exit 1
	}
	set picked 1
}

# Use object format as hash algorithm (either "sha1" or "sha256")
set hashalgorithm [git rev-parse --show-object-format]
if {$hashalgorithm eq "sha1"} {
	set hashlength 40
} elseif {$hashalgorithm eq "sha256"} {
	set hashlength 64
} else {
	puts stderr "Unknown hash algorithm: $hashalgorithm"
	exit 1
}

# we expand the _gitdir when it's just a single dot (i.e. when we're being
# run from the .git dir itself) lest the routines to find the worktree
# get confused
if {$_gitdir eq "."} {
	set _gitdir [pwd]
}

if {![file isdirectory $_gitdir]} {
	catch {wm withdraw .}
	error_popup [strcat [mc "Git directory not found:"] "\n\n$_gitdir"]
	exit 1
}
# Other tabs change the cwd, so a relative gitdir (e.g. ".git") would resolve
# against the wrong repository.
set _gitdir [file normalize $_gitdir]
# _gitdir exists, so try loading the config
load_config 0
apply_config

set _gitworktree [git rev-parse --show-toplevel]

if {$_prefix ne {}} {
	if {$_gitworktree eq {}} {
		regsub -all {[^/]+/} $_prefix ../ cdup
	} else {
		set cdup $_gitworktree
	}
	if {[catch {cd $cdup} err]} {
		catch {wm withdraw .}
		error_popup [strcat [mc "Cannot move to top of working directory:"] "\n\n$err"]
		exit 1
	}
	set _gitworktree [pwd]
	unset cdup
} elseif {![is_enabled bare]} {
	if {[is_bare]} {
		catch {wm withdraw .}
		error_popup [strcat [mc "Cannot use bare repository:"] "\n\n$_gitdir"]
		exit 1
	}
	if {$_gitworktree eq {}} {
		set _gitworktree [file dirname $_gitdir]
	}
	if {[catch {cd $_gitworktree} err]} {
		catch {wm withdraw .}
		error_popup [strcat [mc "No working directory"] " $_gitworktree:\n\n$err"]
		exit 1
	}
	set _gitworktree [pwd]
}
set _reponame [file split [file normalize $_gitdir]]
if {[lindex $_reponame end] eq {.git}} {
	set _reponame [lindex $_reponame end-1]
} else {
	set _reponame [lindex $_reponame end]
}

# Multi-repo fork spike: promote this repository's identity into a switchable
# per-repo context. The gitdir/reponame accessors now read from it.
repoctx::register $_gitdir $_gitworktree $_reponame \
	[expr {[info exists _prefix] ? $_prefix : {}}]

if {[info exists env(GITGUI_CTX_SELFTEST)]} {
	set _ct_real [repoctx::current]
	set ::current_diff_path "real/path.txt"
	set ::HEAD "realbranch"
	set ::ui_diff "real/ui_diff"
	array set ::file_states {real.txt {_M {}}}
	set _ct_fake [repoctx::open_context /fake/repo/.git /fake/repo demo-repo {}]
	# A fresh context: fake repo's identity, live state (diff/HEAD/file_states/
	# widget paths) all start clean rather than inheriting the real repo's.
	set _ct_ok [expr {[gitdir] eq {/fake/repo/.git} && [reponame] eq {demo-repo} \
		&& $::current_diff_path eq {} && $::HEAD eq {} && $::ui_diff eq {} \
		&& [array size ::file_states] == 0}]
	set ::current_diff_path "fake/other.txt"
	set ::HEAD "fakebranch"
	set ::ui_diff .nb.fake.vpane.diff.t
	array set ::file_states {fake.txt {_M {}}}
	repoctx::use $_ct_real
	# Switching back restores every managed global for the real repo, and the
	# fake repo's file_states entry is gone.
	set _ct_ok [expr {$_ct_ok && [reponame] eq $_reponame && [gitdir] eq $_gitdir \
		&& $::current_diff_path eq {real/path.txt} && $::HEAD eq {realbranch} \
		&& $::ui_diff eq {real/ui_diff} \
		&& [lindex $::file_states(real.txt) 0] eq {_M} \
		&& ![info exists ::file_states(fake.txt)]}]
	repoctx::forget $_ct_fake
	array unset ::file_states
	set ::current_diff_path {}
	set ::HEAD {}
	puts stderr "repoctx self-test: [expr {$_ct_ok ? {PASS} : {FAIL}}]\
		(identity + current_diff_path + HEAD + file_states array + ui_* widget\
		paths isolated across switch)"
	unset -nocomplain _ct_real _ct_fake _ct_ok
}

set env(GIT_DIR) $_gitdir
set env(GIT_WORK_TREE) $_gitworktree

######################################################################
##
## global init

set current_diff_path {}
set current_diff_side {}
set diff_actions [list]

set HEAD {}
set PARENT {}
set MERGE_HEAD [list]
set commit_type {}
set commit_type_is_amend 0
set force_prepare_commit_msg 0
set empty_tree {}
set current_branch {}
set is_detached 0
set current_diff_path {}
set is_3way_diff 0
set is_submodule_diff 0
set is_conflict_diff 0
set last_revert {}
set last_revert_enc {}

set nullid [string repeat 0 $hashlength]
set nullid2 "[string repeat 0 [expr $hashlength - 1]]1"

######################################################################
##
## task management

set rescan_active 0
set rescan_owner {}
set rescan_all_active 0
set rescan_all_ids {}
set rescan_all_index 0
set rescan_all_buttons {}
set rescan_all_owner {}
set diff_active 0
set last_clicked {}

set disable_on_lock [list]
set index_lock_type none

proc lock_index {type} {
	global index_lock_type disable_on_lock

	if {$index_lock_type eq {none}} {
		set index_lock_type $type
		foreach w $disable_on_lock {
			# Skip widgets from closed tabs that no longer exist.
			if {![winfo exists [lindex $w 0]]} continue
			uplevel #0 $w disabled
		}
		return 1
	} elseif {$index_lock_type eq "begin-$type"} {
		set index_lock_type $type
		return 1
	}
	return 0
}

proc unlock_index {} {
	global index_lock_type disable_on_lock rescan_all_active rescan_all_buttons

	set index_lock_type none
	foreach w $disable_on_lock {
		if {![winfo exists [lindex $w 0]]} continue
		set state normal
		if {$rescan_all_active
			&& [lsearch -exact $rescan_all_buttons [lindex $w 0]] >= 0} {
			set state disabled
		}
		uplevel #0 [concat $w $state]
	}
}

######################################################################
##
## status

proc repository_state {ctvar hdvar mhvar} {
	global current_branch
	upvar $ctvar ct $hdvar hd $mhvar mh

	set mh [list]

	load_current_branch
	if {[catch {set hd [git rev-parse --verify HEAD]}]} {
		set hd {}
		set ct initial
		return
	}

	set merge_head [gitdir MERGE_HEAD]
	if {[file exists $merge_head]} {
		set ct merge
		set fd_mh [safe_open_file $merge_head r]
		while {[gets $fd_mh line] >= 0} {
			lappend mh $line
		}
		close $fd_mh
		return
	}

	set ct normal
}

proc PARENT {} {
	global PARENT empty_tree

	set p [lindex $PARENT 0]
	if {$p ne {}} {
		return $p
	}
	if {$empty_tree eq {}} {
		set empty_tree [git_redir [list mktree] [list << {}]]
	}
	return $empty_tree
}

proc force_amend {} {
	global commit_type_is_amend
	global HEAD PARENT MERGE_HEAD commit_type

	repository_state newType newHEAD newMERGE_HEAD
	set HEAD $newHEAD
	set PARENT $newHEAD
	set MERGE_HEAD $newMERGE_HEAD
	set commit_type $newType

	set commit_type_is_amend 1
	do_select_commit_type
}

# Rescan runs asynchronously via fileevent callbacks that write to the live
# globals (file_states, ui_* widgets, HEAD/commit_type). If the user switches
# tabs while a rescan is in flight, those writes must still land on the repo the
# rescan was started for. Wrap each callback so it runs in its origin context and
# restores the active one afterward. If the origin tab was closed mid-rescan the
# callback is dropped (and its pipe closed) rather than corrupting the now-active
# repo. Rescans are serialized (rescan_active), so only one is ever in flight.
# A full context swap copies file_states/repo_config, so for a background repo
# pipe output is buffered without swapping and parsed once at EOF.
proc rescan_dispatch {cmd} {
	global rescan_owner rescan_pending
	set fd [lindex $cmd 1]
	if {$rescan_owner ne {} && [lsearch -exact [repoctx::ids] $rescan_owner] < 0} {
		unset -nocomplain rescan_pending($fd)
		catch {close $fd}
		return
	}
	set prev [repoctx::current]
	set swap [expr {$rescan_owner ne {} && $rescan_owner ne $prev}]
	if {$swap} {
		append rescan_pending($fd) [read $fd]
		if {![eof $fd]} return
		repoctx::use $rescan_owner
	}
	set code [catch {uplevel #0 $cmd} res opts]
	if {$swap} { catch {repoctx::use $prev} }
	return -options $opts $res
}

# Read from a rescan pipe, including any output buffered by rescan_dispatch.
proc rescan_read {fd} {
	global rescan_pending
	set data {}
	if {[info exists rescan_pending($fd)]} {
		set data $rescan_pending($fd)
		unset rescan_pending($fd)
	}
	append data [read $fd]
	return $data
}

proc rescan {after {honor_trustmtime 1}} {
	global HEAD PARENT MERGE_HEAD commit_type
	global ui_index ui_workdir ui_comm
	global rescan_active rescan_owner file_states
	global repo_config
	global force_prepare_commit_msg

	# Self-heal: a rescan whose tab was closed mid-scan may have left the shared
	# lock set; clear it so this rescan can proceed.
	if {$rescan_active > 0 && $rescan_owner ne {}
		&& [lsearch -exact [repoctx::ids] $rescan_owner] < 0} {
		set rescan_active 0
		catch {unlock_index}
	}
	if {$rescan_active > 0 || ![lock_index read]} return
	set rescan_owner [repoctx::current]
	catch {tools_base_invalidate}

	repository_state newType newHEAD newMERGE_HEAD
	if {[string match amend* $commit_type]
		&& $newType eq {normal}
		&& $newHEAD eq $HEAD} {
	} else {
		set HEAD $newHEAD
		set PARENT $newHEAD
		set MERGE_HEAD $newMERGE_HEAD
		set commit_type $newType
	}

	array unset file_states

	if {$force_prepare_commit_msg} {
		# Drop the saved/backed up message so the hook is reached below.
		set force_prepare_commit_msg 0
		set ::GITGUI_BCK_exists 0
		catch {file delete [gitdir GITGUI_BCK]}
		catch {file delete [gitdir GITGUI_MSG]}
	}

	if {!$::GITGUI_BCK_exists &&
		(![$ui_comm edit modified]
		|| [string trim [$ui_comm get 0.0 end]] eq {})} {
		if {[string match amend* $commit_type]} {
		} elseif {[load_message GITGUI_MSG utf-8]} {
		} elseif {[run_prepare_commit_msg_hook]} {
		} elseif {[load_message MERGE_MSG]} {
		} elseif {[load_message SQUASH_MSG]} {
		} elseif {[load_message [get_config commit.template]]} {
		}
		$ui_comm edit reset
		$ui_comm edit modified false
	}

	if {$honor_trustmtime && $repo_config(gui.trustmtime) eq {true}} {
		rescan_stage2 {} $after
	} else {
		set rescan_active 1
		ui_status [mc "Refreshing file status..."]
		set fd_rf [git_read [list update-index \
			-q \
			--unmerged \
			--ignore-missing \
			--refresh \
			]]
		fconfigure $fd_rf -blocking 0 -translation binary
		fileevent $fd_rf readable \
			[list rescan_dispatch [list rescan_stage2 $fd_rf $after]]
	}
}

proc have_info_exclude {} {
	return [file readable [gitdir info exclude]]
}

proc rescan_stage2 {fd after} {
	global rescan_active buf_rdi buf_rdf buf_rlo

	if {$fd ne {}} {
		rescan_read $fd
		if {![eof $fd]} return
		close $fd
	}

	set ls_others [list --exclude-standard]

	set buf_rdi {}
	set buf_rdf {}
	set buf_rlo {}

	set rescan_active 2
	ui_status [mc "Scanning for modified files ..."]
	set fd_di [git_read [list diff-index --cached --ignore-submodules=dirty -z [PARENT]]]
	set fd_df [git_read [list diff-files -z]]

	fconfigure $fd_di -blocking 0 -translation binary
	fconfigure $fd_df -blocking 0 -translation binary

	fileevent $fd_di readable [list rescan_dispatch [list read_diff_index $fd_di $after]]
	fileevent $fd_df readable [list rescan_dispatch [list read_diff_files $fd_df $after]]

	if {[is_config_true gui.displayuntracked]} {
		set fd_lo [git_read [concat ls-files --others -z $ls_others]]
		fconfigure $fd_lo -blocking 0 -translation binary
		fileevent $fd_lo readable [list rescan_dispatch [list read_ls_others $fd_lo $after]]
		incr rescan_active
	}
}

proc load_message {file {encoding {}} {keep_trailing_space 0}} {
	global ui_comm

	set f [gitdir $file]
	if {[file isfile $f]} {
		if {[catch {set fd [safe_open_file $f r]}]} {
			return 0
		}
		if {$encoding ne {}} {
			fconfigure $fd -encoding $encoding
		}
		set content [read $fd]
		close $fd
		set tail {}
		if {$keep_trailing_space} {
			regexp {[ ]*$} [string trimright $content "\r\n"] tail
		}
		set content [string trim $content]
		regsub -all -line {[ \r\t]+$} $content {} content
		if {$content ne {}} {
			append content $tail
		}
		$ui_comm delete 0.0 end
		$ui_comm insert end $content
		return 1
	}
	return 0
}

proc run_prepare_commit_msg_hook {} {
	global pch_error

	# prepare-commit-msg requires PREPARE_COMMIT_MSG exist.  From git-gui
	# it will be .git/MERGE_MSG (merge), .git/SQUASH_MSG (squash), or an
	# empty file but existent file.

	set fd_pcm [safe_open_file [gitdir PREPARE_COMMIT_MSG] a]

	if {[file isfile [gitdir MERGE_MSG]]} {
		set pcm_source "merge"
		set fd_mm [safe_open_file [gitdir MERGE_MSG] r]
		fconfigure $fd_mm -encoding utf-8
		puts -nonewline $fd_pcm [read $fd_mm]
		close $fd_mm
	} elseif {[file isfile [gitdir SQUASH_MSG]]} {
		set pcm_source "squash"
		set fd_sm [safe_open_file [gitdir SQUASH_MSG] r]
		fconfigure $fd_sm -encoding utf-8
		puts -nonewline $fd_pcm [read $fd_sm]
		close $fd_sm
	} elseif {[file isfile [get_config commit.template]]} {
		set pcm_source "template"
		set fd_sm [safe_open_file [get_config commit.template] r]
		fconfigure $fd_sm -encoding utf-8
		puts -nonewline $fd_pcm [read $fd_sm]
		close $fd_sm
	} else {
		set pcm_source ""
	}

	close $fd_pcm

	set fd_ph [githook_read prepare-commit-msg \
			[gitdir PREPARE_COMMIT_MSG] $pcm_source]
	if {$fd_ph eq {}} {
		catch {file delete [gitdir PREPARE_COMMIT_MSG]}
		return 0;
	}

	ui_status [mc "Calling prepare-commit-msg hook..."]
	set pch_error {}

	fconfigure $fd_ph -blocking 0 -translation binary
	fileevent $fd_ph readable [list repoctx_dispatch [repoctx::current] \
		[list prepare_commit_msg_hook_wait $fd_ph]]

	return 1;
}

# Run $cmd in context $id, restoring the active context afterward. If the
# context's tab was closed, close the pipe and run $on_gone instead.
proc repoctx_dispatch {id cmd {on_gone {}}} {
	if {[lsearch -exact [repoctx::ids] $id] < 0} {
		catch {close [lindex $cmd 1]}
		uplevel #0 $on_gone
		return
	}
	set prev [repoctx::current]
	set swap [expr {$id ne $prev}]
	if {$swap} { repoctx::use $id }
	set code [catch {uplevel #0 $cmd} res opts]
	if {$swap} { catch {repoctx::use $prev} }
	return -options $opts $res
}

proc prepare_commit_msg_hook_wait {fd_ph} {
	global pch_error

	append pch_error [read $fd_ph]
	fconfigure $fd_ph -blocking 1
	if {[eof $fd_ph]} {
		if {[catch {close $fd_ph}]} {
			ui_status [mc "Commit declined by prepare-commit-msg hook."]
			hook_failed_popup prepare-commit-msg $pch_error
			catch {file delete [gitdir PREPARE_COMMIT_MSG]}
			exit 1
		} else {
			load_message PREPARE_COMMIT_MSG {} 1
		}
		set pch_error {}
		catch {file delete [gitdir PREPARE_COMMIT_MSG]}
		return
	}
	fconfigure $fd_ph -blocking 0
	catch {file delete [gitdir PREPARE_COMMIT_MSG]}
}

proc read_diff_index {fd after} {
	global buf_rdi

	append buf_rdi [rescan_read $fd]
	set c 0
	set n [string length $buf_rdi]
	while {$c < $n} {
		set z1 [string first "\0" $buf_rdi $c]
		if {$z1 == -1} break
		incr z1
		set z2 [string first "\0" $buf_rdi $z1]
		if {$z2 == -1} break

		incr c
		set i [split [string range $buf_rdi $c [expr {$z1 - 2}]] { }]
		set p [string range $buf_rdi $z1 [expr {$z2 - 1}]]
		merge_state \
			[convertfrom utf-8 $p] \
			[lindex $i 4]? \
			[list [lindex $i 0] [lindex $i 2]] \
			[list]
		set c $z2
		incr c
	}
	if {$c < $n} {
		set buf_rdi [string range $buf_rdi $c end]
	} else {
		set buf_rdi {}
	}

	rescan_done $fd buf_rdi $after
}

proc read_diff_files {fd after} {
	global buf_rdf

	append buf_rdf [rescan_read $fd]
	set c 0
	set n [string length $buf_rdf]
	while {$c < $n} {
		set z1 [string first "\0" $buf_rdf $c]
		if {$z1 == -1} break
		incr z1
		set z2 [string first "\0" $buf_rdf $z1]
		if {$z2 == -1} break

		incr c
		set i [split [string range $buf_rdf $c [expr {$z1 - 2}]] { }]
		set p [string range $buf_rdf $z1 [expr {$z2 - 1}]]
		merge_state \
			[convertfrom utf-8 $p] \
			?[lindex $i 4] \
			[list] \
			[list [lindex $i 0] [lindex $i 2]]
		set c $z2
		incr c
	}
	if {$c < $n} {
		set buf_rdf [string range $buf_rdf $c end]
	} else {
		set buf_rdf {}
	}

	rescan_done $fd buf_rdf $after
}

proc read_ls_others {fd after} {
	global buf_rlo

	append buf_rlo [rescan_read $fd]
	set pck [split $buf_rlo "\0"]
	set buf_rlo [lindex $pck end]
	foreach p [lrange $pck 0 end-1] {
		set p [convertfrom utf-8 $p]
		if {[string index $p end] eq {/}} {
			set p [string range $p 0 end-1]
		}
		merge_state $p ?O
	}
	rescan_done $fd buf_rlo $after
}

proc rescan_done {fd buf after} {
	global rescan_active current_diff_path rescan_all_active rescan_all_owner
	global file_states repo_config
	upvar $buf to_clear

	if {![eof $fd]} return
	set to_clear {}
	close $fd
	if {[incr rescan_active -1] > 0} return

	prune_selection
	unlock_index
	display_all_files
	if {$rescan_all_active && $rescan_all_owner eq [repoctx::current]} {
		set rescan_all_owner {}
		return
	}
	if {$current_diff_path ne {}} { reshow_diff $after }
	if {$current_diff_path eq {}} { select_first_diff $after }
}

proc prune_selection {} {
	global file_states selected_paths

	foreach path [array names selected_paths] {
		if {[catch {set still_here $file_states($path)}]} {
			unset selected_paths($path)
		}
	}
}

######################################################################
##
## ui helpers

proc mapicon {w state path} {
	global all_icons

	# Icons are keyed by list kind; each repo tab has its own list widgets.
	set kind [lindex [split $w .] end-1]
	if {[catch {set r $all_icons($state.$kind)}]} {
		puts "error: no icon for $w state={$state} $path"
		return file_plain
	}
	return $r
}

proc mapdesc {state path} {
	global all_descs

	if {[catch {set r $all_descs($state)}]} {
		puts "error: no desc for state={$state} $path"
		return $state
	}
	return $r
}

proc ui_status {msg} {
	global main_status
	if {[info exists main_status]} {
		$main_status show $msg
	}
}

proc ui_ready {} {
	global main_status
	if {[info exists main_status]} {
		$main_status show [mc "Ready."]
	}
}

proc escape_path {path} {
	regsub -all {\\} $path "\\\\" path
	regsub -all "\n" $path "\\n" path
	return $path
}

proc short_path {path} {
	return [escape_path [lindex [file split $path] end]]
}

set next_icon_id 0

proc merge_state {path new_state {head_info {}} {index_info {}}} {
	global file_states next_icon_id nullid

	set s0 [string index $new_state 0]
	set s1 [string index $new_state 1]

	if {[catch {set info $file_states($path)}]} {
		set state __
		set icon n[incr next_icon_id]
	} else {
		set state [lindex $info 0]
		set icon [lindex $info 1]
		if {$head_info eq {}}  {set head_info  [lindex $info 2]}
		if {$index_info eq {}} {set index_info [lindex $info 3]}
	}

	if     {$s0 eq {?}} {set s0 [string index $state 0]} \
	elseif {$s0 eq {_}} {set s0 _}

	if     {$s1 eq {?}} {set s1 [string index $state 1]} \
	elseif {$s1 eq {_}} {set s1 _}

	if {$s0 eq {A} && $s1 eq {_} && $head_info eq {}} {
		set head_info [list 0 $nullid]
	} elseif {$s0 ne {_} && [string index $state 0] eq {_}
		&& $head_info eq {}} {
		set head_info $index_info
	} elseif {$s0 eq {_} && [string index $state 0] ne {_}} {
		set index_info $head_info
		set head_info {}
	}

	set file_states($path) [list $s0$s1 $icon \
		$head_info $index_info \
		]
	return $state
}

proc display_file_helper {w path icon_name old_m new_m} {
	global file_lists

	if {$new_m eq {_}} {
		set lno [lsearch -sorted -exact $file_lists($w) $path]
		if {$lno >= 0} {
			set file_lists($w) [lreplace $file_lists($w) $lno $lno]
			incr lno
			$w conf -state normal
			$w delete $lno.0 [expr {$lno + 1}].0
			$w conf -state disabled
		}
	} elseif {$old_m eq {_} && $new_m ne {_}} {
		lappend file_lists($w) $path
		set file_lists($w) [lsort -unique $file_lists($w)]
		set lno [lsearch -sorted -exact $file_lists($w) $path]
		incr lno
		$w conf -state normal
		$w image create $lno.0 \
			-align center -padx 5 -pady 1 \
			-name $icon_name \
			-image [mapicon $w $new_m $path]
		$w insert $lno.1 "[escape_path $path]\n"
		$w conf -state disabled
	} elseif {$old_m ne $new_m} {
		$w conf -state normal
		$w image conf $icon_name -image [mapicon $w $new_m $path]
		$w conf -state disabled
	}
}

proc display_file {path state} {
	global file_states selected_paths
	global ui_index ui_workdir

	set old_m [merge_state $path $state]
	set s $file_states($path)
	set new_m [lindex $s 0]
	set icon_name [lindex $s 1]

	set o [string index $old_m 0]
	set n [string index $new_m 0]
	if {$o eq {U}} {
		set o _
	}
	if {$n eq {U}} {
		set n _
	}
	display_file_helper	$ui_index $path $icon_name $o $n

	if {[string index $old_m 0] eq {U}} {
		set o U
	} else {
		set o [string index $old_m 1]
	}
	if {[string index $new_m 0] eq {U}} {
		set n U
	} else {
		set n [string index $new_m 1]
	}
	display_file_helper	$ui_workdir $path $icon_name $o $n

	if {$new_m eq {__}} {
		unset file_states($path)
		catch {unset selected_paths($path)}
	}
	autosize_schedule [winfo parent [winfo parent $ui_index]]
}

proc display_all_files_helper {w path icon_name m} {
	global file_lists

	lappend file_lists($w) $path
	set lno [expr {[lindex [split [$w index end] .] 0] - 1}]
	$w image create end \
		-align center -padx 5 -pady 1 \
		-name $icon_name \
		-image [mapicon $w $m $path]
	$w insert end "[escape_path $path]\n"
}

set files_warning 0
proc display_all_files {} {
	global ui_index ui_workdir
	global file_states file_lists
	global last_clicked
	global files_warning

	$ui_index conf -state normal
	$ui_workdir conf -state normal

	$ui_index delete 0.0 end
	$ui_workdir delete 0.0 end
	set last_clicked {}

	set file_lists($ui_index) [list]
	set file_lists($ui_workdir) [list]

	set to_display [lsort [array names file_states]]
	set display_limit [get_config gui.maxfilesdisplayed]
	set displayed 0
	foreach path $to_display {
		set s $file_states($path)
		set m [lindex $s 0]
		set icon_name [lindex $s 1]

		if {$displayed > $display_limit && [string index $m 1] eq {O} } {
			if {!$files_warning} {
				# do not repeatedly warn:
				set files_warning 1
				info_popup [mc "Display limit (gui.maxfilesdisplayed = %s) reached, not showing all %s files." \
					$display_limit [llength $to_display]]
			}
			continue
		}

		set s [string index $m 0]
		if {$s ne {U} && $s ne {_}} {
			display_all_files_helper $ui_index $path \
				$icon_name $s
		}

		if {[string index $m 0] eq {U}} {
			set s U
		} else {
			set s [string index $m 1]
		}
		if {$s ne {_}} {
			display_all_files_helper $ui_workdir $path \
				$icon_name $s
			incr displayed
		}
	}

	$ui_index conf -state disabled
	$ui_workdir conf -state disabled
	autosize_schedule [winfo parent [winfo parent $ui_index]]
}

# -- File list autosizing
#
# Fits the Unstaged/Staged split to their contents and the file column to the
# longest path, within limits. Dragging a sash pins it for the session;
# double-clicking it returns to automatic sizing.
set autosize_min_rows 3
set autosize_min_share 0.2
set autosize_min_width 300
set autosize_min_width_share 0.2
set autosize_max_width_share 0.4

proc autosize_schedule {pw} {
	global autosize_pending
	if {[info exists autosize_pending($pw)]} return
	set autosize_pending($pw) [after idle [list autosize_file_lists $pw]]
}

proc autosize_file_lists {pw} {
	global autosize_pending autosize_pinned
	unset -nocomplain autosize_pending($pw)
	if {![winfo exists $pw] || ![winfo viewable $pw]} return
	if {![is_config_true gui.autosizefilelists]} return
	if {![info exists autosize_pinned($pw)]} {
		autosize_split $pw
	}
	set hp [winfo parent $pw]
	if {![info exists autosize_pinned($hp)]} {
		autosize_column $hp $pw
	}
}

proc autosize_split {pw} {
	global autosize_min_rows autosize_min_share
	set top $pw.workdir
	set bot $pw.index
	set avail [expr {[winfo height $top] + [winfo height $bot]}]
	if {$avail < 20} return
	foreach f [list $top $bot] {
		set t $f.list
		set rows [expr {int([$t index end-1c]) - 1}]
		set px [$t count -update -ypixels 1.0 end-1c]
		if {$rows > 0} {
			set lh [expr {double($px) / $rows}]
		} else {
			set lh [font metrics [$t cget -font] -linespace]
		}
		set chrome [expr {[winfo height $f] - [winfo height $t]}]
		set want($f) [expr {$chrome + $px + 4}]
		set min($f) [expr {$chrome + $autosize_min_rows * $lh}]
	}
	set lo [expr {max($min($top), $avail * $autosize_min_share)}]
	set hi [expr {min($avail - $min($bot), $avail * (1 - $autosize_min_share))}]
	set h [expr {double($avail) * $want($top) / ($want($top) + $want($bot))}]
	set h [expr {int(max($lo, min($hi, $h)))}]
	if {abs($h - [$pw sashpos 0]) > 8} {
		$pw sashpos 0 $h
	}
}

proc autosize_column {hp pw} {
	global autosize_min_width autosize_min_width_share autosize_max_width_share
	set total [winfo width $hp]
	if {$total < 50} return
	set want 0
	set chrome 0
	foreach t [list $pw.workdir.list $pw.index.list] {
		set f [$t cget -font]
		set icon 0
		catch {set icon [expr {[image width [$t image cget 1.0 -image]] + 10}]}
		foreach line [split [$t get 1.0 end-1c] \n] {
			set want [expr {max($want, $icon + [font measure $f $line])}]
		}
		set chrome [expr {max($chrome,
			[winfo width [winfo parent $t]] - [winfo width $t])}]
	}
	set w [expr {$want + $chrome + 8}]
	set hi [expr {int($total * $autosize_max_width_share)}]
	set lo [expr {min($hi, max($autosize_min_width,
		int($total * $autosize_min_width_share)))}]
	set w [expr {max($lo, min($hi, $w))}]
	if {abs($w - [$hp sashpos 0]) > 8} {
		$hp sashpos 0 $w
	}
}

proc autosize_press {w} {
	set ::autosize_press($w) [$w sashpos 0]
}
proc autosize_release {w} {
	if {[info exists ::autosize_press($w)]
	    && [$w sashpos 0] != $::autosize_press($w)} {
		set ::autosize_pinned($w) 1
	}
	unset -nocomplain ::autosize_press($w)
}
proc autosize_unpin {w pw} {
	unset -nocomplain ::autosize_pinned($w)
	autosize_schedule $pw
}

######################################################################
##
## icons

set filemask {
#define mask_width 14
#define mask_height 15
static unsigned char mask_bits[] = {
	0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f,
	0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f,
	0xfe, 0x1f, 0xfe, 0x1f, 0xfe, 0x1f};
}

image create bitmap file_plain -background white -foreground black -data {
#define plain_width 14
#define plain_height 15
static unsigned char plain_bits[] = {
	0xfe, 0x01, 0x02, 0x03, 0x02, 0x05, 0x02, 0x09, 0x02, 0x1f, 0x02, 0x10,
	0x02, 0x10, 0x02, 0x10, 0x02, 0x10, 0x02, 0x10, 0x02, 0x10, 0x02, 0x10,
	0x02, 0x10, 0x02, 0x10, 0xfe, 0x1f};
} -maskdata $filemask

image create bitmap file_mod -background white -foreground blue -data {
#define mod_width 14
#define mod_height 15
static unsigned char mod_bits[] = {
	0xfe, 0x01, 0x02, 0x03, 0x7a, 0x05, 0x02, 0x09, 0x7a, 0x1f, 0x02, 0x10,
	0xfa, 0x17, 0x02, 0x10, 0xfa, 0x17, 0x02, 0x10, 0xfa, 0x17, 0x02, 0x10,
	0xfa, 0x17, 0x02, 0x10, 0xfe, 0x1f};
} -maskdata $filemask

image create bitmap file_fulltick -background white -foreground "#007000" -data {
#define file_fulltick_width 14
#define file_fulltick_height 15
static unsigned char file_fulltick_bits[] = {
	0xfe, 0x01, 0x02, 0x1a, 0x02, 0x0c, 0x02, 0x0c, 0x02, 0x16, 0x02, 0x16,
	0x02, 0x13, 0x00, 0x13, 0x86, 0x11, 0x8c, 0x11, 0xd8, 0x10, 0xf2, 0x10,
	0x62, 0x10, 0x02, 0x10, 0xfe, 0x1f};
} -maskdata $filemask

image create bitmap file_question -background white -foreground black -data {
#define file_question_width 14
#define file_question_height 15
static unsigned char file_question_bits[] = {
	0xfe, 0x01, 0x02, 0x02, 0xe2, 0x04, 0xf2, 0x09, 0x1a, 0x1b, 0x0a, 0x13,
	0x82, 0x11, 0xc2, 0x10, 0x62, 0x10, 0x62, 0x10, 0x02, 0x10, 0x62, 0x10,
	0x62, 0x10, 0x02, 0x10, 0xfe, 0x1f};
} -maskdata $filemask

image create bitmap file_removed -background white -foreground red -data {
#define file_removed_width 14
#define file_removed_height 15
static unsigned char file_removed_bits[] = {
	0xfe, 0x01, 0x02, 0x03, 0x02, 0x05, 0x02, 0x09, 0x02, 0x1f, 0x02, 0x10,
	0x1a, 0x16, 0x32, 0x13, 0xe2, 0x11, 0xc2, 0x10, 0xe2, 0x11, 0x32, 0x13,
	0x1a, 0x16, 0x02, 0x10, 0xfe, 0x1f};
} -maskdata $filemask

image create bitmap file_merge -background white -foreground blue -data {
#define file_merge_width 14
#define file_merge_height 15
static unsigned char file_merge_bits[] = {
	0xfe, 0x01, 0x02, 0x03, 0x62, 0x05, 0x62, 0x09, 0x62, 0x1f, 0x62, 0x10,
	0xfa, 0x11, 0xf2, 0x10, 0x62, 0x10, 0x02, 0x10, 0xfa, 0x17, 0x02, 0x10,
	0xfa, 0x17, 0x02, 0x10, 0xfe, 0x1f};
} -maskdata $filemask

image create bitmap file_statechange -background white -foreground green -data {
#define file_statechange_width 14
#define file_statechange_height 15
static unsigned char file_statechange_bits[] = {
	0xfe, 0x01, 0x02, 0x03, 0x02, 0x05, 0x02, 0x09, 0x02, 0x1f, 0x62, 0x10,
	0x62, 0x10, 0xba, 0x11, 0xba, 0x11, 0x62, 0x10, 0x62, 0x10, 0x02, 0x10,
	0x02, 0x10, 0x02, 0x10, 0xfe, 0x1f};
} -maskdata $filemask

set ui_index .vpane.files.index.list
set ui_workdir .vpane.files.workdir.list

set all_icons(_.index)   file_plain
set all_icons(A.index)   file_plain
set all_icons(M.index)   file_fulltick
set all_icons(D.index)   file_removed
set all_icons(U.index)   file_merge
set all_icons(T.index)   file_statechange

set all_icons(_.workdir) file_plain
set all_icons(M.workdir) file_mod
set all_icons(D.workdir) file_question
set all_icons(U.workdir) file_merge
set all_icons(O.workdir) file_plain
set all_icons(T.workdir) file_statechange

set max_status_desc 0
foreach i {
		{__ {mc "Unmodified"}}

		{_M {mc "Modified, not staged"}}
		{M_ {mc "Staged for commit"}}
		{MM {mc "Portions staged for commit"}}
		{MD {mc "Staged for commit, missing"}}

		{_T {mc "File type changed, not staged"}}
		{MT {mc "File type changed, old type staged for commit"}}
		{AT {mc "File type changed, old type staged for commit"}}
		{T_ {mc "File type changed, staged"}}
		{TM {mc "File type change staged, modification not staged"}}
		{TD {mc "File type change staged, file missing"}}

		{_O {mc "Untracked, not staged"}}
		{A_ {mc "Staged for commit"}}
		{AM {mc "Portions staged for commit"}}
		{AD {mc "Staged for commit, missing"}}

		{_D {mc "Missing"}}
		{D_ {mc "Staged for removal"}}
		{DO {mc "Staged for removal, still present"}}

		{_U {mc "Requires merge resolution"}}
		{U_ {mc "Requires merge resolution"}}
		{UU {mc "Requires merge resolution"}}
		{UM {mc "Requires merge resolution"}}
		{UD {mc "Requires merge resolution"}}
		{UT {mc "Requires merge resolution"}}
	} {
	set text [eval [lindex $i 1]]
	if {$max_status_desc < [string length $text]} {
		set max_status_desc [string length $text]
	}
	set all_descs([lindex $i 0]) $text
}
unset i

######################################################################
##
## util

proc scrollbar2many {list mode args} {
	foreach w $list {eval $w $mode $args}
}

proc many2scrollbar {list mode sb top bottom} {
	$sb set $top $bottom
	foreach w $list {$w $mode moveto $top}
}

proc incr_font_size {font {amt 1}} {
	set sz [font configure $font -size]
	incr sz $amt
	font configure $font -size $sz
	font configure ${font}bold -size $sz
	font configure ${font}italic -size $sz
}

######################################################################
##
## ui commands

proc do_gitk {revs {is_submodule false}} {
	global current_diff_path file_states current_diff_side ui_index
	global _gitdir _gitworktree

	# -- Always start gitk through whatever we were loaded with.  This
	#    lets us bypass using shell process on Windows systems.
	#
	set exe [_which gitk -script]
	set cmd [list [info nameofexecutable] $exe]
	if {$exe eq {}} {
		error_popup [mc "Couldn't find gitk in PATH"]
	} else {
		global env

		set pwd [pwd]

		if {!$is_submodule} {
			if {![is_bare]} {
				cd $_gitworktree
			}
		} else {
			cd $current_diff_path
			if {$revs eq {--}} {
				set s $file_states($current_diff_path)
				set old_sha1 {}
				set new_sha1 {}
				switch -glob -- [lindex $s 0] {
				M_ { set old_sha1 [lindex [lindex $s 2] 1] }
				_M { set old_sha1 [lindex [lindex $s 3] 1] }
				MM {
					if {$current_diff_side eq $ui_index} {
						set old_sha1 [lindex [lindex $s 2] 1]
						set new_sha1 [lindex [lindex $s 3] 1]
					} else {
						set old_sha1 [lindex [lindex $s 3] 1]
					}
				}
				}
				set revs $old_sha1...$new_sha1
			}
			# GIT_DIR and GIT_WORK_TREE for the submodule are not the ones
			# we've been using for the main repository, so unset them.
			# TODO we could make life easier (start up faster?) for gitk
			# by setting these to the appropriate values to allow gitk
			# to skip the heuristics to find their proper value
			unset env(GIT_DIR)
			unset env(GIT_WORK_TREE)
		}
		safe_exec_bg [concat $cmd $revs "--" "--"]

		set env(GIT_DIR) $_gitdir
		set env(GIT_WORK_TREE) $_gitworktree
		cd $pwd

		if {[info exists main_status]} {
			set status_operation [$::main_status \
				start \
				[mc "Starting %s... please wait..." "gitk"]]

			after 3500 [list $status_operation stop]
		}
	}
}

proc do_git_gui {} {
	global current_diff_path

	# -- Always start git gui through whatever we were loaded with.  This
	#    lets us bypass using shell process on Windows systems.
	#
	set exe [list [_which git]]
	if {$exe eq {}} {
		error_popup [mc "Couldn't find git gui in PATH"]
	} else {
		global env
		global _gitdir _gitworktree

		# see note in do_gitk about unsetting these vars when
		# running tools in a submodule
		unset env(GIT_DIR)
		unset env(GIT_WORK_TREE)

		set pwd [pwd]
		cd $current_diff_path

		safe_exec_bg [concat $exe gui]

		set env(GIT_DIR) $_gitdir
		set env(GIT_WORK_TREE) $_gitworktree
		cd $pwd

		set status_operation [$::main_status \
			start \
			[mc "Starting %s... please wait..." "git-gui"]]

		after 3500 [list $status_operation stop]
	}
}

# Get the system-specific explorer app/command.
proc get_explorer {} {
	if {[is_Cygwin]} {
		set explorer "/bin/cygstart.exe --explore"
	} elseif {[is_Windows]} {
		set explorer "explorer.exe"
	} elseif {[is_MacOSX]} {
		set explorer "open"
	} else {
		# freedesktop.org-conforming system is our best shot
		set explorer "xdg-open"
	}
	return $explorer
}

proc do_explore {} {
	global _gitworktree
	set cmd [get_explorer]
	lappend cmd [file nativename $_gitworktree]
	safe_exec_bg $cmd
}

# Open file relative to the working tree by the default associated app.
proc do_file_open {file} {
	global _gitworktree
	set cmd [get_explorer]
	set full_file_path [file join $_gitworktree $file]
	lappend cmd [file nativename $full_file_path]
	safe_exec_bg $cmd
}

# Split a gui.browser value into an exec command list.  Accepts a bare program
# path (which may contain spaces), an optionally quoted path followed by
# arguments, or a plain "program arg arg" string.  Backslashes are preserved.
proc parse_browser_command {spec} {
	set spec [string trim $spec]
	if {$spec eq {}} {
		return {}
	}

	set quote [string index $spec 0]
	if {$quote eq {"} || $quote eq {'}} {
		set close [string first $quote $spec 1]
		if {$close > 0} {
			set prog [string range $spec 1 [expr {$close - 1}]]
			set rest [string trim [string range $spec [expr {$close + 1}] end]]
			set cmd [list $prog]
			if {$rest ne {}} {
				foreach arg [regexp -all -inline {\S+} $rest] {
					lappend cmd $arg
				}
			}
			return $cmd
		}
	}

	if {[file executable $spec]} {
		return [list $spec]
	}

	set cmd {}
	foreach arg [regexp -all -inline {\S+} $spec] {
		lappend cmd $arg
	}
	return $cmd
}

# Open an URL with gui.browser, or the default associated app when unset.
proc do_url_open {url} {
	set cmd [parse_browser_command [get_config gui.browser]]
	if {$cmd eq {}} {
		if {[is_Cygwin]} {
			set cmd [list /bin/cygstart.exe]
		} else {
			set cmd [get_explorer]
		}
	} else {
		set prog [lindex $cmd 0]
		if {[regexp {[/\\]} $prog] && ![file executable $prog]} {
			error_popup [strcat \
				[mc "The configured web browser cannot be run:"] \
				"\n\n$prog\n\n" \
				[mc "Check the gui.browser setting in Edit > Options."]]
			return
		}
	}
	lappend cmd $url
	if {[catch {safe_exec_bg $cmd} err]} {
		error_popup [strcat [mc "Failed to open the web browser:"] "\n\n$err"]
	}
}

proc url_encode {str} {
	set out {}
	foreach ch [split $str {}] {
		if {[string match {[A-Za-z0-9._~-]} $ch]} {
			append out $ch
		} else {
			foreach byte [split [encoding convertto utf-8 $ch] {}] {
				append out [format %%%02X [scan $byte %c]]
			}
		}
	}
	return $out
}

# Translate an Azure DevOps remote URL into the base web URL of the
# repository.  Returns {} when the remote is not an Azure DevOps one.
proc ado_repo_web_url {remote_url} {
	set u [string trimright $remote_url /]
	regsub {\.git$} $u {} u

	# git@ssh.dev.azure.com:v3/<org>/<project>/<repo>
	# ssh://git@ssh.dev.azure.com:22/v3/<org>/<project>/<repo>
	if {[regexp -nocase \
		{ssh\.dev\.azure\.com(?::[0-9]+)?[:/]v3/([^/]+)/([^/]+)/([^/]+)$} \
		$u _ org project repo]} {
		return "https://dev.azure.com/$org/$project/_git/$repo"
	}

	# https://<org>@dev.azure.com/<org>/<project>/_git/<repo>
	if {[regexp -nocase \
		{dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)$} \
		$u _ org project repo]} {
		return "https://dev.azure.com/$org/$project/_git/$repo"
	}

	# https://<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>
	if {[regexp -nocase \
		{^[a-z+]+://(?:[^@/]+@)?([^./]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git/([^/]+)$} \
		$u _ org project repo]} {
		return "https://dev.azure.com/$org/$project/_git/$repo"
	}

	return {}
}

# Build the Azure DevOps web URL showing $path at the checked out revision.
proc ado_file_url {path} {
	global repo_config current_branch is_detached

	set remote {}
	if {[info exists repo_config(remote.origin.url)]} {
		set remote $repo_config(remote.origin.url)
	} else {
		foreach k [lsort [array names repo_config remote.*.url]] {
			set remote $repo_config($k)
			break
		}
	}
	if {$remote eq {}} {
		return {}
	}

	set base [ado_repo_web_url $remote]
	if {$base eq {}} {
		return {}
	}

	if {$is_detached} {
		if {[catch {set version GC[git rev-parse HEAD]}]} {
			return {}
		}
	} else {
		set version GB$current_branch
	}

	return "$base?path=[url_encode /$path]&version=[url_encode $version]&_a=contents"
}

proc do_ado_open {path} {
	if {$path eq {}} return
	set url [ado_file_url $path]
	if {$url eq {}} {
		error_popup [mc "This repository has no Azure DevOps remote."]
		return
	}
	do_url_open $url
}

proc do_ado_copy {path} {
	if {$path eq {}} return
	set url [ado_file_url $path]
	if {$url eq {}} {
		error_popup [mc "This repository has no Azure DevOps remote."]
		return
	}
	clipboard clear
	clipboard append -format STRING -type STRING -- $url
}

set is_quitting 0
set ret_code    1

proc terminate_me {win} {
	global ret_code
	if {$win ne {.}} return
	exit $ret_code
}

proc do_quit {{rc {1}}} {
	global ui_comm is_quitting repo_config commit_type
	global GITGUI_BCK_exists GITGUI_BCK_i
	global ui_comm_spell
	global ret_code

	if {$is_quitting} return
	set is_quitting 1
	if {[winfo exists .repotabs]} { catch {save_repo_tab_session} }

	if {[winfo exists $ui_comm]} {
		# -- Stash our current commit buffer.
		#
		set save [gitdir GITGUI_MSG]
		if {$GITGUI_BCK_exists && ![$ui_comm edit modified]} {
			catch { file rename -force [gitdir GITGUI_BCK] $save }
			set GITGUI_BCK_exists 0
		} elseif {[$ui_comm edit modified]} {
			set msg [string trim [$ui_comm get 0.0 end]]
			regsub -all -line {[ \r\t]+$} $msg {} msg
			if {![string match amend* $commit_type]
				&& $msg ne {}} {
				catch {
					set fd [safe_open_file $save w]
					fconfigure $fd -encoding utf-8
					puts -nonewline $fd $msg
					close $fd
				}
			} else {
				catch {file delete $save}
			}
		}

		# -- Cancel our spellchecker if its running.
		#
		if {[info exists ui_comm_spell]} {
			$ui_comm_spell stop
		}

		# -- Remove our editor backup, its not needed.
		#
		after cancel $GITGUI_BCK_i
		if {$GITGUI_BCK_exists} {
			catch {file delete [gitdir GITGUI_BCK]}
		}

		# -- Stash our current window geometry into this repository.
		#
		set cfg_wmstate [wm state .]
		if {[catch {set rc_wmstate $repo_config(gui.wmstate)}]} {
			set rc_wmstate {}
		}
		if {$cfg_wmstate ne $rc_wmstate} {
			catch {git config gui.wmstate $cfg_wmstate}
		}
		if {$cfg_wmstate eq {zoomed}} {
			# on Windows wm geometry will lie about window
			# position (but not size) when window is zoomed
			# restore the window before querying wm geometry
			wm state . normal
		}
		set cfg_geometry [list]
		lappend cfg_geometry [wm geometry .]
		lappend cfg_geometry [$::ui_vpane sashpos 0]
		lappend cfg_geometry [$::ui_vpane_files sashpos 0]
		if {[catch {set rc_geometry $repo_config(gui.geometry)}]} {
			set rc_geometry {}
		}
		if {$cfg_geometry ne $rc_geometry} {
			catch {git config gui.geometry $cfg_geometry}
		}
	}

	set ret_code $rc

	# Briefly enable send again, working around Tk bug
	# https://sourceforge.net/p/tktoolkit/bugs/2343/
	tk appname [appname]

	destroy .
}

proc do_rescan {} {
	rescan ui_ready
}

proc ui_do_rescan {} {
	rescan {force_first_diff ui_ready}
}

proc do_rescan_all {} {
	global rescan_all_active rescan_all_ids rescan_all_index rescan_all_buttons
	global repo_tab_pending repo_tab_load_queue repo_tab_load_timer
	if {$rescan_all_active} return
	set rescan_all_active 1
	if {$repo_tab_load_timer ne {}} { after cancel $repo_tab_load_timer }
	set repo_tab_load_timer {}
	set repo_tab_load_queue {}
	foreach w $rescan_all_buttons {
		if {[winfo exists $w]} { $w configure -state disabled }
	}
	set previous [repoctx::current]
	foreach tab [.repotabs tabs] {
		if {[info exists repo_tab_pending($tab)]} { repo_tab_initialize $tab 0 }
	}
	if {$previous ne {} && [lsearch -exact [repoctx::ids] $previous] >= 0} {
		repoctx::use $previous
		catch {cd [repoctx::field worktree]}
	}
	set rescan_all_ids [repoctx::ids]
	set rescan_all_index 0
	rescan_all_next
}

proc rescan_all_next {} {
	global rescan_active rescan_owner index_lock_type
	global rescan_all_active rescan_all_ids rescan_all_index rescan_all_buttons
	global current_diff_path rescan_all_owner
	if {!$rescan_all_active} return

	# A closed tab drops its pending fileevent callbacks, so release its stale lock.
	if {$rescan_active > 0 && $rescan_owner ne {}
		&& [lsearch -exact [repoctx::ids] $rescan_owner] < 0} {
		set rescan_active 0
		set rescan_owner {}
		catch {unlock_index}
	}
	if {$rescan_active > 0 || $index_lock_type ne {none}} {
		after 100 rescan_all_next
		return
	}

	while {$rescan_all_index < [llength $rescan_all_ids]} {
		set id [lindex $rescan_all_ids $rescan_all_index]
		incr rescan_all_index
		if {[lsearch -exact [repoctx::ids] $id] < 0} continue

		set previous [repoctx::current]
		set rescan_all_owner $id
		repoctx::use $id
		rescan {}
		if {$previous ne {} && [lsearch -exact [repoctx::ids] $previous] >= 0} {
			repoctx::use $previous
		}
		after 100 rescan_all_next
		return
	}

	set rescan_all_active 0
	foreach w $rescan_all_buttons {
		if {[winfo exists $w]} { $w configure -state normal }
	}
	if {$current_diff_path ne {}} {
		reshow_diff ui_ready
	} else {
		select_first_diff ui_ready
	}
}

proc do_commit {} {
	commit_tree
}

proc next_diff {{after {}}} {
	global next_diff_p next_diff_w next_diff_i
	show_diff $next_diff_p $next_diff_w {} {} $after
}

proc find_anchor_pos {lst name} {
	set lid [lsearch -sorted -exact $lst $name]

	if {$lid == -1} {
		set lid 0
		foreach lname $lst {
			if {$lname >= $name} break
			incr lid
		}
	}

	return $lid
}

proc find_file_from {flist idx delta path mmask} {
	global file_states

	set len [llength $flist]
	while {$idx >= 0 && $idx < $len} {
		set name [lindex $flist $idx]

		if {$name ne $path && [info exists file_states($name)]} {
			set state [lindex $file_states($name) 0]

			if {$mmask eq {} || [regexp $mmask $state]} {
				return $idx
			}
		}

		incr idx $delta
	}

	return {}
}

proc find_next_diff {w path {lno {}} {mmask {}}} {
	global next_diff_p next_diff_w next_diff_i
	global file_lists ui_index ui_workdir

	set flist $file_lists($w)
	if {$lno eq {}} {
		set lno [find_anchor_pos $flist $path]
	} else {
		incr lno -1
	}

	if {$mmask ne {} && ![regexp {(^\^)|(\$$)} $mmask]} {
		if {$w eq $ui_index} {
			set mmask "^$mmask"
		} else {
			set mmask "$mmask\$"
		}
	}

	set idx [find_file_from $flist $lno 1 $path $mmask]
	if {$idx eq {}} {
		incr lno -1
		set idx [find_file_from $flist $lno -1 $path $mmask]
	}

	if {$idx ne {}} {
		set next_diff_w $w
		set next_diff_p [lindex $flist $idx]
		set next_diff_i [expr {$idx+1}]
		return 1
	} else {
		return 0
	}
}

proc next_diff_after_action {w path {lno {}} {mmask {}}} {
	global current_diff_path

	if {$path ne $current_diff_path} {
		return {}
	} elseif {[find_next_diff $w $path $lno $mmask]} {
		return {next_diff;}
	} else {
		return {reshow_diff;}
	}
}

proc select_first_diff {after} {
	global ui_workdir

	if {[find_next_diff $ui_workdir {} 1 {^_?U}] ||
	    [find_next_diff $ui_workdir {} 1 {[^O]$}]} {
		next_diff $after
	} else {
		uplevel #0 $after
	}
}

proc force_first_diff {after} {
	global ui_workdir current_diff_path file_states

	if {[info exists file_states($current_diff_path)]} {
		set state [lindex $file_states($current_diff_path) 0]
	} else {
		set state {OO}
	}

	set reselect 0
	if {[string first {U} $state] >= 0} {
		# Already a conflict, do nothing
	} elseif {[find_next_diff $ui_workdir $current_diff_path {} {^_?U}]} {
		set reselect 1
	} elseif {[string index $state 1] ne {O}} {
		# Already a diff & no conflicts, do nothing
	} elseif {[find_next_diff $ui_workdir $current_diff_path {} {[^O]$}]} {
		set reselect 1
	}

	if {$reselect} {
		next_diff $after
	} else {
		uplevel #0 $after
	}
}

proc toggle_or_diff {mode w args} {
	global file_states file_lists current_diff_path ui_index ui_workdir
	global last_clicked selected_paths file_lists_last_clicked

	if {$mode eq "click"} {
		foreach {x y} $args break
		set pos [split [$w index @$x,$y] .]
		foreach {lno col} $pos break
	} else {
		if {$mode eq "toggle"} {
			if {$w eq $ui_workdir} {
				do_add_selection
				set last_clicked {}
				return
			}
			if {$w eq $ui_index} {
				do_unstage_selection
				set last_clicked {}
				return
			}
		}

		if {$last_clicked ne {}} {
			set lno [lindex $last_clicked 1]
		} else {
			if {![info exists file_lists]
				|| ![info exists file_lists($w)]
				|| [llength $file_lists($w)] == 0} {
				set last_clicked {}
				return
			}
			set lno [expr {int([lindex [$w tag ranges in_diff] 0])}]
		}
		if {$mode eq "toggle"} {
			set col 0; set y 2
		} else {
			incr lno [expr {$mode eq "up" ? -1 : 1}]
			set col 1
		}
	}

	if {![info exists file_lists]
		|| ![info exists file_lists($w)]
		|| [llength $file_lists($w)] < $lno - 1} {
		set path {}
	} else {
		set path [lindex $file_lists($w) [expr {$lno - 1}]]
	}
	if {$path eq {}} {
		set last_clicked {}
		return
	}

	set last_clicked [list $w $lno]
	focus $w
	array unset selected_paths
	$ui_index tag remove in_sel 0.0 end
	$ui_workdir tag remove in_sel 0.0 end

	set file_lists_last_clicked($w) $path

	# Determine the state of the file
	if {[info exists file_states($path)]} {
		set state [lindex $file_states($path) 0]
	} else {
		set state {__}
	}

	# Restage the file, or simply show the diff
	if {$col == 0 && $y > 1} {
		# Conflicts need special handling
		if {[string first {U} $state] >= 0} {
			# $w must always be $ui_workdir, but...
			if {$w ne $ui_workdir} { set lno {} }
			merge_stage_workdir $path $lno
			return
		}

		if {[string index $state 1] eq {O}} {
			set mmask {}
		} else {
			set mmask {[^O]}
		}

		set after [next_diff_after_action $w $path $lno $mmask]

		if {$w eq $ui_index} {
			update_indexinfo \
				"Unstaging [short_path $path] from commit" \
				[list $path] \
				[concat $after {ui_ready;}]
		} elseif {$w eq $ui_workdir} {
			update_index \
				"Adding [short_path $path]" \
				[list $path] \
				[concat $after {ui_ready;}]
		}
	} else {
		set selected_paths($path) 1
		show_diff $path $w $lno
	}
}

proc add_one_to_selection {w x y} {
	global file_lists last_clicked selected_paths

	set lno [lindex [split [$w index @$x,$y] .] 0]
	set path [lindex $file_lists($w) [expr {$lno - 1}]]
	if {$path eq {}} {
		set last_clicked {}
		return
	}

	if {$last_clicked ne {}
		&& [lindex $last_clicked 0] ne $w} {
		array unset selected_paths
		[lindex $last_clicked 0] tag remove in_sel 0.0 end
	}

	set last_clicked [list $w $lno]
	if {[catch {set in_sel $selected_paths($path)}]} {
		set in_sel 0
	}
	if {$in_sel} {
		unset selected_paths($path)
		$w tag remove in_sel $lno.0 [expr {$lno + 1}].0
	} else {
		set selected_paths($path) 1
		$w tag add in_sel $lno.0 [expr {$lno + 1}].0
	}
}

proc add_range_to_selection {w x y} {
	global file_lists last_clicked selected_paths

	if {[lindex $last_clicked 0] ne $w} {
		toggle_or_diff click $w $x $y
		return
	}

	set lno [lindex [split [$w index @$x,$y] .] 0]
	set lc [lindex $last_clicked 1]
	if {$lc < $lno} {
		set begin $lc
		set end $lno
	} else {
		set begin $lno
		set end $lc
	}

	foreach path [lrange $file_lists($w) \
		[expr {$begin - 1}] \
		[expr {$end - 1}]] {
		set selected_paths($path) 1
	}
	$w tag add in_sel $begin.0 [expr {$end + 1}].0
}

proc show_more_context {} {
	global repo_config
	if {$repo_config(gui.diffcontext) < 99} {
		incr repo_config(gui.diffcontext)
		reshow_diff
	}
}

proc show_less_context {} {
	global repo_config
	if {$repo_config(gui.diffcontext) > 1} {
		incr repo_config(gui.diffcontext) -1
		reshow_diff
	}
}

proc focus_widget {widget} {
	global file_lists last_clicked selected_paths
	global file_lists_last_clicked

	if {[llength $file_lists($widget)] > 0} {
		set path $file_lists_last_clicked($widget)
		set index [lsearch -sorted -exact $file_lists($widget) $path]
		if {$index < 0} {
			set index 0
			set path [lindex $file_lists($widget) $index]
		}

		focus $widget
		set last_clicked [list $widget [expr $index + 1]]
		array unset selected_paths
		set selected_paths($path) 1
		show_diff $path $widget
	}
}

proc toggle_commit_type {} {
	global commit_type_is_amend
	set commit_type_is_amend [expr !$commit_type_is_amend]
	do_select_commit_type
}

######################################################################
##
## ui construction

set ui_comm {}

# -- Menu Bar
#
menu .mbar -tearoff 0
if {[is_MacOSX]} {
	# -- Apple Menu (Mac OS X only)
	#
	.mbar add cascade -label Apple -menu .mbar.apple
	menu .mbar.apple
}
.mbar add cascade -label [mc Repository] -menu .mbar.repository
.mbar add cascade -label [mc Edit] -menu .mbar.edit
if {[is_enabled branch]} {
	.mbar add cascade -label [mc Branch] -menu .mbar.branch
}
if {[is_enabled multicommit] || [is_enabled singlecommit]} {
	.mbar add cascade -label [mc Commit@@noun] -menu .mbar.commit
}
if {[is_enabled transport]} {
	.mbar add cascade -label [mc Merge] -menu .mbar.merge
	.mbar add cascade -label [mc Remote] -menu .mbar.remote
}
if {[is_enabled multicommit] || [is_enabled singlecommit]} {
	.mbar add cascade -label [mc Tools] -menu .mbar.tools
}

# -- Repository Menu
#
menu .mbar.repository

.mbar.repository add command \
	-label [mc "Open Repository In New Tab..."] \
	-command do_open_repo_tab
menu .mbar.repository.recent -postcommand populate_recent_tab_menu
.mbar.repository add cascade \
	-label [mc "Open Recent In New Tab"] \
	-menu .mbar.repository.recent
.mbar.repository add command \
	-label [mc "Close Tab"] \
	-command close_repo_tab
.mbar.repository add separator

if {![is_bare]} {
	.mbar.repository add command \
		-label [mc "Explore Working Copy"] \
		-command {do_explore}
}

if {[is_Windows]} {
	# Use /git-bash.exe if available
	set _git_bash [safe_exec [list cygpath -m /git-bash.exe]]
	if {[file executable $_git_bash]} {
		set _bash_cmdline [list "Git Bash" $_git_bash]
	} else {
		set _bash_cmdline [list "Git Bash" bash --login -l]
	}
	.mbar.repository add command \
		-label [mc "Git Bash"] \
		-command {safe_exec_bg [concat [list [_which cmd] /c start] $_bash_cmdline]}
	unset _git_bash
}

if {[is_Windows] || ![is_bare]} {
	.mbar.repository add separator
}

.mbar.repository add command \
	-label [mc "Browse Current Branch's Files"] \
	-command {browser::new $current_branch}
set ui_browse_current [.mbar.repository index last]
.mbar.repository add command \
	-label [mc "Browse Branch Files..."] \
	-command browser_open::dialog
.mbar.repository add separator

.mbar.repository add command \
	-label [mc "Visualize Current Branch's History"] \
	-command {do_gitk $current_branch}
set ui_visualize_current [.mbar.repository index last]
.mbar.repository add command \
	-label [mc "Visualize All Branch History"] \
	-command {do_gitk --all}
.mbar.repository add separator

proc current_branch_write {args} {
	global current_branch
	.mbar.repository entryconf $::ui_browse_current \
		-label [mc "Browse %s's Files" $current_branch]
	.mbar.repository entryconf $::ui_visualize_current \
		-label [mc "Visualize %s's History" $current_branch]
}
trace add variable current_branch write current_branch_write

if {[is_enabled multicommit]} {
	.mbar.repository add command -label [mc "Database Statistics"] \
		-command do_stats

	.mbar.repository add command -label [mc "Compress Database"] \
		-command do_gc

	.mbar.repository add command -label [mc "Verify Database"] \
		-command do_fsck_objects

	.mbar.repository add separator

	if {[is_Cygwin]} {
		.mbar.repository add command \
			-label [mc "Create Desktop Icon"] \
			-command do_cygwin_shortcut
	} elseif {[is_Windows]} {
		.mbar.repository add command \
			-label [mc "Create Desktop Icon"] \
			-command do_windows_shortcut
	} elseif {[is_MacOSX]} {
		.mbar.repository add command \
			-label [mc "Create Desktop Icon"] \
			-command do_macosx_app
	}
}

if {[is_MacOSX]} {
	proc ::tk::mac::Quit {args} { do_quit }
} else {
	.mbar.repository add command -label [mc Quit] \
		-command do_quit \
		-accelerator $M1T-Q
}

# -- Edit Menu
#
menu .mbar.edit
.mbar.edit add command -label [mc Undo] \
	-command {catch {[focus] edit undo}} \
	-accelerator $M1T-Z
.mbar.edit add command -label [mc Redo] \
	-command {catch {[focus] edit redo}} \
	-accelerator $M1T-Y
.mbar.edit add separator
.mbar.edit add command -label [mc Cut] \
	-command {catch {tk_textCut [focus]}} \
	-accelerator $M1T-X
.mbar.edit add command -label [mc Copy] \
	-command {catch {tk_textCopy [focus]}} \
	-accelerator $M1T-C
.mbar.edit add command -label [mc Paste] \
	-command {catch {tk_textPaste [focus]; [focus] see insert}} \
	-accelerator $M1T-V
.mbar.edit add command -label [mc Delete] \
	-command {catch {[focus] delete sel.first sel.last}} \
	-accelerator Del
.mbar.edit add separator
.mbar.edit add command -label [mc "Select All"] \
	-command {catch {[focus] tag add sel 0.0 end}} \
	-accelerator $M1T-A

# -- Branch Menu
#
if {[is_enabled branch]} {
	menu .mbar.branch

	.mbar.branch add command -label [mc "Create..."] \
		-command branch_create::dialog \
		-accelerator $M1T-N
	lappend disable_on_lock [list .mbar.branch entryconf \
		[.mbar.branch index last] -state]

	.mbar.branch add command -label [mc "Checkout..."] \
		-command branch_checkout::dialog \
		-accelerator $M1T-O
	lappend disable_on_lock [list .mbar.branch entryconf \
		[.mbar.branch index last] -state]

	.mbar.branch add command -label [mc "Rename..."] \
		-command branch_rename::dialog
	lappend disable_on_lock [list .mbar.branch entryconf \
		[.mbar.branch index last] -state]

	.mbar.branch add command -label [mc "Delete..."] \
		-command branch_delete::dialog
	lappend disable_on_lock [list .mbar.branch entryconf \
		[.mbar.branch index last] -state]

	.mbar.branch add command -label [mc "Reset..."] \
		-command merge::reset_hard
	lappend disable_on_lock [list .mbar.branch entryconf \
		[.mbar.branch index last] -state]
}

# -- Commit Menu
#
proc commit_btn_caption {} {
	if {[is_enabled nocommit]} {
		return [mc "Done"]
	} else {
		return [mc Commit@@verb]
	}
}

if {[is_enabled multicommit] || [is_enabled singlecommit]} {
	menu .mbar.commit

	if {![is_enabled nocommit]} {
		.mbar.commit add checkbutton \
			-label [mc "Amend Last Commit"] \
			-accelerator $M1T-E \
			-variable commit_type_is_amend \
			-command do_select_commit_type
		lappend disable_on_lock \
			[list .mbar.commit entryconf [.mbar.commit index last] -state]

		.mbar.commit add separator
	}

	.mbar.commit add command -label [mc Rescan] \
		-command ui_do_rescan \
		-accelerator F5
	lappend disable_on_lock \
		[list .mbar.commit entryconf [.mbar.commit index last] -state]

	.mbar.commit add command -label [mc "Rescan All Tabs"] \
		-command do_rescan_all \
		-accelerator Shift-F5
	lappend disable_on_lock \
		[list .mbar.commit entryconf [.mbar.commit index last] -state]

	.mbar.commit add command -label [mc "Stage To Commit"] \
		-command do_add_selection \
		-accelerator $M1T-T
	lappend disable_on_lock \
		[list .mbar.commit entryconf [.mbar.commit index last] -state]

	.mbar.commit add command -label [mc "Stage Changed Files To Commit"] \
		-command do_add_all \
		-accelerator $M1T-I
	lappend disable_on_lock \
		[list .mbar.commit entryconf [.mbar.commit index last] -state]

	.mbar.commit add command -label [mc "Unstage From Commit"] \
		-command do_unstage_selection \
		-accelerator $M1T-U
	lappend disable_on_lock \
		[list .mbar.commit entryconf [.mbar.commit index last] -state]

	.mbar.commit add command -label [mc "Revert Changes"] \
		-command do_revert_selection \
		-accelerator $M1T-J
	lappend disable_on_lock \
		[list .mbar.commit entryconf [.mbar.commit index last] -state]

	.mbar.commit add separator

	.mbar.commit add command -label [mc "Show Less Context"] \
		-command show_less_context \
		-accelerator $M1T-\-

	.mbar.commit add command -label [mc "Show More Context"] \
		-command show_more_context \
		-accelerator $M1T-=

	.mbar.commit add checkbutton -label [mc "Always Show Entire File"] \
		-variable diff_whole_file_ui \
		-command diff_whole_file_changed

	.mbar.commit add command -label [mc "Next Change"] \
		-command {diff_goto_change 1} \
		-accelerator F3

	.mbar.commit add command -label [mc "Previous Change"] \
		-command {diff_goto_change -1} \
		-accelerator Shift-F3

	.mbar.commit add command -label [mc "Find Text..."] \
		-command diff_show_finder \
		-accelerator $M1T-F

	.mbar.commit add separator

	if {![is_enabled nocommitmsg]} {
		.mbar.commit add command -label [mc "Sign Off"] \
			-command do_signoff \
			-accelerator $M1T-S
	}

	.mbar.commit add command -label [commit_btn_caption] \
		-command do_commit \
		-accelerator $M1T-Return
	lappend disable_on_lock \
		[list .mbar.commit entryconf [.mbar.commit index last] -state]
}

# -- Merge Menu
#
if {[is_enabled branch]} {
	menu .mbar.merge
	.mbar.merge add command -label [mc "Local Merge..."] \
		-command merge::dialog \
		-accelerator $M1T-M
	lappend disable_on_lock \
		[list .mbar.merge entryconf [.mbar.merge index last] -state]
	.mbar.merge add command -label [mc "Abort Merge..."] \
		-command merge::reset_hard
	lappend disable_on_lock \
		[list .mbar.merge entryconf [.mbar.merge index last] -state]
}

# -- Transport Menu
#
if {[is_enabled transport]} {
	menu .mbar.remote

	.mbar.remote add command \
		-label [mc "Add..."] \
		-command remote_add::dialog \
		-accelerator $M1T-A
	.mbar.remote add command \
		-label [mc "Push..."] \
		-command do_push_anywhere \
		-accelerator $M1T-P
	.mbar.remote add command \
		-label [mc "Delete Branch..."] \
		-command remote_branch_delete::dialog
}

if {[is_MacOSX]} {
	proc ::tk::mac::ShowPreferences {} {do_options}
} else {
	# -- Edit Menu
	#
	.mbar.edit add separator
	.mbar.edit add command -label [mc "Options..."] \
		-command do_options
}

# -- Tools Menu
#
if {[is_enabled multicommit] || [is_enabled singlecommit]} {
	set tools_menubar .mbar.tools
	menu $tools_menubar
	$tools_menubar add separator
	$tools_menubar add command -label [mc "Add..."] -command tools_add::dialog
	$tools_menubar add command -label [mc "Remove..."] -command tools_remove::dialog
	set tools_tailcnt 3
	if {[array names repo_config guitool.*.cmd] ne {}} {
		tools_populate_all
	}
}

# -- Help Menu
#
.mbar add cascade -label [mc Help] -menu .mbar.help
menu .mbar.help

if {[is_MacOSX]} {
	.mbar.apple add command -label [mc "About %s" [appname]] \
		-command do_about
	.mbar.apple add separator
} else {
	.mbar.help add command -label [mc "About %s" [appname]] \
		-command do_about
}
. configure -menu .mbar

set doc_path [githtmldir]
if {$doc_path ne {}} {
	set doc_path [file join $doc_path index.html]
}

if {[file isfile $doc_path]} {
	set doc_url "file:$doc_path"
} else {
	set doc_url {https://www.kernel.org/pub/software/scm/git/docs/}
}

proc start_browser {url} {
	git "web--browse" $url
}

.mbar.help add command -label [mc "Online Documentation"] \
	-command [list start_browser $doc_url]

.mbar.help add command -label [mc "Show SSH Key"] \
	-command do_ssh_key

unset doc_path doc_url

# -- Standard bindings
#
wm protocol . WM_DELETE_WINDOW do_quit
bind all <$M1B-Key-q> do_quit
bind all <$M1B-Key-Q> do_quit

set m1b_w_script {
	set toplvl_win [winfo toplevel %W]

	# If we are destroying the main window, we should call do_quit to take
	# care of cleanup before exiting the program.
	if {$toplvl_win eq "."} {
		do_quit
	} else {
		destroy $toplvl_win
	}
}

bind all <$M1B-Key-w> $m1b_w_script
bind all <$M1B-Key-W> $m1b_w_script

unset m1b_w_script

set subcommand_args {}
proc usage {} {
	set s "[mc usage:] $::argv0 $::subcommand $::subcommand_args"
	if {[tk windowingsystem] eq "win32"} {
		wm withdraw .
		tk_messageBox -icon info -message $s \
			-title [mc "Usage"]
	} else {
		puts stderr $s
	}
	exit 1
}

proc normalize_relpath {path} {
	set elements {}
	foreach item [file split $path] {
		if {$item eq {.}} continue
		if {$item eq {..} && [llength $elements] > 0
		    && [lindex $elements end] ne {..}} {
			set elements [lrange $elements 0 end-1]
			continue
		}
		lappend elements $item
	}
	return [eval file join $elements]
}

# -- Not a normal commit type invocation?  Do that instead!
#
switch -- $subcommand {
browser -
blame {
	if {$subcommand eq "blame"} {
		set subcommand_args {[--line=<num>] rev? path}
	} else {
		set subcommand_args {rev? path}
	}
	if {$argv eq {}} usage
	set head {}
	set path {}
	set jump_spec {}
	set is_path 0
	foreach a $argv {
		set p [file join $_prefix $a]

		if {$is_path || [file exists $p]} {
			if {$path ne {}} usage
			set path [normalize_relpath $p]
			break
		} elseif {$a eq {--}} {
			if {$path ne {}} {
				if {$head ne {}} usage
				set head $path
				set path {}
			}
			set is_path 1
		} elseif {[regexp {^--line=(\d+)$} $a a lnum]} {
			if {$jump_spec ne {} || $head ne {}} usage
			set jump_spec [list $lnum]
		} elseif {$head eq {}} {
			if {$head ne {}} usage
			set head $a
			set is_path 1
		} else {
			usage
		}
	}
	unset is_path

	if {$head ne {} && $path eq {}} {
		if {[string index $head 0] eq {/}} {
			set path [normalize_relpath $head]
			set head {}
		} else {
			set path [normalize_relpath $_prefix$head]
			set head {}
		}
	}

	if {$head eq {}} {
		load_current_branch
	} else {
		if {[regexp [string map "@@ [expr $hashlength - 1]" {^[0-9a-f]{1,@@}$}] $head]} {
			if {[catch {
					set head [git rev-parse --verify $head]
				} err]} {
				if {[tk windowingsystem] eq "win32"} {
					tk_messageBox -icon error -title [mc Error] -message $err
				} else {
					puts stderr $err
				}
				exit 1
			}
		}
		set current_branch $head
	}

	wm deiconify .
	switch -- $subcommand {
	browser {
		if {$jump_spec ne {}} usage
		if {$head eq {}} {
			if {$path ne {} && [file isdirectory $path]} {
				set head $current_branch
			} else {
				set head $path
				set path {}
			}
		}
		browser::new $head $path
	}
	blame   {
		if {$head eq {} && ![file exists $path]} {
			catch {wm withdraw .}
			tk_messageBox \
				-icon error \
				-type ok \
				-title [mc "git-gui: fatal error"] \
				-message [mc "fatal: cannot stat path %s: No such file or directory" $path]
			exit 1
		}
		blame::new $head $path $jump_spec
	}
	}
	return
}
citool -
gui {
	if {[llength $argv] != 0} {
		usage
	}
	# fall through to setup UI for commits
}
default {
	set err "[mc usage:] $argv0 \[{blame|browser|citool}\]"
	if {[tk windowingsystem] eq "win32"} {
		wm withdraw .
		tk_messageBox -icon error -message $err \
			-title [mc "Usage"]
	} else {
		puts stderr $err
	}
	exit 1
}
}

# -- Branch Control
#
proc build_branch_control {w} {
	ttk::frame $w
	ttk::label $w.l1 \
		-text [mc "Current Branch:"] \
		-anchor w \
		-justify left
	ttk::label $w.cb \
		-textvariable current_branch \
		-anchor w \
		-justify left
	pack $w.l1 -side left
	pack $w.cb -side left -fill x
	pack $w -side top -fill x
}
# -- Main Window Layout
#
# Multi-repo fork: repositories live in notebook tabs. Each tab is a frame under
# which the whole layout is built (via $ui_w). ui_vpane/ui_vpane_files are
# exposed as globals for the sash geometry save/restore and console sizing.
ttk::notebook .repotabs
pack .repotabs -side top -fill both -expand 1

# Draw a distinct border/divider between tabs. The native Windows (vista) theme
# ignores custom tab border colors, so borrow clam's tab element -- which honors
# -bordercolor -- for this notebook only, leaving the rest of the app native.
ttk::style configure Repo.TNotebook -tabmargins {4 2 4 0}
if {![catch {
	ttk::style element create RepoTab.tab from clam Notebook.tab
}]} {
	ttk::style layout Repo.TNotebook.Tab {
		RepoTab.tab -sticky nswe -children {
			Notebook.padding -side top -sticky nswe -children {
				Notebook.label -side top -sticky nswe
			}
		}
	}
	ttk::style configure Repo.TNotebook.Tab \
		-padding {14 5} -borderwidth 2 -bordercolor #4d4d4d -background #d9d9d9
	ttk::style map Repo.TNotebook.Tab \
		-background {selected #ffffff} \
		-bordercolor {selected #1a1a1a}
} else {
	ttk::style configure Repo.TNotebook.Tab -padding {14 5}
}
.repotabs configure -style Repo.TNotebook

# Rescan All sits in the empty right end of the tab strip; the right tab margin
# reserves its width so tabs never slide underneath it.
ttk::button .rescan_all -text [mc "Rescan All"] -style Toolbutton \
	-command do_rescan_all
foreach action {expand collapse} {
	foreach {suffix color foreground} {normal #555555 white disabled #aaaaaa #dddddd} {
		set icon repo_tab_${action}_$suffix
		image create photo $icon -width 22 -height 18
		$icon put $color -to 0 0 22 18
		$icon put $foreground -to 5 8 17 10
		if {$action eq "expand"} { $icon put $foreground -to 10 3 12 15 }
	}
	ttk::button .group_$action \
		-image [list repo_tab_${action}_normal disabled repo_tab_${action}_disabled] \
		-style Toolbutton -command [list repo_tab_set_all [expr {$action eq "collapse"}]]
	bind .group_$action <Enter> [list repo_tab_all_tooltip $action]
	bind .group_$action <Leave> repo_tab_hide_tooltip
	bind .group_$action <ButtonPress> repo_tab_hide_tooltip
}
unset action suffix color foreground icon
lappend rescan_all_buttons .rescan_all
lappend disable_on_lock [list .rescan_all conf -state]
set _rescan_all_w [expr {max([winfo reqwidth .rescan_all],
	[font measure TkDefaultFont [.rescan_all cget -text]] + 24)}]
ttk::style configure Repo.TNotebook \
	-tabmargins [list 4 2 [expr {$_rescan_all_w + [winfo reqwidth .group_expand] + [winfo reqwidth .group_collapse] + 28}] 0]
place .rescan_all -in .repotabs -relx 1.0 -x -4 -y 1 -anchor ne
place .group_collapse -in .repotabs -relx 1.0 -x [expr {-$_rescan_all_w - 12}] -y 1 -anchor ne
place .group_expand -in .repotabs -relx 1.0 -x [expr {-$_rescan_all_w - [winfo reqwidth .group_collapse] - 20}] -y 1 -anchor ne
unset _rescan_all_w
raise .rescan_all
raise .group_expand
raise .group_collapse

set repo_tab_palette {
	#4e79a7 #59a14f #e15759 #b07aa1 #f28e2b
	#76b7b2 #edc948 #ff9da7 #9c755f #bab0ac}
set repo_tab_swatch_seq 0
array set repo_tab_family {}
array set repo_tab_images {}
array set repo_tab_image_state {}
array set repo_tab_main {}
array set repo_tab_discovery {}
array set repo_tab_pending {}
set repo_tab_load_queue {}
set repo_tab_load_timer {}
array set repo_tab_collapsed {}
array set repo_tab_representative {}
set repo_tab_hover {}
set repo_tab_hover_timer {}
set repo_tab_all_states {}
proc repo_tab_decorate {family} {
	global repo_tab_palette repo_tab_swatch_seq repo_tab_images
	if {[info exists repo_tab_images($family)]} { return $repo_tab_images($family) }
	set color [lindex $repo_tab_palette \
		[expr {$repo_tab_swatch_seq % [llength $repo_tab_palette]}]]
	set n [incr repo_tab_swatch_seq]
	set img repo_tab_swatch_$n
	image create photo $img -width 22 -height 18
	$img put $color -to 0 0 22 18
	set repo_tab_images($family) $img
	return $img
}

proc repo_tab_refresh_groups {} {
	global repo_tab_family repo_tab_images repo_tab_image_state repo_tab_collapsed repo_tab_representative
	global repo_tab_all_states
	set groups [dict create]
	foreach tab [.repotabs tabs] {
		if {![info exists repo_tab_family($tab)]} continue
		dict lappend groups [dict get $repo_tab_family($tab) family] $tab
	}
	set selected [.repotabs select]
	set position 0
	set expandable 0
	set expanded 0
	dict for {family tabs} $groups {
		set main_tabs {}
		set worktree_tabs {}
		foreach tab $tabs {
			set path [dict get $repo_tab_family($tab) path]
			set main [dict get $repo_tab_family($tab) repository]
			if {$path eq $main || ([is_Windows] && [string equal -nocase $path $main])} {
				lappend main_tabs $tab
			} else {
				lappend worktree_tabs $tab
			}
		}
		set tabs [concat $main_tabs $worktree_tabs]
		foreach tab $tabs {
			if {[.repotabs index $tab] != $position} {
				.repotabs insert $position $tab
			}
			incr position
		}
		if {![info exists repo_tab_collapsed($family)]} { set repo_tab_collapsed($family) 0 }
		if {[lsearch -exact $tabs $selected] >= 0} {
			set repo_tab_representative($family) $selected
		} elseif {![info exists repo_tab_representative($family)] ||
			[lsearch -exact $tabs $repo_tab_representative($family)] < 0} {
			set repo_tab_representative($family) [lindex $tabs 0]
		}
		set representative $repo_tab_representative($family)
		set count [llength $tabs]
		set collapsed [expr {$repo_tab_collapsed($family) && $count > 1}]
		if {$count > 1} {
			incr expandable
			if {!$collapsed} { incr expanded }
		}
		foreach tab $tabs {
			set label [dict get $repo_tab_family($tab) label]
			if {$collapsed && $tab eq $representative} {
				set label [file tail [dict get $repo_tab_family($tab) repository]]
				append label " (+[expr {$count - 1}])"
			}
			if {[.repotabs tab $tab -text] ne $label} { .repotabs tab $tab -text $label }
			if {!$collapsed || $tab eq $representative} {
				if {[.repotabs tab $tab -state] ne "normal"} { .repotabs tab $tab -state normal }
			} else {
				if {[.repotabs tab $tab -state] ne "hidden"} { .repotabs hide $tab }
			}
		}
		set image_state [list [expr {$count > 1}] $collapsed]
		if {[info exists repo_tab_image_state($family)] &&
			$repo_tab_image_state($family) eq $image_state} continue
		set image $repo_tab_images($family)
		set color [format "#%02x%02x%02x" {*}[$image get 0 0]]
		$image put $color -to 0 0 22 18
		if {$count > 1} {
			$image put white -to 5 8 17 10
			if {$collapsed} { $image put white -to 10 3 12 15 }
		}
		set repo_tab_image_state($family) $image_state
	}
	set states [list [expr {$expandable > $expanded ? "normal" : "disabled"}] \
		[expr {$expanded > 0 ? "normal" : "disabled"}]]
	if {![info exists repo_tab_all_states] || $states ne $repo_tab_all_states} {
		set repo_tab_all_states $states
		foreach action {expand collapse} state $states {
			if {[winfo exists .group_$action]} { .group_$action configure -state $state }
		}
	}
}

proc repo_tab_set_all {collapsed} {
	global repo_tab_collapsed
	repo_tab_hide_tooltip
	foreach family [array names repo_tab_collapsed] { set repo_tab_collapsed($family) $collapsed }
	repo_tab_refresh_groups
}

proc repo_tab_all_tooltip {action} {
	global repo_tab_hover_timer
	repo_tab_hide_tooltip
	if {$action eq "expand"} {
		set text [mc "Expand All Repository Groups"]
	} else {
		set text [mc "Collapse All Repository Groups"]
	}
	set repo_tab_hover_timer [after 600 [list repo_tab_present_tooltip $text]]
}

proc repo_tab_toggle_at {x y} {
	global repo_tab_family repo_tab_collapsed
	if {[catch {.repotabs index @$x,$y} index]} { return 0 }
	set tab [lindex [.repotabs tabs] $index]
	if {![info exists repo_tab_family($tab)]} { return 0 }
	if {[.repotabs identify $x $y] ne "label"} { return 0 }
	set left $x
	while {$left > 0 && [.repotabs identify [expr {$left - 1}] $y] eq "label"} {
		if {[catch {.repotabs index @[expr {$left - 1}],$y} previous] || $previous != $index} break
		incr left -1
	}
	if {$x - $left >= 22} { return 0 }
	set family [dict get $repo_tab_family($tab) family]
	set count 0
	foreach member [.repotabs tabs] {
		if {[info exists repo_tab_family($member)] &&
			[dict get $repo_tab_family($member) family] eq $family} { incr count }
	}
	if {$count < 2} { return 0 }
	set repo_tab_collapsed($family) [expr {!$repo_tab_collapsed($family)}]
	repo_tab_refresh_groups
	return 1
}

proc repo_tab_label {main worktree name} {
	set same_path [expr {[file normalize $worktree] eq $main}]
	if {[is_Windows]} { set same_path [string equal -nocase [file normalize $worktree] $main] }
	set label [file tail $main]
	if {!$same_path} {
		if {[string first "$label-" $name] == 0} {
			set name [string range $name [expr {[string length $label] + 1}] end]
		}
		set label $name
	}
	return $label
}

proc repo_tab_discover {family gitdir} {
	global repo_tab_family repo_tab_main repo_tab_discovery
	unset -nocomplain repo_tab_discovery($family)
	set members {}
	foreach tab [.repotabs tabs] {
		if {[info exists repo_tab_family($tab)] &&
			[dict get $repo_tab_family($tab) family] eq $family} { lappend members $tab }
	}
	if {[llength $members] == 0} return
	if {[catch {set listing [git --git-dir=$gitdir worktree list --porcelain -z]}]} return
	set first [lindex [split $listing "\0"] 0]
	if {![string match "worktree *" $first]} return
	set main [file normalize [string range $first 9 end]]
	set repo_tab_main($family) $main
	foreach tab $members {
		set metadata $repo_tab_family($tab)
		dict set metadata repository $main
		dict set metadata label [repo_tab_label $main [dict get $metadata path] [dict get $metadata name]]
		set repo_tab_family($tab) $metadata
		if {[winfo exists $tab.repository]} {
			set path $main
			if {[is_Windows]} { set path [file nativename $path] }
			$tab.repository configure -text [mc "Repository: %s" $path]
		}
	}
	repo_tab_refresh_groups
}

proc repo_tab_add {widget gitdir worktree name} {
	global repo_tab_family repo_tab_main repo_tab_discovery
	set common $gitdir
	if {[file exists [file join $gitdir commondir]]} {
		if {[catch {
			set common_file [open [file join $gitdir commondir] r]
			try {
				set common [file normalize [file join $gitdir [string trim [read $common_file]]]]
			} finally {
				close $common_file
			}
		}]} { set common $gitdir }
	}
	set family $common
	if {[is_Windows]} { set family [string tolower $family] }
	set main $worktree
	if {[info exists repo_tab_main($family)]} {
		set main $repo_tab_main($family)
	} elseif {[file tail $common] eq ".git"} {
		set main [file dirname $common]
	}
	set label [repo_tab_label $main $worktree $name]
	set neighbor {}
	foreach tab [.repotabs tabs] {
		if {[info exists repo_tab_family($tab)] &&
			[dict get $repo_tab_family($tab) family] eq $family} {
			set neighbor $tab
		}
	}
	set repo_tab_family($widget) [dict create family $family gitdir $gitdir path $worktree label $label repository $main name $name]
	.repotabs add $widget -text $label -image [repo_tab_decorate $family] -compound left
	if {$neighbor ne {}} {
		.repotabs insert [expr {[.repotabs index $neighbor] + 1}] $widget
	}
	repo_tab_refresh_groups
	if {![info exists repo_tab_main($family)] && ![info exists repo_tab_discovery($family)]} {
		set repo_tab_discovery($family) [after idle [list after 0 [list repo_tab_discover $family $gitdir]]]
	}
}

proc repo_tab_hide_tooltip {} {
	global repo_tab_hover repo_tab_hover_timer
	if {$repo_tab_hover_timer ne {}} { after cancel $repo_tab_hover_timer }
	set repo_tab_hover_timer {}
	set repo_tab_hover {}
	if {[winfo exists .repo_tab_tooltip]} { wm withdraw .repo_tab_tooltip }
}

proc repo_tab_present_tooltip {text} {
	set tooltip .repo_tab_tooltip
	if {![winfo exists $tooltip]} {
		toplevel $tooltip -borderwidth 1
		wm withdraw $tooltip
		wm overrideredirect $tooltip 1
		wm transient $tooltip .
		catch {wm attributes $tooltip -type tooltip}
		ttk::label $tooltip.text -padding 6
		pack $tooltip.text
	}
	$tooltip.text configure -text $text
	update idletasks
	set x [expr {min([winfo pointerx .] + 12,
		[winfo screenwidth .] - [winfo reqwidth $tooltip])}]
	set y [expr {min([winfo pointery .] + 20,
		[winfo screenheight .] - [winfo reqheight $tooltip])}]
	wm geometry $tooltip +[expr {max(0, $x)}]+[expr {max(0, $y)}]
	wm deiconify $tooltip
}

proc repo_tab_show_tooltip {tab} {
	global repo_tab_family repo_tab_hover_timer
	set repo_tab_hover_timer {}
	if {![winfo exists $tab] || ![info exists repo_tab_family($tab)]} return
	set metadata $repo_tab_family($tab)
	set gitdir [dict get $metadata gitdir]
	set branch {}
	if {![catch {set head_file [open [file join $gitdir HEAD] r]}]} {
		try {
			set head [string trim [read $head_file 4096]]
			if {![regexp {^ref: refs/heads/(.+)$} $head -> branch]} {
				if {[regexp {^[[:xdigit:]]+$} $head]} { set branch [string range $head 0 6] }
			}
		} finally {
			close $head_file
		}
	}
	set path [dict get $metadata path]
	if {[is_Windows]} { set path [file nativename $path] }
	set text "$path\n$branch"
	set family [dict get $metadata family]
	set count 0
	foreach member [.repotabs tabs] {
		if {[info exists repo_tab_family($member)] &&
			[dict get $repo_tab_family($member) family] eq $family} { incr count }
	}
	if {$count > 1} {
		if {$::repo_tab_collapsed($family)} {
			append text "\n" [mc "Expand repository group"]
		} else {
			append text "\n" [mc "Collapse repository group"]
		}
	}
	repo_tab_present_tooltip $text
}

proc repo_tab_motion {x y} {
	global repo_tab_hover repo_tab_hover_timer
	if {[catch {.repotabs index @$x,$y} index]} {
		repo_tab_hide_tooltip
		return
	}
	set tab [lindex [.repotabs tabs] $index]
	if {$tab eq $repo_tab_hover} return
	repo_tab_hide_tooltip
	set repo_tab_hover $tab
	set repo_tab_hover_timer [after 600 [list repo_tab_show_tooltip $tab]]
}
bind .repotabs <Motion> {repo_tab_motion %x %y}
bind .repotabs <Leave> repo_tab_hide_tooltip
bind .repotabs <ButtonPress> repo_tab_hide_tooltip

ttk::frame .repotabs.repo0
repo_tab_add .repotabs.repo0 $_gitdir $_gitworktree $_reponame

# Build one repository's entire UI under tab frame $w. Every panel sets its ui_*
# path globals relative to $w, so switching repoctx to a repo repoints all the
# shared logic at that tab's widgets. Wrapped as a proc so more repos can open in
# new tabs; inner proc defs simply redefine the global helpers harmlessly.
proc build_repo_ui {w} {
	global ui_w ui_vpane ui_vpane_files ui_index ui_workdir ui_diff
	set repository [dict get $::repo_tab_family($w) repository]
	if {[is_Windows]} { set repository [file nativename $repository] }
	ttk::label $w.repository -text [mc "Repository: %s" $repository] -anchor w
	pack $w.repository -side top -fill x -padx 5 -pady 2
	set ui_w $w
	set ui_vpane $w.vpane
	set ui_vpane_files $ui_vpane.files

build_branch_control $ui_w.branch

ttk::panedwindow $ui_vpane -orient horizontal
ttk::panedwindow $ui_vpane_files -orient vertical
$ui_vpane add $ui_vpane_files
pack $ui_vpane -anchor n -side top -fill both -expand 1

# -- Working Directory and Index File Lists
#
# Multi-repo fork spike: both panes are built by a proc that takes an arbitrary
# parent $w and points the ui_workdir/ui_index path globals at it. In a fork $w
# is each repo's tab frame; here it is the shared .vpane.files. The rest of the
# code reaches these widgets only through the ui_* globals, so this is all that
# is needed to make the file lists per-repo.
proc build_file_lists {w} {
	global ui_workdir ui_index cursor_ptr
	set ui_workdir $w.workdir.list
	set ui_index   $w.index.list

	textframe $w.workdir -height 100 -width 200
	tlabel $w.workdir.title -text [mc "Unstaged Changes"] \
		-background lightsalmon -foreground black
	ttext $ui_workdir \
		-borderwidth 0 \
		-width 20 -height 10 \
		-wrap none \
		-takefocus 1 -highlightthickness 1\
		-cursor $cursor_ptr \
		-xscrollcommand [list $w.workdir.sx set] \
		-yscrollcommand [list $w.workdir.sy set] \
		-state disabled
	ttk::scrollbar $w.workdir.sx -orient h -command [list $ui_workdir xview]
	ttk::scrollbar $w.workdir.sy -orient v -command [list $ui_workdir yview]
	pack $w.workdir.title -side top -fill x
	pack $w.workdir.sx -side bottom -fill x
	pack $w.workdir.sy -side right -fill y
	pack $ui_workdir -side left -fill both -expand 1

	textframe $w.index -height 100 -width 200
	tlabel $w.index.title \
		-text [mc "Staged Changes (Will Commit)"] \
		-background lightgreen -foreground black
	ttext $ui_index \
		-borderwidth 0 \
		-width 20 -height 10 \
		-wrap none \
		-takefocus 1 -highlightthickness 1\
		-cursor $cursor_ptr \
		-xscrollcommand [list $w.index.sx set] \
		-yscrollcommand [list $w.index.sy set] \
		-state disabled
	ttk::scrollbar $w.index.sx -orient h -command [list $ui_index xview]
	ttk::scrollbar $w.index.sy -orient v -command [list $ui_index yview]
	pack $w.index.title -side top -fill x
	pack $w.index.sx -side bottom -fill x
	pack $w.index.sy -side right -fill y
	pack $ui_index -side left -fill both -expand 1

	$w add $w.workdir
	$w add $w.index
}
build_file_lists $ui_vpane_files

foreach _pw [list $ui_vpane $ui_vpane_files] {
	bind $_pw <ButtonPress-1>   {autosize_press %W}
	bind $_pw <ButtonRelease-1> {autosize_release %W}
	bind $_pw <Double-Button-1> [list autosize_unpin %W $ui_vpane_files]
}
unset _pw
bind $ui_vpane_files <Configure> [list autosize_schedule $ui_vpane_files]

proc set_selection_colors {w has_focus} {
	foreach tag [list in_diff in_sel] {
		$w tag conf $tag \
			-background [expr {$has_focus ? $color::select_bg : $color::inactive_select_bg}] \
			-foreground [expr {$has_focus ? $color::select_fg : $color::inactive_select_fg}]
	}
}

foreach i [list $ui_index $ui_workdir] {
	rmsel_tag $i

	set_selection_colors $i 0
	bind $i <FocusIn>	{ set_selection_colors %W 1 }
	bind $i <FocusOut>	{ set_selection_colors %W 0 }
	bind $i <Button-1>         { toggle_or_diff click %W %x %y; break }
	bind $i <$::M1B-Button-1>  { add_one_to_selection %W %x %y; break }
	bind $i <Shift-Button-1>   { add_range_to_selection %W %x %y; break }
	bind $i <Key-Up>           { toggle_or_diff up %W; break }
	bind $i <Key-Down>         { toggle_or_diff down %W; break }
	set ::file_lists_last_clicked($i) {}
	set ::file_lists($i) [list]
}
unset i

# -- Diff and Commit Area
#
ttk::panedwindow $ui_vpane.lower -orient vertical
ttk::frame $ui_vpane.lower.commarea
ttk::frame $ui_vpane.lower.diff -relief sunken -borderwidth 1 -height 500
$ui_vpane.lower add $ui_vpane.lower.diff
$ui_vpane.lower add $ui_vpane.lower.commarea
$ui_vpane add $ui_vpane.lower
$ui_vpane.lower pane $ui_vpane.lower.diff -weight 1
$ui_vpane.lower pane $ui_vpane.lower.commarea -weight 0

# -- Commit Area Buttons and Message Buffer
#
# Multi-repo fork spike: built under an arbitrary parent $w with ui_comm/ui_coml/
# ui_comm_ctxm pointed at it; trace_commit_type updates the active tab's label.
proc trace_commit_type {varname args} {
	global ui_coml commit_type commit_author
	if {$ui_coml eq {} || ![winfo exists $ui_coml]} return
	switch -glob -- $commit_type {
	initial       {set txt [mc "Initial Commit Message:"]}
	amend         {set txt [mc "Amended Commit Message:"]}
	amend-initial {set txt [mc "Amended Initial Commit Message:"]}
	amend-merge   {set txt [mc "Amended Merge Commit Message:"]}
	merge         {set txt [mc "Merge Commit Message:"]}
	*             {set txt [mc "Commit Message:"]}
	}
	if {[string match amend* $commit_type] && [info exists commit_author]
		&& [llength $commit_author] == 6} {
		append txt "   " [mc "Author:"] " " \
			[dict get $commit_author name] \
			" <[dict get $commit_author email]>"
	}
	$ui_coml conf -text $txt
}

proc build_commit_area {w} {
	global ui_comm ui_coml ui_comm_ctxm disable_on_lock repo_config ui_commarea
	set ui_commarea $w

	ttk::frame $w.buttons
	ttk::label $w.buttons.l -text {} \
		-anchor w \
		-justify left
	pack $w.buttons.l -side top -fill x
	pack $w.buttons -side left -fill y

	ttk::button $w.buttons.rescan -text [mc Rescan] \
		-command ui_do_rescan
	pack $w.buttons.rescan -side top -fill x
	lappend disable_on_lock [list $w.buttons.rescan conf -state]

	ttk::button $w.buttons.incall -text [mc "Stage Changed"] \
		-command do_add_all
	pack $w.buttons.incall -side top -fill x
	lappend disable_on_lock [list $w.buttons.incall conf -state]

	if {![is_enabled nocommitmsg]} {
		ttk::button $w.buttons.signoff -text [mc "Sign Off"] \
			-command do_signoff
		pack $w.buttons.signoff -side top -fill x
	}

	ttk::button $w.buttons.commit -text [commit_btn_caption] \
		-command do_commit
	pack $w.buttons.commit -side top -fill x
	lappend disable_on_lock [list $w.buttons.commit conf -state]

	if {![is_enabled nocommit]} {
		ttk::button $w.buttons.push -text [mc Push] \
			-command do_push_anywhere
		pack $w.buttons.push -side top -fill x
	}

	ttk::frame $w.buffer
	ttk::frame $w.buffer.header
	set ui_comm $w.buffer.frame.t
	set ui_coml $w.buffer.header.l

	if {![is_enabled nocommit]} {
		ttk::checkbutton $w.buffer.header.amend \
			-text [mc "Amend Last Commit"] \
			-variable commit_type_is_amend \
			-command do_select_commit_type
		lappend disable_on_lock \
			[list $w.buffer.header.amend conf -state]
	}

	ttk::label $ui_coml \
		-anchor w \
		-justify left
	pack $ui_coml -side left -fill x

	if {![is_enabled nocommit]} {
		pack $w.buffer.header.amend -side right
	}

	textframe $w.buffer.frame
	ttext $ui_comm \
		-borderwidth 1 \
		-undo true \
		-maxundo 20 \
		-autoseparators true \
		-takefocus 1 \
		-highlightthickness 1 \
		-relief sunken \
		-width $repo_config(gui.commitmsgwidth) -height 9 -wrap none \
		-font font_diff \
		-xscrollcommand [list $w.buffer.frame.sbx set] \
		-yscrollcommand [list $w.buffer.frame.sby set]
	ttk::scrollbar $w.buffer.frame.sbx \
		-orient horizontal \
		-command [list $ui_comm xview]
	ttk::scrollbar $w.buffer.frame.sby \
		-orient vertical \
		-command [list $ui_comm yview]

	pack $w.buffer.frame.sbx -side bottom -fill x
	pack $w.buffer.frame.sby -side right -fill y
	pack $ui_comm -side left -fill y
	pack $w.buffer.header -side top -fill x
	pack $w.buffer.frame -side left -fill y
	pack $w.buffer -side left -fill y

	set ctxm $w.buffer.ctxm
	menu $ctxm -tearoff 0
	$ctxm add command \
		-label [mc Cut] \
		-command {tk_textCut $ui_comm}
	$ctxm add command \
		-label [mc Copy] \
		-command {tk_textCopy $ui_comm}
	$ctxm add command \
		-label [mc Paste] \
		-command {tk_textPaste $ui_comm}
	$ctxm add command \
		-label [mc Delete] \
		-command {catch {$ui_comm delete sel.first sel.last}}
	$ctxm add separator
	$ctxm add command \
		-label [mc "Select All"] \
		-command {focus $ui_comm;$ui_comm tag add sel 0.0 end}
	$ctxm add command \
		-label [mc "Copy All"] \
		-command {
			$ui_comm tag add sel 0.0 end
			tk_textCopy $ui_comm
			$ui_comm tag remove sel 0.0 end
		}
	$ctxm add separator
	$ctxm add command \
		-label [mc "Sign Off"] \
		-command do_signoff
	set ui_comm_ctxm $ctxm
}
build_commit_area $ui_vpane.lower.commarea
if {![info exists ::_gg_trace_ct]} {
	set ::_gg_trace_ct 1
	trace add variable ::commit_type write trace_commit_type
}

# -- Diff Header
#
# Multi-repo fork spike: the header frame path is stored in ui_diff_hdr and the
# labels live under it, so the trace updates the active tab's diff header.
proc trace_current_diff_path {varname args} {
	global current_diff_path diff_actions file_states _gitworktree ui_diff_hdr
	if {$ui_diff_hdr eq {} || ![winfo exists $ui_diff_hdr.status]} return
	if {$current_diff_path eq {}} {
		set s {}
		set f {}
		set p {}
		set o disabled
	} else {
		set p $current_diff_path
		set s [mapdesc [lindex $file_states($p) 0] $p]
		set f [mc "File:"]
		set p [escape_path [file nativename [file join $_gitworktree $p]]]
		set o normal
	}

	$ui_diff_hdr.status configure -text $s
	$ui_diff_hdr.file configure -text $f
	$ui_diff_hdr.path configure -text $p
	foreach w $diff_actions {
		uplevel #0 $w $o
	}
}
if {![info exists ::_gg_trace_cdp]} {
	set ::_gg_trace_cdp 1
	trace add variable ::current_diff_path write trace_current_diff_path
}

proc copy_diff_path_unix {} {
	global _gitworktree current_diff_path
	clipboard clear
	clipboard append -format STRING -type STRING \
		-- [file join $_gitworktree $current_diff_path]
}

proc build_diff_header {w} {
	global ui_diff_hdr max_status_desc diff_actions
	set ui_diff_hdr $w.header
	gold_frame $w.header
	tlabel $w.header.status \
		-background gold \
		-foreground black \
		-width $max_status_desc \
		-anchor w \
		-justify left
	tlabel $w.header.file \
		-background gold \
		-foreground black \
		-anchor w \
		-justify left
	tlabel $w.header.path \
		-background gold \
		-foreground blue \
		-anchor w \
		-justify left \
		-font [eval font create [font configure font_ui] -underline 1] \
		-cursor hand2
	pack $w.header.status -side left
	pack $w.header.file -side left
	ttk::button $w.header.next -text [mc "Next Change"] \
		-takefocus 0 -command {diff_goto_change 1}
	ttk::button $w.header.prev -text [mc "Previous Change"] \
		-takefocus 0 -command {diff_goto_change -1}
	pack $w.header.next -side right -padx 2
	pack $w.header.prev -side right -padx 2
	pack $w.header.path -fill x
	set ctxm $w.header.ctxm
	menu $ctxm -tearoff 0
	$ctxm add command \
		-label [mc "Copy Path"] \
		-command {
			clipboard clear
			clipboard append \
				-format STRING \
				-type STRING \
				-- [file nativename [file join $_gitworktree $current_diff_path]]
		}
	$ctxm add command \
		-label [mc "Copy Unix Path"] \
		-command {copy_diff_path_unix}
	$ctxm add command \
		-label [mc Open] \
		-command {do_file_open $current_diff_path}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add separator
	$ctxm add command \
		-label [mc "Open in Azure DevOps"] \
		-command {do_ado_open $current_diff_path}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add command \
		-label [mc "Copy Azure DevOps Link"] \
		-command {do_ado_copy $current_diff_path}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	bind_button3 $w.header.path "tk_popup $ctxm %X %Y"
	bind $w.header.path <Button-1> {do_file_open $current_diff_path}
	bind $w.header.path <Button-2> {
		clipboard clear
		clipboard append \
			-format STRING \
			-type STRING \
			-- [file nativename [file join $_gitworktree $current_diff_path]]
	}
	bind $w.header.path <Double-Button-2> {copy_diff_path_unix}
}
build_diff_header $ui_vpane.lower.diff

# -- Diff Body
#
# Multi-repo fork spike: the line-number + diff text widgets are built by a proc
# under an arbitrary parent $w, pointing ui_diff/ui_diff_ln at it. The scroll
# helpers derive their sibling widgets from the owning diff widget.
proc diff_yscrollcmd {diff finder args} {
	if {![winfo exists $diff]} return
	set body [winfo parent $diff]
	if {![winfo exists $body.sby] || ![winfo exists $body.ln]} return
	eval $body.sby set $args
	$body.ln yview moveto [lindex $args 0]
	catch {::searchbar::scrolled $finder}
}
proc diff_show_finder {} {
	global ui_diff_finder
	catch {::searchbar::show $ui_diff_finder}
}
proc diff_yview {diff args} {
	if {![winfo exists $diff]} return
	set body [winfo parent $diff]
	if {![winfo exists $body.ln]} return
	eval $diff yview $args
	$body.ln yview moveto [lindex [$diff yview] 0]
}

proc build_diff_body {w} {
	global ui_diff ui_diff_ln ui_diff_finder
	set ui_diff_ln $w.body.ln
	set ui_diff    $w.body.t

	textframe $w.body
	text $ui_diff_ln \
		-borderwidth 0 \
		-width 11 -height 5 -wrap none \
		-font font_diff \
		-state disabled \
		-takefocus 0 \
		-highlightthickness 0 \
		-background #f0f0f0 \
		-foreground #888888 \
		-padx 4 \
		-cursor {}
	bind $ui_diff_ln <MouseWheel> \
		"[list diff_yview $ui_diff] scroll \[expr {-%D/120}\] units; break"
	bind $ui_diff_ln <Button-4> [list diff_yview $ui_diff scroll -1 units]\;break
	bind $ui_diff_ln <Button-5> [list diff_yview $ui_diff scroll 1 units]\;break

	ttext $ui_diff \
		-borderwidth 0 \
		-width 80 -height 5 -wrap none \
		-font font_diff \
		-takefocus 1 -highlightthickness 1 \
		-xscrollcommand [list $w.body.sbx set] \
		-yscrollcommand [list diff_yscrollcmd $ui_diff {}] \
		-state disabled
	catch {$ui_diff configure -tabstyle wordprocessor}
	ttk::scrollbar $w.body.sbx -orient horizontal \
		-command [list $ui_diff xview]
	ttk::scrollbar $w.body.sby -orient vertical \
		-command [list diff_yview $ui_diff]
	# Change overview strip, packed beside the scrollbar in whole-file mode.
	canvas $w.body.map -width 12 -highlightthickness 0 -borderwidth 0 \
		-background #f0f0f0 -cursor {}
	bind $w.body.map <Configure> {diff_map_draw %W}
	bind $w.body.map <Button-1> {diff_map_click %W %y}
	bind $w.body.map <B1-Motion> {diff_map_click %W %y}
	pack $w.body.sbx -side bottom -fill x
	# The search bar is grid-managed; the zero-size spacer keeps this container
	# collapsed while the bar is hidden.
	ttk::frame $w.body.fc
	grid columnconfigure $w.body.fc 0 -weight 1
	grid [ttk::frame $w.body.fc.sp] -row 1 -column 0
	set ui_diff_finder [::searchbar::new $w.body.fc.f $ui_diff -row 0 -column 0]
	$ui_diff configure -yscrollcommand [list diff_yscrollcmd $ui_diff $ui_diff_finder]
	pack $w.body.fc -side bottom -fill x
	pack $w.body.sby -side right -fill y
	pack $ui_diff_ln -side left -fill y
	pack $ui_diff -side left -fill both -expand 1
	pack $w.body -side bottom -fill both -expand 1

	set f $ui_diff_finder
	set e [::searchbar::editor $f]
	bind $ui_diff <Key-slash> [list ::searchbar::show $f]\;break
	bind $ui_diff <$::M1B-Key-f> [list ::searchbar::show $f]\;break
	bind $ui_diff <$::M1B-Key-F> [list ::searchbar::show $f]\;break
	bind $ui_diff <Escape>    [list ::searchbar::hide $f]
	bind $e <Escape>          [list ::searchbar::hide $f]\;break
	bind $e <Key-F3>          [list ::searchbar::find_next $f]\;break
	bind $e <Shift-Key-F3>    [list ::searchbar::find_prev $f]\;break

	foreach {n c} {0 black 1 red4 2 green4 3 yellow4 4 blue4 5 magenta4 6 cyan4 7 grey60} {
		$ui_diff tag configure clr4$n -background $c
		$ui_diff tag configure clri4$n -foreground $c
		$ui_diff tag configure clr3$n -foreground $c
		$ui_diff tag configure clri3$n -background $c
	}
	$ui_diff tag configure clr1 -font font_diffbold
	$ui_diff tag configure clr4 -underline 1

	$ui_diff tag conf d_info -foreground blue -font font_diffbold
	$ui_diff tag conf d_rescan -foreground blue -underline 1 -font font_diffbold
	$ui_diff tag bind d_rescan <Button-1> { clear_diff; rescan ui_ready 0 }

	$ui_diff tag conf d_cr -elide true
	$ui_diff tag conf d_@ -font font_diffbold
	$ui_diff tag conf d_+ -foreground {#00a000}
	$ui_diff tag conf d_- -foreground red

	$ui_diff tag conf d_++ -foreground {#00a000}
	$ui_diff tag conf d_-- -foreground red
	$ui_diff tag conf d_+s \
		-foreground {#00a000} \
		-background {#e2effa}
	$ui_diff tag conf d_-s \
		-foreground red \
		-background {#e2effa}
	$ui_diff tag conf d_s+ \
		-foreground {#00a000} \
		-background ivory1
	$ui_diff tag conf d_s- \
		-foreground red \
		-background ivory1

	$ui_diff tag conf d< \
		-foreground orange \
		-font font_diffbold
	$ui_diff tag conf d| \
		-foreground orange \
		-font font_diffbold
	$ui_diff tag conf d= \
		-foreground orange \
		-font font_diffbold
	$ui_diff tag conf d> \
		-foreground orange \
		-font font_diffbold

	$ui_diff tag conf found -background yellow
	$ui_diff tag raise sel
}
pack $ui_vpane.lower.diff.header -side top -fill x
build_diff_body $ui_vpane.lower.diff

# -- Diff Body Context Menu
#

proc create_common_diff_popup {ctxm} {
	$ctxm add command \
		-label [mc "Next Change"] \
		-command {diff_goto_change 1} \
		-accelerator F3
	$ctxm add command \
		-label [mc "Previous Change"] \
		-command {diff_goto_change -1} \
		-accelerator Shift-F3
	$ctxm add command \
		-label [mc "Find Text..."] \
		-command diff_show_finder \
		-accelerator $::M1T-F
	$ctxm add checkbutton \
		-label [mc "Always Show Entire File"] \
		-variable diff_whole_file_ui \
		-command diff_whole_file_changed
	$ctxm add separator
	$ctxm add command \
		-label [mc Refresh] \
		-command reshow_diff
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add command \
		-label [mc Copy] \
		-command {tk_textCopy $ui_diff}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add command \
		-label [mc "Select All"] \
		-command {focus $ui_diff;$ui_diff tag add sel 0.0 end}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add command \
		-label [mc "Copy All"] \
		-command {
			$ui_diff tag add sel 0.0 end
			tk_textCopy $ui_diff
			$ui_diff tag remove sel 0.0 end
		}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add separator
	$ctxm add command \
		-label [mc "Decrease Font Size"] \
		-command {incr_font_size font_diff -1}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add command \
		-label [mc "Increase Font Size"] \
		-command {incr_font_size font_diff 1}
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add separator
	set emenu $ctxm.enc
	menu $emenu
	build_encoding_menu $emenu [list force_diff_encoding]
	$ctxm add cascade \
		-label [mc "Encoding"] \
		-menu $emenu
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add separator
	$ctxm add command -label [mc "Options..."] \
		-command do_options
}

proc build_diff_menus {} {
	global ui_diff diff_actions
	global ui_diff_applyhunk ui_diff_applyline
	global ui_diff_reverthunk ui_diff_revertline ui_diff_undorevert

	set ctxm $ui_diff.ctxm
	menu $ctxm -tearoff 0
	$ctxm add command \
		-label [mc "Apply/Reverse Hunk"] \
		-command {apply_or_revert_hunk $cursorX $cursorY 0}
	set ui_diff_applyhunk [$ctxm index last]
	lappend diff_actions [list $ctxm entryconf $ui_diff_applyhunk -state]
	$ctxm add command \
		-label [mc "Apply/Reverse Line"] \
		-command {apply_or_revert_range_or_line $cursorX $cursorY 0; do_rescan}
	set ui_diff_applyline [$ctxm index last]
	lappend diff_actions [list $ctxm entryconf $ui_diff_applyline -state]
	$ctxm add separator
	$ctxm add command \
		-label [mc "Revert Hunk"] \
		-command {apply_or_revert_hunk $cursorX $cursorY 1}
	set ui_diff_reverthunk [$ctxm index last]
	lappend diff_actions [list $ctxm entryconf $ui_diff_reverthunk -state]
	$ctxm add command \
		-label [mc "Revert Line"] \
		-command {apply_or_revert_range_or_line $cursorX $cursorY 1; do_rescan}
	set ui_diff_revertline [$ctxm index last]
	lappend diff_actions [list $ctxm entryconf $ui_diff_revertline -state]
	$ctxm add command \
		-label [mc "Undo Last Revert"] \
		-command {undo_last_revert; do_rescan}
	set ui_diff_undorevert [$ctxm index last]
	lappend diff_actions [list $ctxm entryconf $ui_diff_undorevert -state]
	$ctxm add separator
	$ctxm add command \
		-label [mc "Show Less Context"] \
		-command show_less_context
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add command \
		-label [mc "Show More Context"] \
		-command show_more_context
	lappend diff_actions [list $ctxm entryconf [$ctxm index last] -state]
	$ctxm add separator
	create_common_diff_popup $ctxm

	set ctxmmg $ui_diff.ctxmmg
	menu $ctxmmg -tearoff 0
	$ctxmmg add command \
		-label [mc "Run Merge Tool"] \
		-command {merge_resolve_tool}
	lappend diff_actions [list $ctxmmg entryconf [$ctxmmg index last] -state]
	$ctxmmg add separator
	$ctxmmg add command \
		-label [mc "Use Remote Version"] \
		-command {merge_resolve_one 3}
	lappend diff_actions [list $ctxmmg entryconf [$ctxmmg index last] -state]
	$ctxmmg add command \
		-label [mc "Use Local Version"] \
		-command {merge_resolve_one 2}
	lappend diff_actions [list $ctxmmg entryconf [$ctxmmg index last] -state]
	$ctxmmg add command \
		-label [mc "Revert To Base"] \
		-command {merge_resolve_one 1}
	lappend diff_actions [list $ctxmmg entryconf [$ctxmmg index last] -state]
	$ctxmmg add separator
	$ctxmmg add command \
		-label [mc "Show Less Context"] \
		-command show_less_context
	lappend diff_actions [list $ctxmmg entryconf [$ctxmmg index last] -state]
	$ctxmmg add command \
		-label [mc "Show More Context"] \
		-command show_more_context
	lappend diff_actions [list $ctxmmg entryconf [$ctxmmg index last] -state]
	$ctxmmg add separator
	create_common_diff_popup $ctxmmg

	set ctxmsm $ui_diff.ctxmsm
	menu $ctxmsm -tearoff 0
	$ctxmsm add command \
		-label [mc "Visualize These Changes In The Submodule"] \
		-command {do_gitk -- true}
	lappend diff_actions [list $ctxmsm entryconf [$ctxmsm index last] -state]
	$ctxmsm add command \
		-label [mc "Visualize Current Branch History In The Submodule"] \
		-command {do_gitk {} true}
	lappend diff_actions [list $ctxmsm entryconf [$ctxmsm index last] -state]
	$ctxmsm add command \
		-label [mc "Visualize All Branch History In The Submodule"] \
		-command {do_gitk --all true}
	lappend diff_actions [list $ctxmsm entryconf [$ctxmsm index last] -state]
	$ctxmsm add separator
	$ctxmsm add command \
		-label [mc "Start git gui In The Submodule"] \
		-command {do_git_gui}
	lappend diff_actions [list $ctxmsm entryconf [$ctxmsm index last] -state]
	$ctxmsm add separator
	create_common_diff_popup $ctxmsm
}
build_diff_menus

proc has_textconv {path} {
	if {[is_config_false gui.textconv]} {
		return 0
	}
	set filter [gitattr $path diff set]
	set textconv [get_config [join [list diff $filter textconv] .]]
	if {$filter ne {set} && $textconv ne {}} {
		return 1
	} else {
		return 0
	}
}

proc popup_diff_menu {ctxm ctxmmg ctxmsm x y X Y} {
	global current_diff_path file_states last_revert
	set ::cursorX $x
	set ::cursorY $y
	if {[info exists file_states($current_diff_path)]} {
		set state [lindex $file_states($current_diff_path) 0]
	} else {
		set state {__}
	}
	if {[string first {U} $state] >= 0} {
		tk_popup $ctxmmg $X $Y
	} elseif {$::is_submodule_diff} {
		tk_popup $ctxmsm $X $Y
	} else {
		set has_range [expr {[$::ui_diff tag nextrange sel 0.0] != {}}]
		set u [mc "Undo Last Revert"]
		if {$::ui_index eq $::current_diff_side} {
			set l [mc "Unstage Hunk From Commit"]
			set h [mc "Revert Hunk"]

			if {$has_range} {
				set t [mc "Unstage Lines From Commit"]
				set r [mc "Revert Lines"]
			} else {
				set t [mc "Unstage Line From Commit"]
				set r [mc "Revert Line"]
			}
		} else {
			set l [mc "Stage Hunk For Commit"]
			set h [mc "Revert Hunk"]

			if {$has_range} {
				set t [mc "Stage Lines For Commit"]
				set r [mc "Revert Lines"]
			} else {
				set t [mc "Stage Line For Commit"]
				set r [mc "Revert Line"]
			}
		}
		if {$::is_3way_diff
			|| $current_diff_path eq {}
			|| {__} eq $state
			|| {_O} eq $state
			|| [string match {?T} $state]
			|| [string match {T?} $state]
			|| [has_textconv $current_diff_path]} {
			set s disabled
			set revert_state disabled
		} else {
			set s normal

			# Only allow reverting changes in the working tree. If
			# the user wants to revert changes in the index, they
			# need to unstage those first.
			if {$::ui_workdir eq $::current_diff_side} {
				set revert_state normal
			} else {
				set revert_state disabled
			}
		}

		if {$last_revert eq {}} {
			set undo_state disabled
		} else {
			set undo_state normal
		}

		$ctxm entryconf $::ui_diff_applyhunk -state $s -label $l
		$ctxm entryconf $::ui_diff_applyline -state $s -label $t
		$ctxm entryconf $::ui_diff_revertline -state $revert_state \
			-label $r
		$ctxm entryconf $::ui_diff_reverthunk -state $revert_state \
			-label $h
		$ctxm entryconf $::ui_diff_undorevert -state $undo_state \
			-label $u

		tk_popup $ctxm $X $Y
	}
}
bind_button3 $ui_diff [list popup_diff_menu $ui_diff.ctxm $ui_diff.ctxmmg $ui_diff.ctxmsm %x %y %X %Y]
}
build_repo_ui .repotabs.repo0

# Map each notebook tab to its repoctx id, and on tab change swap the active
# repo context and cd to its worktree (git-gui runs git via the process cwd).
array set tab_ctx {}
set tab_ctx(.repotabs.repo0) [repoctx::current]
array set tab_path {}
set tab_path(.repotabs.repo0) [file normalize $_gitworktree]
# Monotonic tab-frame counter; never reused, so closing a tab can't collide with
# a later-opened one (widget names must stay unique under .repotabs).
set _repo_tab_seq 0

# Refresh HEAD/commit_type/branch for the ACTIVE repo. These are otherwise only
# restored from a context snapshot that can be stale -- e.g. saved as "initial"
# or with an empty PARENT before the repo's initial rescan finished when several
# repos open at once -- which made amend fail with "nothing to amend". An
# in-progress amend is left untouched so it is not lost.
proc refresh_commit_state {} {
	global commit_type HEAD PARENT MERGE_HEAD
	if {[string match amend* $commit_type]} return
	if {![catch {repository_state ct hd mh}]} {
		set HEAD $hd
		set PARENT $hd
		set MERGE_HEAD $mh
		set commit_type $ct
	}
}

proc refresh_active_commit_state {} {
	global commit_type commit_type_is_amend
	if {[string match amend* $commit_type]} {
		catch {load_current_branch}
	} else {
		refresh_commit_state
	}
	# Keep the amend checkbox in sync with this tab's commit_type.
	set commit_type_is_amend [string match amend* $commit_type]
}

# Set the main window title to the active repo (name + worktree path).
proc set_repo_window_title {} {
	catch {wm title . "[reponame] [file normalize $::_gitworktree]"}
}

proc on_repo_tab_changed {} {
	global tab_ctx repo_tab_pending
	repo_tab_refresh_groups
	set w [.repotabs select]
	if {$w ne {} && [info exists repo_tab_pending($w)]} {
		if {![repo_tab_initialize $w]} {
			foreach tab [.repotabs tabs] {
				if {[info exists tab_ctx($tab)] && $tab_ctx($tab) eq [repoctx::current]} {
					.repotabs select $tab
					break
				}
			}
		}
		return
	}
	if {$w eq {} || ![info exists tab_ctx($w)]} return
	if {[repoctx::current] eq $tab_ctx($w)} {
		save_repo_tab_session
		return
	}
	repoctx::use $tab_ctx($w)
	catch {cd [repoctx::field worktree]}
	# Refresh commit state (HEAD/commit_type/branch) for the now-active repo.
	catch {refresh_active_commit_state}
	catch {set_repo_window_title}
	catch {diff_map_update}
	catch {autosize_schedule [winfo parent [winfo parent $::ui_index]]}
	# repo_config is now the active repo's; rebuild the shared Tools menu so
	# per-repo guitools (e.g. includeIf gitdir entries) match the active tab.
	if {[info exists ::tools_menubar]} { tools_populate_all }
	save_repo_tab_session
}
bind .repotabs <<NotebookTabChanged>> on_repo_tab_changed
bind .repotabs <Button-2> {close_repo_tab_at %x %y; break}

proc repo_tab_list_worktrees {tab} {
	global tab_path
	if {![info exists tab_path($tab)]} return
	set path $tab_path($tab)
	if {[catch {set output [exec git -C $path worktree list]} err]} {
		error_popup [strcat [mc "Unable to list worktrees"] ":\n\n" $err]
		return
	}
	set rows {}
	set path_width [string length [mc "Worktree Path"]]
	set head_width [string length [mc "HEAD"]]
	foreach line [split $output "\n"] {
		if {$line eq {}} continue
		if {[regexp {^(.+)\s+([[:xdigit:]]{7,64})(?:\s+(.*))?$} \
			$line -> worktree head branch_state]} {
			if {[regexp {^\[([^\]]+)\](.*)$} $branch_state -> branch suffix]} {
				set branch_state "$branch$suffix"
			}
		} else {
			set worktree $line
			set head {}
			set branch_state {}
		}
		if {[is_Windows]} { set worktree [file nativename $worktree] }
		set path_width [expr {max($path_width, [string length $worktree])}]
		set head_width [expr {max($head_width, [string length $head])}]
		lappend rows [list $worktree $head $branch_state]
	}
	set row_format "%-*s  %-*s  %s"
	set header [format $row_format $path_width [mc "Worktree Path"] \
		$head_width [mc "HEAD"] [mc "Branch / State"]]
	set display_output [list $header [string repeat - [string length $header]]]
	foreach row $rows {
		lappend display_output [format $row_format $path_width \
			[lindex $row 0] $head_width [lindex $row 1] [lindex $row 2]]
	}
	repo_tab_show_worktrees $path [join $display_output "\n"] $rows
}

proc repo_tab_copy_worktrees_selection {widget} {
	if {[catch {set selection [$widget get sel.first sel.last]}]} return
	clipboard clear -displayof $widget
	clipboard append -displayof $widget $selection
}

proc repo_tab_select_worktree {widget x y rows button} {
	set index [$widget index @$x,$y]
	set row [expr {[lindex [split $index .] 0] - 3}]
	$widget mark set worktree_row $index
	if {$row >= 0 && $row < [llength $rows]} {
		$button configure -state normal
	} else {
		$button configure -state disabled
	}
}

proc repo_tab_open_worktree {widget rows} {
	global tab_path
	set row [expr {[lindex [split [$widget index worktree_row] .] 0] - 3}]
	if {$row < 0 || $row >= [llength $rows]} return
	set path [lindex [lindex $rows $row] 0]
	if {![file isdirectory $path]} {
		error_popup [mc "Worktree directory does not exist: %s" $path]
		return
	}
	set path [file normalize $path]
	foreach tab [.repotabs tabs] {
		if {![info exists tab_path($tab)]} continue
		if {$tab_path($tab) eq $path ||
			([is_Windows] && [string equal -nocase $tab_path($tab) $path])} {
			.repotabs select $tab
			return
		}
	}
	open_repo_context $path
}

proc repo_tab_show_worktrees {path output rows} {
	set w .repo_worktrees
	if {[winfo exists $w]} { destroy $w }
	toplevel $w
	if {[is_Windows]} { set path [file nativename $path] }
	wm title $w [mc "Worktrees for %s" $path]
	wm geometry $w 960x360
	wm minsize $w 640 240

	ttk::frame $w.contents
	text $w.contents.output \
		-background white \
		-foreground black \
		-borderwidth 1 \
		-relief sunken \
		-width 110 -height 14 \
		-wrap none \
		-exportselection 0 \
		-font font_diff \
		-xscrollcommand [list $w.contents.sbx set] \
		-yscrollcommand [list $w.contents.sby set]
	ttk::scrollbar $w.contents.sbx -orient horizontal \
		-command [list $w.contents.output xview]
	ttk::scrollbar $w.contents.sby -orient vertical \
		-command [list $w.contents.output yview]
	pack $w.contents.sby -side right -fill y
	pack $w.contents.sbx -side bottom -fill x
	pack $w.contents.output -side left -fill both -expand 1
	$w.contents.output insert 1.0 $output
	$w.contents.output configure -state disabled
	bind $w.contents.output <<Copy>> \
		"[list repo_tab_copy_worktrees_selection $w.contents.output]\nbreak"

	ttk::frame $w.buttons
	ttk::button $w.buttons.open \
		-text [mc "Open Worktree"] \
		-state disabled \
		-command [list repo_tab_open_worktree $w.contents.output $rows]
	ttk::button $w.buttons.browse \
		-text [mc "Open Repository..."] \
		-command do_open_repo_tab
	bind $w.contents.output <ButtonRelease-1> \
		[list repo_tab_select_worktree %W %x %y $rows $w.buttons.open]
	ttk::button $w.buttons.copy \
		-text [mc "Copy Selection"] \
		-command [list repo_tab_copy_worktrees_selection $w.contents.output]
	ttk::button $w.buttons.close \
		-text [mc "Close"] \
		-command [list destroy $w]
	pack $w.buttons.close -side right -padx 8 -pady 8
	pack $w.buttons.copy -side right -padx 8 -pady 8
	pack $w.buttons.open -side left -padx 8 -pady 8
	pack $w.buttons.browse -side left -padx 8 -pady 8
	pack $w.contents -side top -fill both -expand 1 -padx 8 -pady 8
	pack $w.buttons -side bottom -fill x

	wm protocol $w WM_DELETE_WINDOW [list destroy $w]
	bind $w <Escape> [list destroy $w]
	wm transient $w .
	wm deiconify $w
	raise $w
	focus $w.contents.output
}

proc repo_tab_right_click {x y} {
	repo_tab_hide_tooltip
	if {[catch {.repotabs index @$x,$y} idx]} return
	set tab [lindex [.repotabs tabs] $idx]
	if {$tab eq {}} return
	repo_tab_list_worktrees $tab
}
bind .repotabs <Button-3> [list repo_tab_right_click %x %y]
if {[is_MacOSX]} {
	bind .repotabs <Control-Button-1> [list repo_tab_right_click %x %y]
}

# Ctrl-Tab / Ctrl-Shift-Tab cycle through the repository tabs (built-in ttk).
ttk::notebook::enableTraversal .repotabs

# Reorder tabs by dragging within the tab strip: remember the tab the drag
# started on, and as the pointer moves over a different tab position, move the
# dragged tab there via the notebook's insert.
set _repo_tab_drag {}
proc repo_tab_drag_press {x y} {
	global _repo_tab_drag
	repo_tab_hide_tooltip
	set _repo_tab_drag {}
	if {[repo_tab_toggle_at $x $y]} { return -code break }
	catch {set _repo_tab_drag [.repotabs index @$x,$y]}
}
proc repo_tab_drag_motion {x y} {
	global _repo_tab_drag
	if {$_repo_tab_drag eq {}} return
	if {[catch {.repotabs index @$x,$y} idx]} return
	if {$idx eq $_repo_tab_drag} return
	catch {.repotabs insert $idx [lindex [.repotabs tabs] $_repo_tab_drag]}
	set _repo_tab_drag $idx
}
proc repo_tab_drag_release {} {
	global _repo_tab_drag
	set _repo_tab_drag {}
	repo_tab_refresh_groups
	save_repo_tab_session
}
bind .repotabs <ButtonPress-1>   {repo_tab_drag_press %x %y}
bind .repotabs <B1-Motion>       {repo_tab_drag_motion %x %y}
bind .repotabs <ButtonRelease-1> {repo_tab_drag_release}

# Record $wt as the most-recent repository without duplicating: drop any prior
# entry for the same path, append it, then trim to gui.maxrecentrepo. Operates
# directly on git config so it never disturbs the active repo context (unlike
# the chooser's _append_recentrepos, which reloads config).
proc _record_recent_repo {wt} {
	set wt [file normalize $wt]
	set re $wt
	regsub -all -- {([()\[\]{}\.^$+*?\\])} $re {\\\1} re
	catch {exec git config --global --unset-all gui.recentrepo "^$re\$"}
	catch {exec git config --global --add gui.recentrepo $wt}
	if {[catch {set maxrecent [exec git config --get gui.maxrecentrepo]}]} {
		set maxrecent 10
	}
	if {![string is integer -strict $maxrecent] || $maxrecent <= 0} return
	if {[catch {set recent [exec git config --global --get-all gui.recentrepo]}]} return
	set recent [split $recent "\n"]
	while {[llength $recent] > $maxrecent} {
		set old [lindex $recent 0]
		set ore $old
		regsub -all -- {([()\[\]{}\.^$+*?\\])} $ore {\\\1} ore
		catch {exec git config --global --unset-all gui.recentrepo "^$ore\$"}
		set recent [lrange $recent 1 end]
	}
}

proc save_repo_tab_session {} {
	global global_config tab_path
	if {![info exists global_config(gui.restoretabs)]} return
	set enabled [string tolower $global_config(gui.restoretabs)]
	set enabled [expr {$enabled eq {} || $enabled in {true 1 yes on}}]
	if {!$enabled} {
		catch {exec git config --global --unset-all gui.sessionrepo}
		catch {exec git config --global --unset gui.sessionactive}
		return
	}

	catch {exec git config --global --unset-all gui.sessionrepo}
	foreach w [.repotabs tabs] {
		if {![info exists tab_path($w)] || $tab_path($w) eq {}} continue
		catch {exec git config --global --add gui.sessionrepo $tab_path($w)}
	}
	set selected [.repotabs select]
	if {$selected ne {} && [info exists tab_path($selected)]} {
		catch {exec git config --global gui.sessionactive $tab_path($selected)}
	}
}

proc select_repo_tab_by_path {path} {
	global tab_path
	if {$path eq {}} return
	foreach w [.repotabs tabs] {
		if {[info exists tab_path($w)] && $tab_path($w) eq $path} {
			.repotabs select $w
			return
		}
	}
}

# Open another repository in a new tab: discover its git dirs, register a fresh
# repoctx, build its UI under a new tab, load its config, and rescan.
proc repo_tab_restore {path} {
	global tab_path repo_tab_pending
	set path [file normalize $path]
	foreach tab [.repotabs tabs] {
		if {[info exists tab_path($tab)] &&
			([string equal $tab_path($tab) $path] ||
			([is_Windows] && [string equal -nocase $tab_path($tab) $path]))} { return }
	}
	set gitdir [file join $path .git]
	if {[file isfile $gitdir]} {
		if {[catch {
			set gitfile [open $gitdir r]
			try {
				set contents [string trim [read $gitfile 4096]]
			} finally { close $gitfile }
			if {![regexp {^gitdir: (.+)$} $contents -> target]} { error "Invalid gitdir file" }
			set gitdir [file normalize [file join $path $target]]
		}]} return
	}
	if {![file isdirectory $gitdir]} return
	set tab .repotabs.repo[incr ::_repo_tab_seq]
	ttk::frame $tab
	set tab_path($tab) $path
	set repo_tab_pending($tab) $path
	repo_tab_add $tab $gitdir $path [file tail $path]
}

proc repo_tab_schedule_load {} {
	global repo_tab_load_queue repo_tab_load_timer
	if {$repo_tab_load_timer eq {} && [llength $repo_tab_load_queue] > 0} {
		set repo_tab_load_timer [after 300 repo_tab_background_next]
	}
}

proc repo_tab_queue_load {tab {priority 0}} {
	global repo_tab_load_queue
	set repo_tab_load_queue [lsearch -all -inline -not -exact $repo_tab_load_queue $tab]
	if {$priority} {
		set repo_tab_load_queue [linsert $repo_tab_load_queue 0 $tab]
	} else {
		lappend repo_tab_load_queue $tab
	}
	repo_tab_schedule_load
}

proc repo_tab_request_scan {tab} {
	global repo_tab_load_queue rescan_active rescan_all_active index_lock_type
	if {$rescan_active > 0 || $rescan_all_active || $index_lock_type ne "none"} {
		repo_tab_queue_load $tab 1
		return
	}
	set repo_tab_load_queue [lsearch -all -inline -not -exact $repo_tab_load_queue $tab]
	do_rescan
}

proc repo_tab_background_next {} {
	global repo_tab_load_queue repo_tab_load_timer repo_tab_pending tab_ctx
	global rescan_active rescan_owner rescan_all_active index_lock_type
	set repo_tab_load_timer {}
	if {![winfo exists .repotabs]} { set repo_tab_load_queue {}; return }
	if {$rescan_active > 0 && $rescan_owner ne {} &&
		[lsearch -exact [repoctx::ids] $rescan_owner] < 0} {
		set rescan_active 0
		set rescan_owner {}
		catch {unlock_index}
	}
	if {$rescan_active > 0 || $rescan_all_active || $index_lock_type ne "none"} {
		repo_tab_schedule_load
		return
	}
	set selected [.repotabs select]
	if {[lsearch -exact $repo_tab_load_queue $selected] >= 0} {
		set repo_tab_load_queue [linsert \
			[lsearch -all -inline -not -exact $repo_tab_load_queue $selected] 0 $selected]
	}
	while {[llength $repo_tab_load_queue] > 0} {
		set tab [lindex $repo_tab_load_queue 0]
		set repo_tab_load_queue [lrange $repo_tab_load_queue 1 end]
		if {![winfo exists $tab]} continue
		set previous [repoctx::current]
		set previous_dir [pwd]
		try {
			if {[info exists repo_tab_pending($tab)] && ![repo_tab_initialize $tab 0 1]} continue
			if {![info exists tab_ctx($tab)]} continue
			repoctx::use $tab_ctx($tab)
			cd [repoctx::field worktree]
			if {$tab eq [.repotabs select]} {
				do_rescan
			} else {
				rescan {}
			}
		} on error {message options} {
			if {$rescan_active == 0} { catch {unlock_index} }
		} finally {
			if {$previous ne {} && [lsearch -exact [repoctx::ids] $previous] >= 0} {
				repoctx::use $previous
			}
			catch {cd $previous_dir}
		}
		break
	}
	repo_tab_schedule_load
}

proc repo_tab_initialize {tab {scan 1} {quiet 0}} {
	global repo_tab_pending tab_ctx disable_on_lock
	if {![info exists repo_tab_pending($tab)]} { return [info exists tab_ctx($tab)] }
	set path $repo_tab_pending($tab)
	set previous [repoctx::current]
	set previous_ids [repoctx::ids]
	set previous_dir [pwd]
	unset repo_tab_pending($tab)
	set initialized 0
	set failed [catch {set initialized [open_repo_context $path $tab $scan]} message]
	if {$failed || !$initialized} {
		set failed_context [repoctx::current]
		if {$previous ne {} && [lsearch -exact [repoctx::ids] $previous] >= 0} {
			repoctx::reload $previous
		}
		if {$failed_context ne {} && [lsearch -exact $previous_ids $failed_context] < 0} {
			repoctx::forget $failed_context
		}
		catch {cd $previous_dir}
		foreach child [winfo children $tab] { destroy $child }
		unset -nocomplain tab_ctx($tab)
		set kept {}
		foreach entry $disable_on_lock {
			if {![string match $tab.* [lindex $entry 0]]} { lappend kept $entry }
		}
		set disable_on_lock $kept
		set repo_tab_pending($tab) $path
		if {!$failed} { set message [mc "Unable to open repository: %s" $path] }
		if {!$quiet} { error_popup $message }
		return 0
	}
	return 1
}

proc open_repo_context {path {w {}} {scan 1}} {
	global tab_ctx tab_path env
	set save [pwd]
	# git-gui pins the active repo via GIT_DIR/GIT_WORK_TREE env vars, which
	# override cwd. Clear them so discovery honors the chosen directory; the
	# fresh context's _load will set them to the new repo.
	set restore_env [dict create]
	foreach variable {GIT_DIR GIT_WORK_TREE} {
		if {[info exists env($variable)]} {
			dict set restore_env $variable $env($variable)
			unset env($variable)
		}
	}
	try {
		if {[catch {cd $path}]} { return 0 }
		if {[catch {set gd [git rev-parse --git-dir]}]} { return 0 }
		set gd [file normalize $gd]
		set wt {}
		catch {set wt [string trim [git rev-parse --show-toplevel]]}
		if {$wt eq {}} { set wt [file normalize $path] }
		set pfx {}
		catch {set pfx [string trim [git rev-parse --show-prefix]]}
	} finally {
		cd $save
		foreach variable {GIT_DIR GIT_WORK_TREE} { unset -nocomplain env($variable) }
		dict for {variable value} $restore_env { set env($variable) $value }
	}
	set rn [file tail $wt]
	_record_recent_repo $wt

	if {$w eq {}} {
		set w .repotabs.repo[incr ::_repo_tab_seq]
		ttk::frame $w
		repo_tab_add $w $gd $wt $rn
	}

	repoctx::open_context $gd $wt $rn $pfx
	cd $wt
	load_config 0
	# Set the branch synchronously so this context saves the correct value when
	# switched away from, before its async do_rescan below completes.
	catch {load_current_branch}
	# apply_config does one-time global theming (fonts/theme/pave_toplevel)
	# already done at startup; for an extra repo we only need its comment char.
	set ::comment_string [get_config core.commentstring]
	if {$::comment_string eq {}} {
		set ::comment_string [get_config core.commentchar]
	}
	build_repo_ui $w
	set tab_ctx($w) [repoctx::current]
	set tab_path($w) [file normalize $wt]

	if {!$scan} { return 1 }
	.repotabs select $w
	# The tab-changed handler short-circuits when the new tab is already the
	# active context, so populate this repo's Tools menu and title explicitly.
	if {[info exists ::tools_menubar]} { tools_populate_all }
	catch {set_repo_window_title}
	repo_tab_request_scan $w
	save_repo_tab_session
	return 1
}

proc do_open_repo_tab {} {
	set p [tk_chooseDirectory -title [mc "Open Repository In New Tab"] -mustexist 1]
	if {$p ne {}} { open_repo_context $p }
}

# Existing repositories from the global recent list (deduped, still present),
# newest first and capped at gui.maxrecentrepo (Edit > Options).
proc recent_repo_paths {} {
	set r {}
	catch {set r [get_config gui.recentrepo]}
	if {$r eq {}} {
		catch {set r [split [string trim \
			[exec git config --global --get-all gui.recentrepo]] "\n"]}
	}
	if {[set maxrecent [get_config gui.maxrecentrepo]] eq {}} {
		set maxrecent 10
	}
	set out {}
	# git config lists oldest first; walk newest first and dedupe by first seen.
	foreach p [lreverse $r] {
		if {$p eq {} || [lsearch -exact $out $p] >= 0} continue
		if {![file isdirectory $p]} continue
		lappend out $p
		if {$maxrecent > 0 && [llength $out] >= $maxrecent} break
	}
	return $out
}

proc populate_recent_tab_menu {} {
	set m .mbar.repository.recent
	$m delete 0 end
	set recent [recent_repo_paths]
	if {[llength $recent] == 0} {
		$m add command -label [mc "(no recent repositories)"] -state disabled
		return
	}
	foreach p $recent {
		$m add command -label $p -command [list open_repo_context $p]
	}
}

# Close the active repository tab (quit if it is the last one).
proc close_repo_tab_widget {w} {
	global tab_ctx repo_tab_family repo_tab_pending tab_path
	repo_tab_hide_tooltip
	if {$w eq {}} return
	if {[llength [.repotabs tabs]] <= 1} { do_quit ; return }
	set ctx {}
	catch {set ctx $tab_ctx($w)}
	set closing_active [expr {[.repotabs select] eq $w}]
	set scan_survivor 0

	if {$closing_active} {
		# Pick the tab to activate after this closes (next one, else previous).
		set tabs [.repotabs tabs]
		set idx [lsearch -exact $tabs $w]
		set rest [lreplace $tabs $idx $idx]
		if {$idx < [llength $rest]} {
			set stab [lindex $rest $idx]
		} else {
			set stab [lindex $rest end]
		}
		if {[info exists repo_tab_pending($stab)]} {
			if {![repo_tab_initialize $stab 0]} return
			set scan_survivor 1
		}
		.repotabs tab $stab -state normal
		# Activate the survivor's context BEFORE destroying this tab. The
		# closing repo's widgets are about to vanish, so load the survivor
		# without saving the outgoing (now-invalid) globals back into any
		# context.
		if {$stab ne {} && [info exists tab_ctx($stab)]} {
			repoctx::reload $tab_ctx($stab)
			catch {cd [repoctx::field worktree]}
		}
	}

	unset -nocomplain tab_ctx($w)
	unset -nocomplain repo_tab_family($w)
	unset -nocomplain repo_tab_pending($w) tab_path($w)
	.repotabs forget $w
	destroy $w
	if {$ctx ne {}} { repoctx::forget $ctx }

	# Drop this tab's widgets from the index-lock list so a later lock_index
	# never touches the destroyed widgets.
	global disable_on_lock
	set kept {}
	foreach e $disable_on_lock {
		if {[string match $w.* [lindex $e 0]]} continue
		lappend kept $e
	}
	set disable_on_lock $kept

	if {$closing_active} {
		catch {.repotabs select $stab}
		catch {refresh_active_commit_state}
		catch {set_repo_window_title}
		if {[info exists ::tools_menubar]} { tools_populate_all }
		if {$scan_survivor} { repo_tab_request_scan $stab }
	}
	repo_tab_refresh_groups
	save_repo_tab_session
}

proc close_repo_tab {} { close_repo_tab_widget [.repotabs select] }

proc close_repo_tab_at {x y} {
	if {[catch {.repotabs index @$x,$y} idx]} return
	close_repo_tab_widget [lindex [.repotabs tabs] $idx]
}

# -- Status Bar
#
set main_status [::status_bar::new .status]
pack .status -anchor w -side bottom -fill x
$main_status show [mc "Initializing..."]

# -- Load geometry
#
proc on_ttk_pane_mapped {w pane pos} {
	bind $w <Map> {}
	after 0 [list after idle [list $w sashpos $pane $pos]]
}
proc on_application_mapped {} {
	global repo_config
	bind . <Map> {}
	set gm $repo_config(gui.geometry)
	bind $::ui_vpane <Map> \
		[list on_ttk_pane_mapped %W 0 [lindex $gm 1]]
	bind $::ui_vpane_files <Map> \
		[list on_ttk_pane_mapped %W 0 [lindex $gm 2]]
	wm geometry . [lindex $gm 0]
}
if {[info exists repo_config(gui.geometry)]} {
	bind . <Map> [list on_application_mapped]
	wm geometry . [lindex $repo_config(gui.geometry) 0]
}

# -- Load window state
#
if {[info exists repo_config(gui.wmstate)]} {
	catch {wm state . $repo_config(gui.wmstate)}
}

# -- Key Bindings
#
bind $ui_comm <$M1B-Key-Return> {do_commit;break}
bind $ui_comm <$M1B-Key-t> {do_add_selection;break}
bind $ui_comm <$M1B-Key-T> {do_add_selection;break}
bind $ui_comm <$M1B-Key-u> {do_unstage_selection;break}
bind $ui_comm <$M1B-Key-U> {do_unstage_selection;break}
bind $ui_comm <$M1B-Key-j> {do_revert_selection;break}
bind $ui_comm <$M1B-Key-J> {do_revert_selection;break}
bind $ui_comm <$M1B-Key-i> {do_add_all;break}
bind $ui_comm <$M1B-Key-I> {do_add_all;break}
bind $ui_comm <$M1B-Key-x> {tk_textCut %W;break}
bind $ui_comm <$M1B-Key-X> {tk_textCut %W;break}
bind $ui_comm <$M1B-Key-c> {tk_textCopy %W;break}
bind $ui_comm <$M1B-Key-C> {tk_textCopy %W;break}
bind $ui_comm <$M1B-Key-v> {tk_textPaste %W; %W see insert; break}
bind $ui_comm <$M1B-Key-V> {tk_textPaste %W; %W see insert; break}
bind $ui_comm <$M1B-Key-a> {%W tag add sel 0.0 end;break}
bind $ui_comm <$M1B-Key-A> {%W tag add sel 0.0 end;break}
bind $ui_comm <$M1B-Key-minus> {show_less_context;break}
bind $ui_comm <$M1B-Key-KP_Subtract> {show_less_context;break}
bind $ui_comm <$M1B-Key-equal> {show_more_context;break}
bind $ui_comm <$M1B-Key-plus> {show_more_context;break}
bind $ui_comm <$M1B-Key-KP_Add> {show_more_context;break}
bind $ui_comm <$M1B-Key-BackSpace> {event generate %W <Meta-Delete>;break}
bind $ui_comm <$M1B-Key-Delete> {event generate %W <Meta-d>;break}

bind $ui_diff <$M1B-Key-x> {tk_textCopy %W;break}
bind $ui_diff <$M1B-Key-X> {tk_textCopy %W;break}
bind $ui_diff <$M1B-Key-c> {tk_textCopy %W;break}
bind $ui_diff <$M1B-Key-C> {tk_textCopy %W;break}
bind $ui_diff <$M1B-Key-v> {break}
bind $ui_diff <$M1B-Key-V> {break}
bind $ui_diff <$M1B-Key-a> {%W tag add sel 0.0 end;break}
bind $ui_diff <$M1B-Key-A> {%W tag add sel 0.0 end;break}
bind $ui_diff <$M1B-Key-j> {do_revert_selection;break}
bind $ui_diff <$M1B-Key-J> {do_revert_selection;break}
bind $ui_diff <Key-Up>     {catch {%W yview scroll -1 units};break}
bind $ui_diff <Key-Down>   {catch {%W yview scroll  1 units};break}
bind $ui_diff <Key-Left>   {catch {%W xview scroll -1 units};break}
bind $ui_diff <Key-Right>  {catch {%W xview scroll  1 units};break}
bind $ui_diff <Key-k>         {catch {%W yview scroll -1 units};break}
bind $ui_diff <Key-j>         {catch {%W yview scroll  1 units};break}
bind $ui_diff <Key-h>         {catch {%W xview scroll -1 units};break}
bind $ui_diff <Key-l>         {catch {%W xview scroll  1 units};break}
bind $ui_diff <Control-Key-b> {catch {%W yview scroll -1 pages};break}
bind $ui_diff <Button-1>   {focus %W}

if {[is_enabled branch]} {
	bind . <$M1B-Key-n> branch_create::dialog
	bind . <$M1B-Key-N> branch_create::dialog
	bind . <$M1B-Key-o> branch_checkout::dialog
	bind . <$M1B-Key-O> branch_checkout::dialog
	bind . <$M1B-Key-m> merge::dialog
	bind . <$M1B-Key-M> merge::dialog
}
if {[is_enabled transport]} {
	bind . <$M1B-Key-p> do_push_anywhere
	bind . <$M1B-Key-P> do_push_anywhere
}

bind .   <Key-F5>     ui_do_rescan
bind .   <Shift-Key-F5> do_rescan_all
bind .   <$M1B-Key-r> ui_do_rescan
bind .   <$M1B-Key-R> ui_do_rescan
bind .   <$M1B-Key-s> do_signoff
bind .   <$M1B-Key-S> do_signoff
bind .   <$M1B-Key-t> { toggle_or_diff toggle %W }
bind .   <$M1B-Key-T> { toggle_or_diff toggle %W }
bind .   <$M1B-Key-u> { toggle_or_diff toggle %W }
bind .   <$M1B-Key-U> { toggle_or_diff toggle %W }
bind .   <$M1B-Key-j> do_revert_selection
bind .   <$M1B-Key-J> do_revert_selection
bind .   <$M1B-Key-i> do_add_all
bind .   <$M1B-Key-I> do_add_all
bind .   <$M1B-Key-e> toggle_commit_type
bind .   <$M1B-Key-E> toggle_commit_type
bind .   <$M1B-Key-minus> {show_less_context;break}
bind .   <$M1B-Key-KP_Subtract> {show_less_context;break}
bind .   <$M1B-Key-equal> {show_more_context;break}
bind .   <$M1B-Key-plus> {show_more_context;break}
bind .   <$M1B-Key-KP_Add> {show_more_context;break}
bind .   <Key-F3>       {diff_goto_change 1}
bind .   <Shift-Key-F3> {diff_goto_change -1}
bind .   <Key-F7>       diff_show_finder
bind .   <$M1B-Key-Return> do_commit
bind .   <$M1B-Key-KP_Enter> do_commit

bind .   <Alt-Key-1> {focus_widget $::ui_workdir}
bind .   <Alt-Key-2> {focus_widget $::ui_index}
bind .   <Alt-Key-3> {focus $::ui_diff}
bind .   <Alt-Key-4> {focus $::ui_comm}

catch {diff_map_update}

set_repo_window_title
focus -force $ui_comm

# -- Only initialize complex UI if we are going to stay running.
#
if {[is_enabled transport]} {
	load_all_remotes

	set n [.mbar.remote index end]
	populate_remotes_menu
	set n [expr {[.mbar.remote index end] - $n}]
	if {$n > 0} {
		if {[.mbar.remote type 0] eq "tearoff"} { incr n }
		.mbar.remote insert $n separator
	}
	unset n
}

if {[winfo exists $ui_comm]} {
	set GITGUI_BCK_exists [load_message GITGUI_BCK utf-8]

	# -- If both our backup and message files exist use the
	#    newer of the two files to initialize the buffer.
	#
	if {$GITGUI_BCK_exists} {
		set m [gitdir GITGUI_MSG]
		if {[file isfile $m]} {
			if {[file mtime [gitdir GITGUI_BCK]] > [file mtime $m]} {
				catch {file delete [gitdir GITGUI_MSG]}
			} else {
				$ui_comm delete 0.0 end
				$ui_comm edit reset
				$ui_comm edit modified false
				catch {file delete [gitdir GITGUI_BCK]}
				set GITGUI_BCK_exists 0
			}
		}
		unset m
	}

	proc backup_commit_buffer {} {
		global ui_comm GITGUI_BCK_exists

		if {$ui_comm eq {} || ![winfo exists $ui_comm]} return
		set m [$ui_comm edit modified]
		if {$m || $GITGUI_BCK_exists} {
			set msg [string trim [$ui_comm get 0.0 end]]
			regsub -all -line {[ \r\t]+$} $msg {} msg

			if {$msg eq {}} {
				if {$GITGUI_BCK_exists} {
					catch {file delete [gitdir GITGUI_BCK]}
					set GITGUI_BCK_exists 0
				}
			} elseif {$m} {
				catch {
					set fd [safe_open_file [gitdir GITGUI_BCK] w]
					fconfigure $fd -encoding utf-8
					puts -nonewline $fd $msg
					close $fd
					set GITGUI_BCK_exists 1
				}
			}

			$ui_comm edit modified false
		}

		set ::GITGUI_BCK_i [after 2000 backup_commit_buffer]
	}

	backup_commit_buffer

	# Grey out comment lines (which are stripped from the final commit message by
	# wash_commit_message).
	$ui_comm tag configure commit_comment -foreground gray
	proc dim_commit_comment_lines {} {
		global ui_comm comment_string
		$ui_comm tag remove commit_comment 1.0 end
		set text [$ui_comm get 1.0 end]
		# See also cmt_rx in wash_commit_message
		set cmt_rx [strcat {^} [regsub -all {\W} $comment_string {\\&}]]
		set ranges [regexp -all -indices -inline -line -- $cmt_rx $text]
		foreach pair $ranges {
			set idx "1.0 + [lindex $pair 0] chars"
			$ui_comm tag add commit_comment $idx "$idx lineend + 1 char"
		}
	}
	dim_commit_comment_lines
	bind $ui_comm <<Modified>> { after idle dim_commit_comment_lines }

	# -- If the user has aspell available we can drive it
	#    in pipe mode to spellcheck the commit message.
	#
	set spell_cmd [list |]
	set spell_dict [get_config gui.spellingdictionary]
	lappend spell_cmd aspell
	if {$spell_dict ne {}} {
		lappend spell_cmd --master=$spell_dict
	}
	lappend spell_cmd --mode=none
	lappend spell_cmd --encoding=utf-8
	lappend spell_cmd pipe
	if {$spell_dict eq {none}
	 || [catch {set spell_fd [open $spell_cmd r+]} spell_err]} {
		bind_button3 $ui_comm [list tk_popup $ui_comm_ctxm %X %Y]
	} else {
		set ui_comm_spell [spellcheck::init \
			$spell_fd \
			$ui_comm \
			$ui_comm_ctxm \
		]
	}
	unset -nocomplain spell_cmd spell_fd spell_err spell_dict
}

lock_index begin-read
if {![winfo ismapped .]} {
	wm deiconify .
}
after 1 {
	if {[is_enabled initialamend]} {
		force_amend
	} else {
		do_rescan
	}

	if {[is_enabled nocommitmsg]} {
		$ui_comm configure -state disabled -background gray
	}
}
if {[is_enabled multicommit] && ![is_config_false gui.gcwarning]} {
	after 1000 hint_gc
}
if {[is_enabled retcode]} {
	bind . <Destroy> {+terminate_me %W}
}
if {$picked && [is_config_true gui.autoexplore]} {
	do_explore
}

# Clear "Initializing..." status
after 500 {$main_status show ""}

# Open any additional repositories passed on the command line as extra tabs, one
# at a time: rescans are serialized, so opening them all at once would leave the
# later repos un-scanned. Wait for the current rescan to finish before each open.
proc open_repos_sequentially {paths {select_path {}}} {
	global rescan_active
	if {[llength $paths] == 0} {
		select_repo_tab_by_path $select_path
		save_repo_tab_session
		return
	}
	if {$rescan_active > 0} {
		after 100 [list open_repos_sequentially $paths $select_path]
		return
	}
	open_repo_context [lindex $paths 0]
	after 100 [list open_repos_sequentially \
		[lrange $paths 1 end] $select_path]
}
proc restore_repo_tabs {paths select_path} {
	global repo_tab_pending
	foreach path $paths { repo_tab_restore $path }
	select_repo_tab_by_path $select_path
	foreach tab [.repotabs tabs] {
		if {[info exists repo_tab_pending($tab)]} { repo_tab_queue_load $tab }
	}
	save_repo_tab_session
}
set _rest {}
if {[info exists _multi_repo_paths]} {
	set _rest [lrange $_multi_repo_paths 1 end]
	set _restore_active_repo {}
}
set _startup_repo_path [file normalize $_gitworktree]
set _session_rest {}
foreach _session_path $_restore_repo_paths {
	if {$_session_path eq $_startup_repo_path
		|| [lsearch -exact $_rest $_session_path] >= 0} continue
	lappend _session_rest $_session_path
}
after idle [list restore_repo_tabs $_session_rest $_restore_active_repo]
if {[llength $_rest] > 0} {
	after idle [list open_repos_sequentially $_rest $_restore_active_repo]
}

# Local variables:
# mode: tcl
# indent-tabs-mode: t
# tab-width: 4
# End:
