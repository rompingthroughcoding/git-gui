# repoctx.tcl -- per-repo context scaffolding (multi-repo fork spike)
#
# Proof-of-concept for a git-gui fork where multi-repo is a first-class feature:
# instead of one process per repository glued together by the master hub, a
# single process holds several repositories, each with its own state.
#
# Rewriting git-gui's hundreds of `global HEAD` / `global current_diff_path`
# sites into accessor calls is impractical, so this context uses a
# *context-swap* model: the singleton globals hold the ACTIVE repo's state, and
# each context stores a snapshot of them. Switching context saves the outgoing
# repo's globals back into its context and restores the incoming one's, so
# subsystem code keeps reading/writing the globals unchanged.
#
# `managed` lists the globals that belong to a repository. This spike covers
# repo identity (gitdir/worktree/reponame/prefix) plus the first live example,
# current_diff_path; a real fork would extend it with HEAD, PARENT, commit_type,
# file_states, etc. See the GITGUI_CTX_SELFTEST self-test in git-gui.sh.

namespace eval repoctx {
	variable contexts       ;# id -> dict of managed-global snapshots
	array set contexts {}
	variable order   {}     ;# registration order of ids
	variable current {}     ;# active context id
	variable seq     0
	# Scalar globals that hold the active repo's state; swapped on switch.
	# Includes the ui_* widget-path globals: once each repo's widgets are built
	# under its own tab frame, swapping these paths redirects all the lib code
	# (which references widgets via these globals) to the active repo's tree.
	variable managed {_gitdir _gitworktree _reponame _prefix \
		current_diff_path HEAD PARENT MERGE_HEAD commit_type current_branch \
		ui_index ui_workdir ui_diff ui_comm ui_diff_ln ui_diff_hdr \
		ui_coml ui_comm_ctxm}
	# Array globals swapped on switch (need array get/set rather than set).
	variable managed_arrays {file_states}
}

# Register a repository's identity as a new context and make it current.
# Returns the new context id.
proc repoctx::register {gitdir worktree reponame prefix} {
	variable contexts
	variable order
	variable seq
	variable managed
	variable managed_arrays
	set id ctx[incr seq]
	# Seed every managed global empty so a fresh context starts clean, then
	# overlay this repo's identity.
	set d [dict create]
	foreach v $managed        { dict set d $v {} }
	foreach v $managed_arrays { dict set d $v {} }
	dict set d _gitdir      $gitdir
	dict set d _gitworktree $worktree
	dict set d _reponame    $reponame
	dict set d _prefix      $prefix
	set contexts($id) $d
	lappend order $id
	use $id
	return $id
}

# Save the active repo's managed globals back into context $id.
proc repoctx::_save {id} {
	variable contexts
	variable managed
	variable managed_arrays
	if {![info exists contexts($id)]} return
	foreach v $managed {
		if {[info exists ::$v]} { dict set contexts($id) $v [set ::$v] }
	}
	foreach v $managed_arrays {
		if {[array exists ::$v]} { dict set contexts($id) $v [array get ::$v] }
	}
}

# Restore context $id's managed globals into the live singletons.
proc repoctx::_load {id} {
	variable contexts
	variable managed
	variable managed_arrays
	foreach v $managed {
		if {[dict exists $contexts($id) $v]} { set ::$v [dict get $contexts($id) $v] }
	}
	foreach v $managed_arrays {
		if {[dict exists $contexts($id) $v]} {
			array unset ::$v
			array set ::$v [dict get $contexts($id) $v]
		}
	}
}

# Switch the active context: snapshot the outgoing repo, restore the incoming.
proc repoctx::use {id} {
	variable contexts
	variable current
	if {![info exists contexts($id)]} { error "repoctx: unknown context $id" }
	if {$current ne {} && $current ne $id} { _save $current }
	set current $id
	_load $id
	return $id
}

proc repoctx::current {} {
	variable current
	return $current
}

proc repoctx::ids {} {
	variable order
	return $order
}

proc repoctx::forget {id} {
	variable contexts
	variable order
	variable current
	unset -nocomplain contexts($id)
	set order [lsearch -all -inline -not -exact $order $id]
	if {$current eq $id} { set current [lindex $order end] }
}

# Read an identity field from the active context (used by the gitdir/reponame
# accessors). Falls back to the live global before any context is registered.
proc repoctx::field {key} {
	variable contexts
	variable current
	set gk [dict get {gitdir _gitdir worktree _gitworktree \
		reponame _reponame prefix _prefix} $key]
	if {$current ne {} && [info exists contexts($current)]
	 && [dict exists $contexts($current) $gk]} {
		return [dict get $contexts($current) $gk]
	}
	return [expr {[info exists ::$gk] ? [set ::$gk] : {}}]
}
