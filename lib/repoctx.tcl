# repoctx.tcl -- per-repo context scaffolding (multi-repo fork spike)
#
# Proof-of-concept for a git-gui fork where multi-repo is a first-class feature:
# instead of one process per repository glued together by the master hub, a
# single process holds several repositories, each with its own state living in
# a context object rather than in singleton globals.
#
# This spike converts the repo-identity subsystem (gitdir / worktree /
# reponame / prefix), which is already funneled through the gitdir/reponame
# accessor procs, so the conversion is non-breaking: the app still runs
# single-repo, but repo identity now genuinely lives in a switchable context.
# See the GITGUI_CTX_SELFTEST self-test in git-gui.sh for a demonstration that
# two contexts coexist and can be switched between within one interpreter.

namespace eval repoctx {
	variable contexts       ;# id -> dict {gitdir worktree reponame prefix}
	array set contexts {}
	variable order   {}     ;# registration order of ids
	variable current {}     ;# active context id
	variable seq     0
}

# Register a repository's identity as a new context and make it current.
# Returns the new context id.
proc repoctx::register {gitdir worktree reponame prefix} {
	variable contexts
	variable order
	variable seq
	set id ctx[incr seq]
	set contexts($id) [dict create \
		gitdir $gitdir worktree $worktree reponame $reponame prefix $prefix]
	lappend order $id
	use $id
	return $id
}

# Switch the active context. Keeps the legacy _gitdir/_gitworktree/_reponame/
# _prefix globals in sync so any code still reading them raw (subsystems not
# yet converted) sees the active repository.
proc repoctx::use {id} {
	variable contexts
	variable current
	if {![info exists contexts($id)]} { error "repoctx: unknown context $id" }
	set current $id
	global _gitdir _gitworktree _reponame _prefix
	set _gitdir      [dict get $contexts($id) gitdir]
	set _gitworktree [dict get $contexts($id) worktree]
	set _reponame    [dict get $contexts($id) reponame]
	set _prefix      [dict get $contexts($id) prefix]
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

# Read a field from the active context. Before any context is registered (early
# startup), fall back to the legacy global so accessor calls still work.
proc repoctx::field {key} {
	variable contexts
	variable current
	if {$current ne {} && [info exists contexts($current)]
	 && [dict exists $contexts($current) $key]} {
		return [dict get $contexts($current) $key]
	}
	switch -- $key {
		gitdir   { return [expr {[info exists ::_gitdir]      ? $::_gitdir      : {}}] }
		worktree { return [expr {[info exists ::_gitworktree] ? $::_gitworktree : {}}] }
		reponame { return [expr {[info exists ::_reponame]    ? $::_reponame    : {}}] }
		prefix   { return [expr {[info exists ::_prefix]      ? $::_prefix      : {}}] }
	}
	return {}
}
