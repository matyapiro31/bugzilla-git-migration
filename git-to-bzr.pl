#!/usr/bin/perl -w

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Synchronizes a bzr repository from a git repository.
# Based on the bzr-to-cvs.pl script.

use strict;
use warnings;
use Cwd qw(cwd);
use File::Temp qw(tempdir);
use File::Spec;
use Getopt::Long;

our (%switch, $verbose);

sub do_command {
    $verbose && print join(' ', @_), "\n";
    return system(@_);
}

sub open_last_rev_file {
    my ($bzr_checkout, $mode) = @_;
    my $rev_file_name = "$bzr_checkout/.gitrev";
    open(my $rev_file, $mode, $rev_file_name) || die "$rev_file_name: $!";
    return $rev_file;
}

sub get_last_rev {
    my ($repo, $branch) = @_;
    my $rev = `bzr cat $repo$branch/.gitrev`;
    return '' if $? != 0;
    chomp($rev);
    return $rev;
}

sub update_last_rev {
    my ($bzr_checkout, $rev) = @_;
    my $rev_file = open_last_rev_file($bzr_checkout, '>');
    print $rev_file $rev;
    close($rev_file);
}

sub git_revisions_since {
    # Returns a list of new revisions since $rev, from newest to oldest.
    my ($git_checkout, $rev) = @_;
    my @revs;
    my $command = 'git --git-dir=' . $git_checkout . '/.git --work-tree=' .
        $git_checkout . ' log --pretty="%H" ' . $rev . '..HEAD';
    $verbose && print $command . "\n";
    my $revlist = `$command`;
    chomp($revlist);
    if ($? != 0) {
        print 'error retrieving revisions starting at ' . $rev . "\n";
    } else {
        @revs = split(/\n/, $revlist);
    }
    return @revs;
}

sub git_branch_revno {
    my ($repo, $branch) = @_;
    my $command = "git ls-remote $repo $branch";
    $verbose && print $command . "\n";
    return (split /\s/, `$command`)[0];
}

sub checkout_bzr {
    # Checkout HEAD from the given branch.
    my ($repo, $branch) = @_;
    my $to_dir = tempdir(CLEANUP => 1);
    my $branch_path = $repo . $branch;
    do_command('bzr', 'checkout', '-q', $branch_path, $to_dir) && exit $?;
    return $to_dir;
}

sub checkout_git {
    my ($git_checkout, $rev) = @_;
    do_command('git', "--git-dir=$git_checkout/.git",
               "--work-tree=$git_checkout", 'checkout', '-q', $rev);
}

sub clone_git {
    my ($repo) = @_;
    my $to_dir = tempdir(CLEANUP => 1);
    do_command('git', 'clone', '-q', $repo, $to_dir) && exit $?;
    return $to_dir;
}

sub remove_removed_files {
    my @items = @_;
    my @q_switch = $verbose ? () : ('-q');
    foreach my $item (@items) {
        # We retain .bzrignore files in bzr even if we deleted them in git.
        # Also, we don't delete the .gitrev file, of course.
        if ($item !~ /\.bzrignore/ and $item !~ /\.gitrev/) {
            do_command('bzr', 'rm', @q_switch, $item);
        }
    }
}

sub get_added_and_removed_files {
    my $list = `git status --porcelain | grep -v '.bzr/\$'`;
    my (@added, @removed);
    my @lines = split("\n", $list);
    foreach my $line (@lines) {
        if ($line =~ /^\s*D\s+(.+)/) {
            push(@added, $1);
        } elsif ($line =~ /^\?\?\s+(.+)/) {
            push(@removed, $1);
        }
    }
    return (\@added, \@removed);
}

sub get_log_message {
    my ($rev) = @_;
    return substr(`git log --pretty="%B" -1 $rev`, 0, -1);
}

sub get_author {
    my ($rev) = @_;
    return substr(`git log --pretty="%an <%ae>" -1 $rev`, 0, -1);
}

sub get_commit_time {
    # e.g. '2009-10-10 08:00:00 +0100'.
    my ($rev) = @_;
    return substr(`git log --pretty="%ai" -1 $rev`, 0, -1);
}

sub add_added_files {
    my ($bzr_checkout, @files) = @_;
    return if !@files;

    my @q_switch = $verbose ? () : ('-q');

    do_command('bzr', 'add', @q_switch, @files);
}

sub sync_one_revision {
    my ($git_checkout, $bzr_checkout, $next_git_rev) = @_;

    checkout_git($git_checkout, $next_git_rev);

    # Figure out added and removed files by moving the .git directory
    # to the Bazaar directory and using git commands on the Bazaar directory
    # with the appropriate revision.
    # e.g. git diff 50fbdcf5fd33e21fa81d1fdc4e464cf69fdc122e
    do_command('mv', "$git_checkout/.git/", "$bzr_checkout/");
    chdir($bzr_checkout);
    my ($added, $removed) = get_added_and_removed_files();
    do_command('mv', "$bzr_checkout/.git/", "$git_checkout/");

    if ($verbose) {
        print "added files from git rev $next_git_rev:\n    ";
        print join("\n    ", @$added) . "\n";
        print "removed files from git rev $next_git_rev:\n    ";
        print join("\n    ", @$removed) . "\n";
    }

    chdir($git_checkout);
    my $log_message = get_log_message($next_git_rev);
    my ($bug_id) = $log_message =~ /^[bB]ug (\d+)/;
    my $author = get_author($next_git_rev);
    my $commit_time = get_commit_time($next_git_rev);

    # Copy over the git data into the bzr checkout in preparation for commit.
    my @v_switch = $verbose ? ('-v') : ();
    do_command('rsync', '-a', @v_switch, "$git_checkout/", "$bzr_checkout/");
    do_command('rm', '-rf', "$bzr_checkout/.git/");

    chdir($bzr_checkout);
    remove_removed_files(@$removed);
    add_added_files($bzr_checkout, @$added);
    update_last_rev($bzr_checkout, $next_git_rev);

    my @q_switch = $verbose ? () : ('-q');
    my @fixes_option = $bug_id ? ('--fixes', "mozilla:$bug_id") : ();

    if ($switch{'dry-run'}) {
        # There's no --dry-run option for bzr commit, so just show the status.
        do_command('bzr', 'status', @q_switch);
    } else {
        do_command('bzr', 'commit', '--author', $author, '--commit-time',
                   $commit_time,'-m', $log_message, @q_switch, @fixes_option);
    }
}

# from-repo is the source git repo.
# from-branch is the source branch in the git repo.
# to-repo is the destination Bazaar repo path up to but not including the
#   branch name.
# to-branch is the destination Bazaar branch, which is appended to to-repo.

GetOptions(\%switch, 'from-repo=s', 'from-branch=s', 'to-repo=s', 'to-branch=s', 'dry-run|n', 'verbose|v') || die $@;
($switch{'from-repo'} && $switch{'from-branch'} && $switch{'to-repo'} && $switch{'to-branch'}) or die "--from-repo, --from-branch, --to-repo, and --to-branch must be specified.\n";
my ($from_repo, $from_branch, $to_repo, $to_branch) = @switch{qw(from-repo from-branch to-repo to-branch)};
$verbose = $switch{'verbose'};

$to_repo =~ s!/*$!/!;  # add trailing slash

my $orig_wd = cwd();

my $last_git_rev = get_last_rev($to_repo, $to_branch);
my $latest_git_rev = git_branch_revno($from_repo, $from_branch);

$verbose && print "last git rev in bzr is $last_git_rev and latest " .
    "from git is $latest_git_rev\n";
if ($last_git_rev eq $latest_git_rev) {
    $verbose && print "Everything is up to date!\n";
    exit;
}

my $bzr_checkout = checkout_bzr($to_repo, $to_branch);
if (!$last_git_rev) {
    $verbose && print "No .gitrev found. Creating it with ID of latest git revision\n($latest_git_rev).\n";
    chdir($bzr_checkout);
    update_last_rev($bzr_checkout, $latest_git_rev);
    add_added_files($bzr_checkout, ('.gitrev'));
    my @q_switch = $verbose ? () : ('-q');

    if ($switch{'dry-run'}) {
        # There's no --dry-run option for bzr commit, so just show the status.
        do_command('bzr', 'status', @q_switch);
    } else {
        do_command('bzr', 'commit', '-m', 'Added .gitrev.', @q_switch);
    }
    exit;
}

my $git_checkout = clone_git($from_repo);
checkout_git($git_checkout, $from_branch);
my @new_git_revs = git_revisions_since($git_checkout, $last_git_rev);

$verbose && print 'new git revs: ' . join(', ', @new_git_revs) . "\n";

while (@new_git_revs) {
    my $next_git_rev = pop(@new_git_revs);
    sync_one_revision($git_checkout, $bzr_checkout, $next_git_rev);
}

checkout_git($git_checkout, $from_branch);

chdir($orig_wd);
