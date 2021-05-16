#!/bin/bash
#
# update-ipsets - for FireHOL - A firewall for humans...
#
#   Copyright
#
#       Copyright (C) 2015-2017 Costa Tsaousis <costa@tsaousis.gr>
#       Copyright (C) 2015-2017 Phil Whineray <phil@sanewall.org>
#
#   License
#
#       This program is free software; you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation; either version 2 of the License, or
#       (at your option) any later version.
#
#       This program is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#       GNU General Public License for more details.
#
#       You should have received a copy of the GNU General Public License
#       along with this program. If not, see <http://www.gnu.org/licenses/>.
#
#       See the file COPYING for details.
#

# What this program does:
#
# 1. It downloads a number of IP lists
#    - respects network resource: it will download a file only if it has
#      been changed on the server (IF_MODIFIED_SINCE)
#    - it will not attempt to download a file too frequently
#      (it has a maximum frequency per download URL embedded, so that
#      even if a server does not support IF_MODIFIED_SINCE it will not
#      download the IP list too frequently).
#    - it will use compression when possible.
#
# 2. Once a file is downloaded, it will convert it either to
#    an ip:hash or a net:hash ipset.
#    It can convert:
#    - text files
#    - snort rules files
#    - PIX rules files
#    - XML files (like RSS feeds)
#    - CSV files
#    - compressed files (zip, gz, etc)
#    - generally, anything that can be converted using shell commands
#
# 3. For all file types it can keep a history of the processed sets
#    that can be merged with the new downloaded one, so that it can
#    populate the generated set with all the IPs of the last X days.
#
# 4. For each set updated, it will:
#    - save it to disk
#    - update a kernel ipset, having the same name
#
# 5. It can commit all successfully updated files to a git repository.
#    Just do 'git init' in $SYSCONFDIR/firehol/ipsets to enable it.
#    If it is called with -g it will also push the committed changes
#    to a remote git server (to have this done by cron, please set
#    git to automatically push changes without human action).
#
# 6. It can compare ipsets and keep track of geomaping, history of size,
#    age of IPs listed, retention policy, overlaps with other sets.
#    To enable it, run it with -c.
#
# -----------------------------------------------------------------------------
#
# How to use it:
# 
# This script depends on iprange, found also in firehol.
# It does not depend on firehol. You can use it without firehol.
# 
# 1. Run this script. It will give you instructions on which
#    IP lists are available and what to do to enable them.
# 2. Enable a few lists, following its instructions.
# 3. Run it again to update the lists.
# 4. Put it in a cron job to do the updates automatically.

# -----------------------------------------------------------------------------

READLINK_CMD=${READLINK_CMD:-readlink}
BASENAME_CMD=${BASENAME_CMD:-basename}
DIRNAME_CMD=${DIRNAME_CMD:-dirname}
function realdir {
	local r="$1"; local t=$($READLINK_CMD "$r")
	while [ "$t" ]; do
		r=$(cd $($DIRNAME_CMD "$r") && cd $($DIRNAME_CMD "$t") && pwd -P)/$($BASENAME_CMD "$t")
		t=$($READLINK_CMD "$r")
	done
	$DIRNAME_CMD "$r"
}
PROGRAM_FILE="$0"
PROGRAM_DIR="${FIREHOL_OVERRIDE_PROGRAM_DIR:-$(realdir "$0")}"
PROGRAM_PWD="${PWD}"
declare -a PROGRAM_ORIGINAL_ARGS=("${@}")

for functions_file in install.config functions.common
do
	if [ -r "$PROGRAM_DIR/$functions_file" ]
	then
		source "$PROGRAM_DIR/$functions_file"
	else
		1>&2 echo "Cannot access $PROGRAM_DIR/$functions_file"
		exit 1
	fi
done

common_disable_localization || exit
common_public_umask || exit

marksreset() { :; }
markdef() { :; }
if [ -r "${FIREHOL_CONFIG_DIR}/firehol-defaults.conf" ]
then
	source "${FIREHOL_CONFIG_DIR}/firehol-defaults.conf" || exit 1
fi

RUNNING_ON_TERMINAL=0
if [ "z$1" = "z-nc" ]
then
	shift
else
	common_setup_terminal && RUNNING_ON_TERMINAL=1
fi

$RENICE_CMD 10 $$ >/dev/null 2>/dev/null

# -----------------------------------------------------------------------------
# logging

error() {
	echo >&2 -e "${COLOR_BGRED}${COLOR_WHITE}${COLOR_BOLD} ERROR ${COLOR_RESET}: ${@}"
	$LOGGER_CMD -p daemon.err -t "update-ipsets.sh[$$]" "${@}"
}
warning() {
	echo >&2 -e "${COLOR_BGYELLOW}${COLOR_BLACK}${COLOR_BOLD} WARNING ${COLOR_RESET}: ${@}"
	$LOGGER_CMD -p daemon.warning -t "update-ipsets.sh[$$]" "${@}"
}
info() {
	echo >&2 "${@}"
	$LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "${@}"
}
verbose() {
	[ ${VERBOSE} -eq 1 ] && echo >&2 "${@}"
}
silent() {
	[ ${SILENT} -ne 1 ] && echo >&2 "${@}"
}

print_ipset_indent=35
print_ipset_spacer="$(printf "%${print_ipset_indent}s| " "")"
print_ipset_last=

print_ipset_reset() {
	print_ipset_last=
}

print_ipset_header() {
	local ipset="${1}"

	if [ "${ipset}" = "${print_ipset_last}" ]
		then
		printf >&2 "%${print_ipset_indent}s| " ""
	else
		[ ${SILENT} -ne 1 ] && echo >&2 "${print_ipset_spacer}"
		printf >&2 "${COLOR_GREEN}%${print_ipset_indent}s${COLOR_RESET}| " "${ipset}"
		print_ipset_last="${ipset}"
	fi
}

ipset_error() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 -e "${COLOR_BGRED}${COLOR_WHITE}${COLOR_BOLD} ERROR ${COLOR_RESET} ${@}"
	$LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "ERROR: ${ipset}: ${@}"
}
ipset_warning() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 -e "${COLOR_BGYELLOW}${COLOR_BLACK}${COLOR_BOLD} WARNING ${COLOR_RESET} ${@}"
	$LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "WARNING: ${ipset}: ${@}"
}
ipset_info() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 "${@}"
	$LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "INFO: ${ipset}: ${@}"
}
ipset_saved() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 -e "${COLOR_BGGREEN}${COLOR_RED}${COLOR_BOLD} SAVED ${COLOR_RESET} ${@}"
	$LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "SAVED: ${ipset}: ${@}"
}
ipset_loaded() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 -e "${COLOR_BGGREEN}${COLOR_BLACK}${COLOR_BOLD} LOADED ${COLOR_RESET} ${@}"
	$LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "LOADED: ${ipset}: ${@}"
}
ipset_same() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 -e "${COLOR_BGWHITE}${COLOR_BLACK}${COLOR_BOLD} SAME ${COLOR_RESET} ${@}"
	$LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "DOWNLOADED SAME: ${ipset}: ${@}"
}
ipset_notupdated() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 -e "${COLOR_BGWHITE}${COLOR_BLACK}${COLOR_BOLD} NOT UPDATED ${COLOR_RESET} ${@}"
	# $LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "NOT UPDATED: ${ipset}: ${@}"
}
ipset_notyet() {
	local ipset="${1}"
	shift

	print_ipset_header "${ipset}"
	echo >&2 -e "${COLOR_BGWHITE}${COLOR_BLACK}${COLOR_BOLD} LATER ${COLOR_RESET} ${@}"
	# $LOGGER_CMD -p daemon.info -t "update-ipsets.sh[$$]" "LATER: ${ipset}: ${@}"
}
ipset_disabled() {
	local ipset="${1}"
	shift

	if [ ${SILENT} -eq 0 ]
		then
		print_ipset_header "${ipset}"
		echo >&2 -e "${COLOR_BGWHITE}${COLOR_BLACK}${COLOR_BOLD} DISABLED ${COLOR_RESET} ${@}"
		print_ipset_header "${ipset}"
		echo >&2    "To enable run: update-ipsets enable ${ipset}"
	fi
}
ipset_silent() {
	local ipset="${1}"
	shift

	if [ ${SILENT} -eq 0 ]
		then
		print_ipset_header "${ipset}"
		echo >&2 "${@}"
	fi
}
ipset_verbose() {
	local ipset="${1}"
	shift

	if [ ${VERBOSE} -eq 1 ]
		then
		print_ipset_header "${ipset}"
		echo >&2 "${@}"
	fi
}

# -----------------------------------------------------------------------------
# find a working iprange command

HAVE_IPRANGE=${IPRANGE_CMD}
if [ ! -z "${IPRANGE_CMD}" ]
then
	${IPRANGE_CMD} --has-reduce 2>/dev/null || HAVE_IPRANGE=
fi

if [ -z "$HAVE_IPRANGE" ]
then
	error "Cannot find a working iprange command. It should be part of FireHOL but it is not installed."
	exit 1
fi

# -----------------------------------------------------------------------------
# CONFIGURATION

if [ "${UID}" = "0" -o -z "${UID}" ]
	then
	BASE_DIR="${BASE_DIR-${FIREHOL_CONFIG_DIR}/ipsets}"
	CONFIG_FILE="${CONFIG_FILE-${FIREHOL_CONFIG_DIR}/update-ipsets.conf}"
	RUN_PARENT_DIR="${RUN_PARENT_DIR-$LOCALSTATEDIR/run}"
	CACHE_DIR="${CACHE_DIR-$LOCALSTATEDIR/cache/update-ipsets}"
	LIB_DIR="${LIB_DIR-$LOCALSTATEDIR/lib/update-ipsets}"
	IPSETS_APPLY=1
else
	$MKDIR_CMD -p "${HOME}/.update-ipsets" || exit 1
	BASE_DIR="${BASE_DIR-${HOME}/ipsets}"
	CONFIG_FILE="${CONFIG_FILE-${HOME}/.update-ipsets/update-ipsets.conf}"
	RUN_PARENT_DIR="${RUN_PARENT_DIR-${HOME}/.update-ipsets}"
	CACHE_DIR="${CACHE_DIR-${HOME}/.update-ipsets/cache}"
	LIB_DIR="${LIB_DIR-${HOME}/.update-ipsets/lib}"
	IPSETS_APPLY=0
fi

# admin defined ipsets
ADMIN_SUPPLIED_IPSETS="${ADMIN_SUPPLIED_IPSETS-${FIREHOL_CONFIG_DIR}/ipsets.d}"

# distribution defined ipsets
DISTRIBUTION_SUPPLIED_IPSETS="${DISTRIBUTION_SUPPLIED_IPSETS-${FIREHOL_SHARE_DIR}/ipsets.d}"

# user defined ipsets
USER_SUPPLIED_IPSETS="${USER_SUPPLIED_IPSETS-${HOME}/.update-ipsets/ipsets.d}"

# where to keep the history files
HISTORY_DIR="${HISTORY_DIR-${BASE_DIR}/history}"

# where to keep the files we cannot process
# when empty, error files will be deleted
ERRORS_DIR="${ERRORS_DIR-${BASE_DIR}/errors}"

# where to keep the tmp files
# a subdirectory will be created as RUN_DIR
TMP_DIR="${TMP_DIR-/tmp}"

# options to be given to iprange for reducing netsets
IPSET_REDUCE_FACTOR=${IPSET_REDUCE_FACTOR-20}
IPSET_REDUCE_ENTRIES=${IPSET_REDUCE_ENTRIES-65536}

# how many entries the ipset charts should have
WEB_CHARTS_ENTRIES=${WEB_CHARTS_ENTRIES-500}

# if the .git directory is present, push it also
PUSH_TO_GIT=${PUSH_TO_GIT-0}

# when PUSH_TO_GIT is enabled, this controls if each
# ipset will get its own commit, or all files will be
# committed together
PUSH_TO_GIT_MERGED=${PUSH_TO_GIT_MERGED-1}

# additional options to add as the git commit/push lines
PUSH_TO_GIT_COMMIT_OPTIONS=""
PUSH_TO_GIT_PUSH_OPTIONS=""

# if we will also push github gh-pages
PUSH_TO_GIT_WEB=${PUSH_TO_GIT_WEB-${PUSH_TO_GIT}}

# the maximum time in seconds, to connect to the remote web server
MAX_CONNECT_TIME=${MAX_CONNECT_TIME-10}

# agent string to use when performing downloads
USER_AGENT="FireHOL-Update-Ipsets/3.0 (linux-gnu) https://iplists.firehol.org/"

# the maximum time in seconds any download may take
MAX_DOWNLOAD_TIME=${MAX_DOWNLOAD_TIME-300}

# ignore a few download failures
# if the download fails more than these consecutive times, the ipset will be
# penalized X times its failures (ie. MINUTES * ( FAILURES - the following number) )
IGNORE_REPEATING_DOWNLOAD_ERRORS=${IGNORE_REPEATING_DOWNLOAD_ERRORS-10}

# how many DNS queries to execute in parallel when resolving hostnames to IPs
# IMPORTANT: Increasing this too much and you are going to need A LOT of bandwidth!
# IMPORTANT: Giving a lot parallel requests to your name server will create a queue
#            that will start filling up as time passes, possibly hitting a quota
#            on the name server.
PARALLEL_DNS_QUERIES=${PARALLEL_DNS_QUERIES-10}

# where to put the CSV files for the web server
# if empty or does not exist, web files will not be generated
WEB_DIR=""

# how to chown web files
WEB_OWNER=""

# where is the web url to show info about each ipset
# the ipset name is appended to it
WEB_URL="http://iplists.firehol.org/?ipset="

# the path to copy downloaded files to, using ${WEB_OWNER} permissions
# if empty, do not copy them
WEB_DIR_FOR_IPSETS=""

# options for the web site
# the ipset name will be appended
LOCAL_COPY_URL="https://iplists.firehol.org/files/"
GITHUB_CHANGES_URL="https://github.com/firehol/blocklist-ipsets/commits/master/"
GITHUB_SETINFO="https://github.com/firehol/blocklist-ipsets/tree/master/"

# -----------------------------------------------------------------------------
# Command line parsing

CLEANUP_OLD=0
ENABLE_ALL=0
IGNORE_LASTCHECKED=0
FORCE_WEB_REBUILD=0
REPROCESS_ALL=0
SILENT=0
VERBOSE=0

declare -a LISTS_TO_ENABLE=()
declare -A RUN_ONLY_THESE_IPSETS=()

usage() {
$CAT_CMD <<EOFUSAGE
FireHOL update-ipsets $VERSION
(C) 2015 Costa Tsaousis

USAGE:

${PROGRAM_FILE} [options]

The above will execute an update on the configured ipsets

or

${PROGRAM_FILE} enable ipset1 ipset2 ipset3 ...

The above will only enable the given ipsets and exit
It does not validate that the ipsets exists.

options are:

	-s
	--silent 	log less than default
			This will not report all the possible ipsets that
			can be enabled.

	-v
	--verbose 	log more than default
			This will produce more log, to see what the program
			does (more like debugging info).

	-f FILE
	--config FILE 	the configuration file to use, the default is:
			${CONFIG_FILE}

	-i
	--recheck 	Each ipset has a hardcoded refresh frequency.
			When we check if it has been updated on the server
			we may find that it has not.
			update-ipsets.sh will then attempt to re-check
			in half the original frequency.
			When this option is given, update-ipsets.sh will
			ignore that it has checked it before and attempt
			to download all ipsets that have not been updated.
			DO NOT ENABLE THIS OPTION WHEN RUNNING VIA CRON.
			We have to respect the server resources of the
			IP list maintainers' servers!

	-g
	--push-git 	In the base directory (default: ${BASE_DIR})
			you can setup git (just cd to it and run 'git init').
			Once update-ipsets.sh finds a git initialized, it
			will automatically commit all ipset and netset files
			to it.
			This option enables an automatic 'git push' at the
			end of all commits.
			You have to set it up so that git will not ask for 
			credentials to do the push (normally this done by
			using ssh in the git push URL and configuring the
			ssh keys for automatic login - keep in mind that
			if update-ipsets is running through cron, the user
			that runs it has to have the ssh keys installed).

	--enable-all 	Enable all the ipsets at once
			This will also execute an update on them

	-r
	--rebuild 	Will re-process all ipsets, even the ones that have
			not been updated.
			This is required in cases of program updates that
			need to trigger a full refresh of the generated
			metadata (it only affects the web site).

	--cleanup 	Will cleanup obsolete ipsets that are not
			available anymore.

	run ipset1 ipset2 ...
			Will only process the given ipsets.
			This parameter must be the last in command line, it
			assumes all parameters after the keyword 'run' are
			ipsets names.

EOFUSAGE
}

while [ ! -z "${1}" ]
do
	case "${1}" in
		enable)
			shift
			LISTS_TO_ENABLE=("${@}")
			break
			;;

		run)
			shift
			while [ ! -z "${1}" ]
			do
				RUN_ONLY_THESE_IPSETS[${1}]="${1}"
				shift
			done
			break
			;;

		--cleanup) CLEANUP_OLD=1;;
		--rebuild|-r) FORCE_WEB_REBUILD=1;;
		--reprocess|-p) REPROCESS_ALL=1;;
		--silent|-s) SILENT=1;;
		--push-git|-g) PUSH_TO_GIT=1;;
		--recheck|-i) IGNORE_LASTCHECKED=1;;
		--compare|-c) ;; # obsolete
		--verbose|-v) VERBOSE=1;;
		--config|-f) CONFIG_FILE="${2}"; shift ;;
		--enable-all) ENABLE_ALL=1;;
		--help|-h) usage; exit 1 ;;
		*) error "Unknown command line argument '${1}'".; exit 1 ;;
	esac
	shift
done

if [ -f "${CONFIG_FILE}" ]
	then
	info "Loading configuration from ${CONFIG_FILE}"
	source "${CONFIG_FILE}"
fi


# -----------------------------------------------------------------------------
# FIX DIRECTORIES

if [ -z "${BASE_DIR}" ]
	then
	error "BASE_DIR is unset. Set it in '${CONFIG_FILE}'."
	exit 1
fi

if [ -z "${RUN_PARENT_DIR}" ]
	then
	error "RUN_PARENT_DIR is unset. Set it in '${CONFIG_FILE}'."
	exit 1
fi

if [ ! -d "${RUN_PARENT_DIR}" ]
	then
	error "RUN_PARENT_DIR='${RUN_PARENT_DIR}' does not exist. Set it in '${CONFIG_FILE}'."
	exit 1
fi

if [ -z "${LIB_DIR}" ]
	then
	error "LIB_DIR is unset. Probably you empty it in '${CONFIG_FILE}'. Please leave it set."
	exit 1
fi

if [ -z "${CACHE_DIR}" ]
	then
	error "CACHE_DIR is unset. Probably you empty it in '${CONFIG_FILE}'. Please leave it set."
	exit 1
fi

if [ -z "${TMP_DIR}" ]
	then
	error "TMP_DIR is unset. Set it in '${CONFIG_FILE}'."
	exit 1
fi

if [ ! -d "${TMP_DIR}" ]
	then
	error "TMP_DIR='${TMP_DIR}' does not exist. Set it in '${CONFIG_FILE}'."
	exit 1
fi

if [ -z "${WEB_DIR}" ]
	then
	WEB_DIR=
elif [ ! -d "${WEB_DIR}" ]
	then
	warning "WEB_DIR='${WEB_DIR}' is invalid. Disabling web site updates. Set WEB_DIR in '${CONFIG_FILE}' to enable it."
	WEB_DIR=
fi

for d in "${BASE_DIR}" "${HISTORY_DIR}" "${ERRORS_DIR}" "${CACHE_DIR}" "${LIB_DIR}"
do
	[ -z "${d}" -o -d "${d}" ] && continue

	$MKDIR_CMD -p "${d}" || exit 1
	info "Created directory '${d}'."
done
cd "${BASE_DIR}" || exit 1


# -----------------------------------------------------------------------------
# if we are just enabling ipsets

if [ "${#LISTS_TO_ENABLE[@]}" -gt 0 ]
	then
	for x in "${LISTS_TO_ENABLE[@]}"
	do
		if [ -f "${BASE_DIR}/${x}.source" ]
			then
			warning "${x}: is already enabled"
		else
			info "${x}: Enabling ${x}..."
			$TOUCH_CMD -t 0001010000 "${BASE_DIR}/${x}.source" || exit 1
		fi
	done
	exit 0
fi

ipset_shall_be_run() {
	local ipset="${1}"

	if [ ! -f "${BASE_DIR}/${ipset}.source" ]
	then
		if [ ${ENABLE_ALL} -eq 1 -a -z "${IPSET_TMP_DO_NOT_ENABLE_WITH_ALL[${ipset}]}" ]
			then
			ipset_silent "${ipset}" "Enabling due to --enable-all option."
			$TOUCH_CMD -t 0001010000 "${BASE_DIR}/${ipset}.source" || return 1
		else
			ipset_disabled "${ipset}"

			# cleanup the cache
			[ ! -z "${IPSET_CHECKED_DATE[${ipset}]}" ] && cache_remove_ipset "${ipset}"

			return 1
		fi
	fi

	if [ ${#RUN_ONLY_THESE_IPSETS[@]} -ne 0 -a -z "${RUN_ONLY_THESE_IPSETS[${ipset}]}" ]
		then
		ipset_verbose "${ipset}" "skipping - not requested"
		return 2
	fi

	return 0
}

# -----------------------------------------------------------------------------
# Make sure we are the only process doing this job

# to ensure only one runs
UPDATE_IPSETS_LOCK_FILE="${RUN_PARENT_DIR}/update-ipsets.lock"

exlcusive_lock() {
	exec 200>"${UPDATE_IPSETS_LOCK_FILE}"
	if [ $? -ne 0 ]; then exit; fi
	${FLOCK_CMD} -n 200
	if [ $? -ne 0 ]
	then
		echo >&2 "Already running. Try later..."
		exit 1
	fi
	return 0
}

exlcusive_lock

# -----------------------------------------------------------------------------
# CLEANUP

RUN_DIR=$(${MKTEMP_CMD} -d "${TMP_DIR}/update-ipsets-XXXXXXXXXX")
if [ $? -ne 0 ]
	then
	error "ERROR: Cannot create temporary directory in ${TMP_DIR}."
	exit 1
fi
cd "${RUN_DIR}"

PROGRAM_COMPLETED=0
cleanup() {
	# make sure the cache is saved
	CACHE_SAVE_ENABLED=1
	cache_save

	cd "${TMP_DIR}"

	if [ ! -z "${RUN_DIR}" -a -d "${RUN_DIR}" ]
		then
		verbose "Cleaning up temporary files in ${RUN_DIR}."
		$RM_CMD -rf "${RUN_DIR}"
	fi
	trap exit EXIT

	if [ ${PROGRAM_COMPLETED} -eq 1 ]
		then
		verbose "Completed successfully."
		exit 0
	fi

	verbose "Completed with errors."
	exit 1
}
trap cleanup EXIT
trap cleanup SIGHUP
trap cleanup INT

# -----------------------------------------------------------------------------
# other preparations

if [ ! -d "${BASE_DIR}/.git" -a ${PUSH_TO_GIT} -ne 0 ]
then
	info "Git is not initialized in ${BASE_DIR}. Ignoring git support."
	PUSH_TO_GIT=0
else
	[ -z "${GIT_CMD}" ] && PUSH_TO_GIT=0
fi

[ -d "${BASE_DIR}/.git" -a ! -f "${BASE_DIR}/.gitignore" ] && printf "*.setinfo\n*.source\n" >"${BASE_DIR}/.gitignore"


# -----------------------------------------------------------------------------
# COMMON FUNCTIONS

# echo all the parameters, sorted
params_sort() {
	local x=
	for x in "${@}"
	do
		echo "${x}"
	done | $SORT_CMD
}

# convert a number of minutes to a human readable text
mins_to_text() {
	local days= hours= mins="${1}"

	if [ -z "${mins}" -o $[mins + 0] -eq 0 ]
		then
		echo "none"
		return 0
	fi

	days=$[mins / (24*60)]
	mins=$[mins - (days * 24 * 60)]

	hours=$[mins / 60]
	mins=$[mins - (hours * 60)]

	case ${days} in
		0) ;;
		1) printf "1 day " ;;
		*) printf "%d days " ${days} ;;
	esac
	case ${hours} in
		0) ;;
		1) printf "1 hour " ;;
		*) printf "%d hours " ${hours} ;;
	esac
	case ${mins} in
		0) ;;
		1) printf "1 min " ;;
		*) printf "%d mins " ${mins} ;;
	esac
	printf "\n"

	return 0
}

declare -A UPDATED_DIRS=()
declare -A UPDATED_SETS=()

git_add_if_not_already_added() {
	local file="${1}"

	$GIT_CMD -C "${BASE_DIR}" ls-files "${file}" --error-unmatch >/dev/null 2>&1
	if [ $? -ne 0 ]
		then
		[ ! -f "${BASE_DIR}/${file}" ] && $TOUCH_CMD "${BASE_DIR}/${file}"
		verbose "Adding '${file}' to git"
		$GIT_CMD -C "${BASE_DIR}" add "${file}"
		return $?
	fi
	
	return 0
}

git_ignore_file() {
	local file="${1}"

	local found=$($CAT_CMD "${BASE_DIR}/.gitignore" | $GREP_CMD "^${file}$")
	if [ -z "${found}" ]
		then
		echo "${file}" >>"${BASE_DIR}/.gitignore" || return 1
	fi

	return 0
}

# http://stackoverflow.com/questions/3046436/how-do-you-stop-tracking-a-remote-branch-in-git
# to delete a branch on git
# localy only - remote will not be affected
#
# BRANCH_TO_DELETE_LOCALY_ONLY="master"
# git branch -d -r origin/${BRANCH_TO_DELETE_LOCALY_ONLY}
# git config --unset branch.${BRANCH_TO_DELETE_LOCALY_ONLY}.remote
# git config --unset branch.${BRANCH_TO_DELETE_LOCALY_ONLY}.merge
# git gc --aggressive --prune=all --force

declare -A IPSET_TMP_DO_NOT_REDISTRIBUTE=()
declare -A IPSET_TMP_ACCEPT_EMPTY=()
declare -A IPSET_TMP_NO_IF_MODIFIED_SINCE=()
declare -A IPSET_TMP_DO_NOT_ENABLE_WITH_ALL=()
commit_to_git() {
	cd "${BASE_DIR}" || return 1

}

copy_ipsets_to_web() {
	[ -z "${WEB_DIR_FOR_IPSETS}" -o ! -d "${WEB_DIR_FOR_IPSETS}" ] && return 0

	local ipset= f= d=
	for ipset in "${!UPDATED_SETS[@]}"
	do
		[ ! -z "${IPSET_TMP_DO_NOT_REDISTRIBUTE[${ipset}]}" ] && continue
		[ ! -f "${UPDATED_SETS[${ipset}]}" ] && continue

		# relative filename - may include a dir
		f="${UPDATED_SETS[${ipset}]}"
		d="${f/\/*/}"
		[ "${d}" = "${f}" ] && d=

		if [ ! -z "${d}" ]
			then
			echo >&2 "Creating directory ${WEB_DIR_FOR_IPSETS}/${d}"
			${MKDIR_CMD} -p "${WEB_DIR_FOR_IPSETS}/${d}"
			[ ! -z "${WEB_OWNER}" ] && ${CHOWN_CMD} "${WEB_OWNER}" "${WEB_DIR_FOR_IPSETS}/${d}"
		fi

		echo >&2 "Copying ${f} to ${WEB_DIR_FOR_IPSETS}/${f}"
		${CP_CMD} "${f}" "${WEB_DIR_FOR_IPSETS}/${f}.new"
		[ ! -z "${WEB_OWNER}" ] && ${CHOWN_CMD} "${WEB_OWNER}" "${WEB_DIR_FOR_IPSETS}/${f}.new"
		${MV_CMD} "${WEB_DIR_FOR_IPSETS}/${f}.new" "${WEB_DIR_FOR_IPSETS}/${f}"
	done
}

# touch a file to a relative date in the past
touch_in_the_past() {
	local mins_ago="${1}" file="${2}"

	local now=$($DATE_CMD +%s)
	local date=$($DATE_CMD -d @$[now - (mins_ago * 60)] +"%y%m%d%H%M.%S")
	$TOUCH_CMD -t "${date}" "${file}"
}
touch_in_the_past $[7 * 24 * 60] "${RUN_DIR}/.warn_if_last_downloaded_before_this"

# get all the active ipsets in the system
ipset_list_names() {
	if [ ${IPSETS_APPLY} -eq 1 ]
		then
		( $IPSET_CMD --list -t || $IPSET_CMD --list ) | $GREP_CMD "^Name: " | $CUT_CMD -d ' ' -f 2
		return $?
	fi
	return 0
}

echo
echo "`$DATE_CMD`: ${0} ${*}" 
echo

if [ ${IPSETS_APPLY} -eq 1 ]
	then
	# find the active ipsets
	info "Getting list of active ipsets..."
	declare -A sets=()
	for x in $(ipset_list_names)
	do
		sets[$x]=1
	done
	silent "Found these ipsets active: ${!sets[@]}"
fi

# -----------------------------------------------------------------------------

# check if a file is too old
check_file_too_old() {
	local ipset="${1}" file="${2}"

	if [ -f "${file}" -a "${RUN_DIR}/.warn_if_last_downloaded_before_this" -nt "${file}" ]
	then
		ipset_warning "${ipset}" "DATA ARE TOO OLD!"
		return 1
	fi
	return 0
}

history_keep() {
	local ipset="${1}" file="${2}" slot=

	slot="`$DATE_CMD -r "${file}" +%s`.set"

	if [ ! -d "${HISTORY_DIR}/${ipset}" ]
	then
		$MKDIR_CMD "${HISTORY_DIR}/${ipset}" || return 2
		$CHMOD_CMD 700 "${HISTORY_DIR}/${ipset}"
	fi

	# copy the new file to the history
	# we use the binary format of iprange for fast operations later
	$IPRANGE_CMD "${file}" --print-binary >"${HISTORY_DIR}/${ipset}/${slot}"
	$TOUCH_CMD -r "${file}" "${HISTORY_DIR}/${ipset}/${slot}"
}

history_cleanup() {
	local ipset="${1}" mins="${2}"

	# touch a reference file
	touch_in_the_past ${mins} "${RUN_DIR}/history.reference" || return 3

	for x in ${HISTORY_DIR}/${ipset}/*.set
	do
		if [ ! "${x}" -nt "${RUN_DIR}/history.reference" ]
		then
			ipset_verbose "${ipset}" "deleting history file '${x}'"
			$RM_CMD "${x}"
		fi
	done
}

history_get() {
	local ipset="${1}" mins="${2}" \
		tmp= x=

	# touch a reference file
	touch_in_the_past ${mins} "${RUN_DIR}/history.reference" || return 3

	# get all the history files, that are newer than our reference
	${IPRANGE_CMD} --union-all $($FIND_CMD "${HISTORY_DIR}/${ipset}"/*.set -newer "${RUN_DIR}/history.reference")
	$RM_CMD "${RUN_DIR}/history.reference"

	return 0
}

# -----------------------------------------------------------------------------
# DOWNLOADERS

# RETURN
# 0 = SUCCESS
# 99 = NOT MODIFIED ON THE SERVER
# ANY OTHER = FAILED

# Fetch a url - the output file has the last modified timestamp of the server.
# On the next run, the file is downloaded only if it has changed on the server.
DOWNLOADER_MESSAGE=
DOWNLOADER_OK=0
DOWNLOADER_FAILED=1
DOWNLOADER_NOTMODIFIED=255

DOWNLOADER_IPSET=
downloader_log() {
	local severity="${1}" message="${2}"

	case "${severity}" in
		info)		ipset_info "${DOWNLOADER_IPSET}" "${message}" ;;
		silent)		ipset_silent "${DOWNLOADER_IPSET}" "${message}" ;;
		warning)	ipset_warning "${DOWNLOADER_IPSET}" "${message}" ;;
		error)		ipset_warning "${DOWNLOADER_IPSET}" "${message}" ;;
		*)			ipset_verbose "${DOWNLOADER_IPSET}" "${message}" ;;
	esac
}

copyfile() {
	local file="${1}" reference="${2}" url="${3}"
	eval "local doptions=(${4})"

	if [ ! -z "${doptions[0]}" -a -f "${doptions[0]}" ]
		then
		$CAT_CMD "${doptions[0]}" >"${file}"
		$TOUCH_CMD -r "${doptions[0]}" "${file}"
		DOWNLOADER_MESSAGE="copied file '${doptions[0]}'"
		return ${DOWNLOADER_OK}
	fi

	DOWNLOADER_MESSAGE="file '${doptions[0]}' is not found"
	return ${DOWNLOADER_FAILED}
}

geturl() {
	local file="${1}" reference="${2}" url="${3}" doptions=() ret= http_code= curl_opts=() message=

	eval "local doptions=(${4})"

	if [ -z "${reference}" -o ! -f "${reference}" ]
		then
		reference="${RUN_DIR}/geturl-reference"
		$TOUCH_CMD -t 0001010000 "${reference}"
	else
		# copy the timestamp of the reference
		# to our file - we need this to check it later
		$TOUCH_CMD -r "${reference}" "${file}"
		curl_opts+=("--time-cond" "${reference}")
	fi

	[ ${VERBOSE} -eq 0 ] && curl_opts+=("--silent")

	downloader_log verbose "curl ${doptions} '${url}'"
	http_code=$( \
		$CURL_CMD --connect-timeout ${MAX_CONNECT_TIME} --max-time ${MAX_DOWNLOAD_TIME} \
			--retry 0 --fail --compressed --user-agent "${USER_AGENT}" \
			"${curl_opts[@]}" \
			--output "${file}" --remote-time \
			--location --referer "http://iplists.firehol.org/" \
			--write-out '%{http_code}' "${doptions[@]}" "${url}" \
		)
	ret=$?

	case "${ret}" in
		0)	if [ "${http_code}" = "304" -a ! "${file}" -nt "${reference}" ]
			then
				message="Not Modified"
				ret=${DOWNLOADER_NOTMODIFIED}
			else
				message="OK"
				ret=${DOWNLOADER_OK}
			fi
			;;

		1)	message="Unsupported Protocol"; ret=${DOWNLOADER_FAILED} ;;
		2)	message="Failed to initialize"; ret=${DOWNLOADER_FAILED} ;;
		3)	message="Malformed URL"; ret=${DOWNLOADER_FAILED} ;;
		5)	message="Can't resolve proxy"; ret=${DOWNLOADER_FAILED} ;;
		6)	message="Can't resolve host"; ret=${DOWNLOADER_FAILED} ;;
		7)	message="Failed to connect"; ret=${DOWNLOADER_FAILED} ;;
		18)	message="Partial Transfer"; ret=${DOWNLOADER_FAILED} ;;
		22)	message="HTTP Error"; ret=${DOWNLOADER_FAILED} ;;
		23)	message="Cannot write local file"; ret=${DOWNLOADER_FAILED} ;;
		26)	message="Read Error"; ret=${DOWNLOADER_FAILED} ;;
		28)	message="Timeout"; ret=${DOWNLOADER_FAILED} ;;
		35)	message="SSL Error"; ret=${DOWNLOADER_FAILED} ;;
		47)	message="Too many redirects"; ret=${DOWNLOADER_FAILED} ;;
		52)	message="Server did not reply anything"; ret=${DOWNLOADER_FAILED} ;;
		55)	message="Failed sending network data"; ret=${DOWNLOADER_FAILED} ;;
		56)	message="Failure in receiving network data"; ret=${DOWNLOADER_FAILED} ;;
		61)	message="Unrecognized transfer encoding"; ret=${DOWNLOADER_FAILED} ;;
		*)	message="Error ${ret} returned by curl"; ret=${DOWNLOADER_FAILED} ;;
	esac

	DOWNLOADER_MESSAGE="HTTP/${http_code} ${message}"

	return ${ret}
}

# download a file if it has not been downloaded in the last $mins
DOWNLOAD_OK=0
DOWNLOAD_FAILED=1
DOWNLOAD_NOT_UPDATED=2
download_manager() {
	local 	ipset="${1}" mins="${2}" url="${3}" \
			st= ret= \
			tmp= now="$($DATE_CMD +%s)" base= omins= detail= inc= fails= dt=

	# make sure it is numeric
	[ "$[mins + 0]" -lt 1 ] && mins=1
	omins=${mins}

	# add some time (1/100th), to make sure the source is updated
	inc=$[ (mins + 50) / 100 ]

	# if the download period is less than 30min, do not add anything
	[ ${mins} -le 30 ] && inc=0

	# if the added time is above 10min, make it 10min
	[ ${inc} -gt 10 ] && inc=10

	mins=$[mins + inc]

	# make sure we have a proper time for last-checked
	st=0
	[ -f "${BASE_DIR}/${ipset}.source"          ] && st="$($DATE_CMD -r "${BASE_DIR}/${ipset}.source" +%s)"
	[ -z "${IPSET_CHECKED_DATE[${ipset}]}"      ] && IPSET_CHECKED_DATE[${ipset}]=${st}
	[ -z "${IPSET_CHECKED_DATE[${ipset}]}"      ] && IPSET_CHECKED_DATE[${ipset}]=0
	[ -z "${IPSET_DOWNLOAD_FAILURES[${ipset}]}" ] && IPSET_DOWNLOAD_FAILURES[${ipset}]=0

	# nunber of consecutive failures so far
	fails=${IPSET_DOWNLOAD_FAILURES[${ipset}]}
	base=${IPSET_CHECKED_DATE[${ipset}]}
	if [ ${IGNORE_LASTCHECKED} -eq 1 ]
		then
		base=${st}
		fails=0
	fi

	dt=$[ now - base ]
	detail="$[dt/60]/${mins} mins passed, will fetch in $[mins - (dt/60)] mins"

	if [ ${fails} -gt ${IGNORE_REPEATING_DOWNLOAD_ERRORS} ]
		then
		mins=$[ mins * (fails - IGNORE_REPEATING_DOWNLOAD_ERRORS) ]
		dt=$[ now - base ]
		detail="$[dt/60]/${mins} mins passed, will fetch in $[mins - (dt/60)] mins"
		ipset_silent "${ipset}" "${fails} fails so far, time increased from ${omins} to ${mins} mins"
	elif [ ${fails} -gt 0 ]
		then
		mins=$[ (mins + 1) / 2 ]
		dt=$[ now - base ]
		detail="$[dt/60]/${mins} mins passed, will fetch in $[mins - (dt/60)] mins"
		ipset_silent "${ipset}" "${fails} fails so far, time decreased from ${omins} to ${mins} mins"
	fi

	# echo >&2 "${ipset}: source:${st} processed:${IPSET_PROCESSED_DATE[${ipset}]} checked:${IPSET_CHECKED_DATE[${ipset}]}, fails:${IPSET_DOWNLOAD_FAILURES[${ipset}]}, mins:${omins}, dt:$[dt / 60]"

	# if it is too soon, do nothing
	if [ ${dt} -lt $[ mins * 60 ] ]
		then
		ipset_notyet "${ipset}" "${detail}"
		return ${DOWNLOAD_NOT_UPDATED}
	fi

	# return ${DOWNLOAD_NOT_UPDATED}

	IPSET_CHECKED_DATE[${ipset}]="${now}"
	ipset_info "${ipset}" "$[dt/60]/${mins} mins passed, downloading..."

	# download it
	local reference="${BASE_DIR}/${ipset}.source"
	[ ! -z "${IPSET_TMP_NO_IF_MODIFIED_SINCE[${ipset}]}" ] && reference=""

	if [ ${#url} -gt 55 ]
		then
		ipset_silent "${ipset}" "fetch: '$(printf '%-50.50s ... ' "${url}")'"
	else
		ipset_silent "${ipset}" "fetch: '${url}'"
	fi

	tmp=`$MKTEMP_CMD "${RUN_DIR}/download-${ipset}-XXXXXXXXXX"` || return ${DOWNLOAD_FAILED}
	[ -z "${IPSET_DOWNLOADER[${ipset}]}" ] && IPSET_DOWNLOADER[${ipset}]="geturl"
	DOWNLOADER_IPSET="${ipset}"

	ipset_verbose "${ipset}" "running downloader '${IPSET_DOWNLOADER[${ipset}]}'"
	"${IPSET_DOWNLOADER[${ipset}]}" "${tmp}" "${reference}" "${url}" "${IPSET_DOWNLOADER_OPTIONS[${ipset}]}"
	ret=$?
	ipset_info "${ipset}" "${DOWNLOADER_MESSAGE}"

	# if the downloaded file is empty, but we don't accept empty files
	if [ $ret -eq 0 -a ! -s "${tmp}" -a -z "${IPSET_TMP_ACCEPT_EMPTY[${ipset}]}" ]
		then
		ret=9999
		ipset_silent "${ipset}" "downloaded file is empty"
	fi

	case $ret in
		# DOWNLOADER_OK
		0)
			ipset_silent "${ipset}" "downloaded successfully"
			IPSET_CHECKED_DATE[${ipset}]="$($DATE_CMD -r "${tmp}" +%s)"
			IPSET_DOWNLOAD_FAILURES[${ipset}]=0
			cache_save
			;;

		# DOWNLOADER_NOTMODIFIED
		255)
			IPSET_DOWNLOAD_FAILURES[${ipset}]=0
			cache_save
			ipset_notupdated "${ipset}" "file on server has not been updated yet"
			$RM_CMD "${tmp}"
			return ${DOWNLOAD_NOT_UPDATED}
			;;

		# DOWNLOADER_FAILED
		*)
			$RM_CMD "${tmp}"
			IPSET_DOWNLOAD_FAILURES[${ipset}]=$(( fails + 1 ))
			ipset_error "${ipset}" "failed - ${IPSET_DOWNLOAD_FAILURES[${ipset}]} consecutive failures so far."
			cache_save
			return ${DOWNLOAD_FAILED}
			;;
	esac

	[ ! -z "${IPSET_TMP_NO_IF_MODIFIED_SINCE[${ipset}]}" ] && $TOUCH_CMD "${tmp}"

	# check if the downloaded file is the same with the last one
	$DIFF_CMD -q "${BASE_DIR}/${ipset}.source" "${tmp}" >/dev/null 2>&1
	if [ $? -eq 0 ]
	then
		# they are the same
		ipset_same "${ipset}" "downloaded file is the same to the old one."

		# copy the timestamp of the downloaded to our file
		$TOUCH_CMD -r "${tmp}" "${BASE_DIR}/${ipset}.source"
		$RM_CMD "${tmp}"
		return ${DOWNLOAD_NOT_UPDATED}
	fi

	# move it to its place
	ipset_silent "${ipset}" "saving downloaded file"
	$MV_CMD "${tmp}" "${BASE_DIR}/${ipset}.source" || return ${DOWNLOAD_FAILED}

	return ${DOWNLOAD_OK}
}

# -----------------------------------------------------------------------------
# keep a cache of the data about all completed ipsets

declare -A IPSET_INFO=()
declare -A IPSET_SOURCE=()
declare -A IPSET_URL=()
declare -A IPSET_FILE=()
declare -A IPSET_IPV=()
declare -A IPSET_HASH=()
declare -A IPSET_MINS=()
declare -A IPSET_HISTORY_MINS=()
declare -A IPSET_ENTRIES=()
declare -A IPSET_IPS=()
declare -A IPSET_SOURCE_DATE=()
declare -A IPSET_PROCESSED_DATE=()
declare -A IPSET_CHECKED_DATE=()
declare -A IPSET_CATEGORY=()
declare -A IPSET_MAINTAINER=()
declare -A IPSET_MAINTAINER_URL=()

declare -A IPSET_LICENSE=()
declare -A IPSET_GRADE=()
declare -A IPSET_PROTECTION=()
declare -A IPSET_INTENDED_USE=()
declare -A IPSET_FALSE_POSITIVES=()
declare -A IPSET_POISONING=()
declare -A IPSET_SERVICES=()
declare -A IPSET_ENTRIES_MIN=()
declare -A IPSET_ENTRIES_MAX=()
declare -A IPSET_IPS_MIN=()
declare -A IPSET_IPS_MAX=()
declare -A IPSET_STARTED_DATE=()

declare -A IPSET_CLOCK_SKEW=()

declare -A IPSET_DOWNLOAD_FAILURES=()
declare -A IPSET_VERSION=()
declare -A IPSET_AVERAGE_UPDATE_TIME=()
declare -A IPSET_MIN_UPDATE_TIME=()
declare -A IPSET_MAX_UPDATE_TIME=()

declare -A IPSET_DOWNLOADER=()
declare -A IPSET_DOWNLOADER_OPTIONS=()

# TODO - FIXME
#declare -A IPSET_PREFIXES=()

CACHE_SAVE_ENABLED=1
cache_save() {
	[ ${CACHE_SAVE_ENABLED} -eq 0 ] && return 0

	#info "Saving cache"

	declare -p \
		IPSET_INFO \
		IPSET_SOURCE \
		IPSET_URL \
		IPSET_FILE \
		IPSET_IPV \
		IPSET_HASH \
		IPSET_MINS \
		IPSET_HISTORY_MINS \
		IPSET_ENTRIES \
		IPSET_IPS \
		IPSET_SOURCE_DATE \
		IPSET_CHECKED_DATE \
		IPSET_PROCESSED_DATE \
		IPSET_CATEGORY \
		IPSET_MAINTAINER \
		IPSET_MAINTAINER_URL \
		IPSET_LICENSE \
		IPSET_GRADE \
		IPSET_PROTECTION \
		IPSET_INTENDED_USE \
		IPSET_FALSE_POSITIVES \
		IPSET_POISONING \
		IPSET_SERVICES \
		IPSET_ENTRIES_MIN \
		IPSET_ENTRIES_MAX \
		IPSET_IPS_MIN \
		IPSET_IPS_MAX \
		IPSET_STARTED_DATE \
		IPSET_CLOCK_SKEW \
		IPSET_DOWNLOAD_FAILURES \
		IPSET_VERSION \
		IPSET_AVERAGE_UPDATE_TIME \
		IPSET_MIN_UPDATE_TIME \
		IPSET_MAX_UPDATE_TIME \
		IPSET_DOWNLOADER \
		IPSET_DOWNLOADER_OPTIONS \
		>"${BASE_DIR}/.cache.new.$$"

	[ -f "${BASE_DIR}/.cache" ] && $CP_CMD "${BASE_DIR}/.cache" "${BASE_DIR}/.cache.old"
	$MV_CMD "${BASE_DIR}/.cache.new.$$" "${BASE_DIR}/.cache" || exit 1
}

if [ -f "${BASE_DIR}/.cache" ]
	then
	verbose "Loading cache file: ${BASE_DIR}/.cache"
	source "${BASE_DIR}/.cache"
fi

cache_save_metadata_backup() {
	local ipset="${1}"

	ipset_verbose "${ipset}" "saving metadata backup"

	printf >"${LIB_DIR}/${ipset}/metadata" "\
IPSET_INFO[${ipset}]=%q\n\
IPSET_SOURCE[${ipset}]=%q\n\
IPSET_URL[${ipset}]=%q\n\
IPSET_FILE[${ipset}]=%q\n\
IPSET_IPV[${ipset}]=%q\n\
IPSET_HASH[${ipset}]=%q\n\
IPSET_MINS[${ipset}]=%q\n\
IPSET_HISTORY_MINS[${ipset}]=%q\n\
IPSET_ENTRIES[${ipset}]=%q\n\
IPSET_IPS[${ipset}]=%q\n\
IPSET_SOURCE_DATE[${ipset}]=%q\n\
IPSET_CHECKED_DATE[${ipset}]=%q\n\
IPSET_PROCESSED_DATE[${ipset}]=%q\n\
IPSET_CATEGORY[${ipset}]=%q\n\
IPSET_MAINTAINER[${ipset}]=%q\n\
IPSET_MAINTAINER_URL[${ipset}]=%q\n\
IPSET_LICENSE[${ipset}]=%q\n\
IPSET_GRADE[${ipset}]=%q\n\
IPSET_PROTECTION[${ipset}]=%q\n\
IPSET_INTENDED_USE[${ipset}]=%q\n\
IPSET_FALSE_POSITIVES[${ipset}]=%q\n\
IPSET_POISONING[${ipset}]=%q\n\
IPSET_SERVICES[${ipset}]=%q\n\
IPSET_ENTRIES_MIN[${ipset}]=%q\n\
IPSET_ENTRIES_MAX[${ipset}]=%q\n\
IPSET_IPS_MIN[${ipset}]=%q\n\
IPSET_IPS_MAX[${ipset}]=%q\n\
IPSET_STARTED_DATE[${ipset}]=%q\n\
IPSET_CLOCK_SKEW[${ipset}]=%q\n\
IPSET_DOWNLOAD_FAILURES[${ipset}]=%q\n\
IPSET_VERSION[${ipset}]=%q\n\
IPSET_AVERAGE_UPDATE_TIME[${ipset}]=%q\n\
IPSET_MIN_UPDATE_TIME[${ipset}]=%q\n\
IPSET_MAX_UPDATE_TIME[${ipset}]=%q\n\
IPSET_DOWNLOADER[${ipset}]=%q\n\
IPSET_DOWNLOADER_OPTIONS[${ipset}]=%q\n\
		" \
		"${IPSET_INFO[${ipset}]}" \
		"${IPSET_SOURCE[${ipset}]}" \
		"${IPSET_URL[${ipset}]}" \
		"${IPSET_FILE[${ipset}]}" \
		"${IPSET_IPV[${ipset}]}" \
		"${IPSET_HASH[${ipset}]}" \
		"${IPSET_MINS[${ipset}]}" \
		"${IPSET_HISTORY_MINS[${ipset}]}" \
		"${IPSET_ENTRIES[${ipset}]}" \
		"${IPSET_IPS[${ipset}]}" \
		"${IPSET_SOURCE_DATE[${ipset}]}" \
		"${IPSET_CHECKED_DATE[${ipset}]}" \
		"${IPSET_PROCESSED_DATE[${ipset}]}" \
		"${IPSET_CATEGORY[${ipset}]}" \
		"${IPSET_MAINTAINER[${ipset}]}" \
		"${IPSET_MAINTAINER_URL[${ipset}]}" \
		"${IPSET_LICENSE[${ipset}]}" \
		"${IPSET_GRADE[${ipset}]}" \
		"${IPSET_PROTECTION[${ipset}]}" \
		"${IPSET_INTENDED_USE[${ipset}]}" \
		"${IPSET_FALSE_POSITIVES[${ipset}]}" \
		"${IPSET_POISONING[${ipset}]}" \
		"${IPSET_SERVICES[${ipset}]}" \
		"${IPSET_ENTRIES_MIN[${ipset}]}" \
		"${IPSET_ENTRIES_MAX[${ipset}]}" \
		"${IPSET_IPS_MIN[${ipset}]}" \
		"${IPSET_IPS_MAX[${ipset}]}" \
		"${IPSET_STARTED_DATE[${ipset}]}" \
		"${IPSET_CLOCK_SKEW[${ipset}]}" \
		"${IPSET_DOWNLOAD_FAILURES[${ipset}]}" \
		"${IPSET_VERSION[${ipset}]}" \
		"${IPSET_AVERAGE_UPDATE_TIME[${ipset}]}" \
		"${IPSET_MIN_UPDATE_TIME[${ipset}]}" \
		"${IPSET_MAX_UPDATE_TIME[${ipset}]}" \
		"${IPSET_DOWNLOADER[${ipset}]}" \
		"${IPSET_DOWNLOADER_OPTIONS[${ipset}]}" \
		${NULL}
}

cache_remove_ipset() {
	local ipset="${1}"

	ipset_verbose "${ipset}" "removing from cache"

	unset IPSET_INFO[${ipset}]
	unset IPSET_SOURCE[${ipset}]
	unset IPSET_URL[${ipset}]
	unset IPSET_FILE[${ipset}]
	unset IPSET_IPV[${ipset}]
	unset IPSET_HASH[${ipset}]
	unset IPSET_MINS[${ipset}]
	unset IPSET_HISTORY_MINS[${ipset}]
	unset IPSET_ENTRIES[${ipset}]
	unset IPSET_IPS[${ipset}]
	unset IPSET_SOURCE_DATE[${ipset}]
	unset IPSET_CHECKED_DATE[${ipset}]
	unset IPSET_PROCESSED_DATE[${ipset}]
	unset IPSET_CATEGORY[${ipset}]
	unset IPSET_MAINTAINER[${ipset}]
	unset IPSET_MAINTAINER_URL[${ipset}]
	unset IPSET_LICENSE[${ipset}]
	unset IPSET_GRADE[${ipset}]
	unset IPSET_PROTECTION[${ipset}]
	unset IPSET_INTENDED_USE[${ipset}]
	unset IPSET_FALSE_POSITIVES[${ipset}]
	unset IPSET_POISONING[${ipset}]
	unset IPSET_SERVICES[${ipset}]
	unset IPSET_ENTRIES_MIN[${ipset}]
	unset IPSET_ENTRIES_MAX[${ipset}]
	unset IPSET_IPS_MIN[${ipset}]
	unset IPSET_IPS_MAX[${ipset}]
	unset IPSET_STARTED_DATE[${ipset}]
	unset IPSET_CLOCK_SKEW[${ipset}]
	unset IPSET_DOWNLOAD_FAILURES[${ipset}]
	unset IPSET_VERSION[${ipset}]
	unset IPSET_AVERAGE_UPDATE_TIME[${ipset}]
	unset IPSET_MIN_UPDATE_TIME[${ipset}]
	unset IPSET_MAX_UPDATE_TIME[${ipset}]
	unset IPSET_DOWNLOADER[${ipset}]
	unset IPSET_DOWNLOADER_OPTIONS[${ipset}]

	cache_save
}

ipset_services_to_json_array() {
	local x= i=0
	for x in "${@}"
	do
		i=$[i + 1]
		[ $i -gt 1 ] && printf ", "
		printf "\"%s\"" "${x}"
	done
}

ipset_normalize_for_json() {
	local ipset="${1}"

	ipset_verbose "${ipset}" "normalizing data..."

	[ -z "${IPSET_ENTRIES_MIN[${ipset}]}"         ] && IPSET_ENTRIES_MIN[${ipset}]="${IPSET_ENTRIES[${ipset}]}"
	[ -z "${IPSET_ENTRIES_MAX[${ipset}]}"         ] && IPSET_ENTRIES_MAX[${ipset}]="${IPSET_ENTRIES[${ipset}]}"
	[ -z "${IPSET_IPS_MIN[${ipset}]}"             ] && IPSET_IPS_MIN[${ipset}]="${IPSET_IPS[${ipset}]}"
	[ -z "${IPSET_IPS_MAX[${ipset}]}"             ] && IPSET_IPS_MAX[${ipset}]="${IPSET_IPS[${ipset}]}"
	[ -z "${IPSET_STARTED_DATE[${ipset}]}"        ] && IPSET_STARTED_DATE[${ipset}]="${IPSET_SOURCE_DATE[${ipset}]}"
	[ -z "${IPSET_PROCESSED_DATE[${ipset}]}"      ] && IPSET_PROCESSED_DATE[${ipset}]="${IPSET_SOURCE_DATE[${ipset}]}"
	[ -z "${IPSET_CHECKED_DATE[${ipset}]}"        ] && IPSET_CHECKED_DATE[${ipset}]="${IPSET_PROCESSED_DATE[${ipset}]}"

	[ -z "${IPSET_CLOCK_SKEW[${ipset}]}"          ] && IPSET_CLOCK_SKEW[${ipset}]=0
	[ -z "${IPSET_DOWNLOAD_FAILURES[${ipset}]}"   ] && IPSET_DOWNLOAD_FAILURES[${ipset}]=0

	[ -z "${IPSET_VERSION[${ipset}]}"             ] && IPSET_VERSION[${ipset}]=0
	[ -z "${IPSET_AVERAGE_UPDATE_TIME[${ipset}]}" ] && IPSET_AVERAGE_UPDATE_TIME[${ipset}]=${IPSET_MINS[${ipset}]}
	[ -z "${IPSET_MIN_UPDATE_TIME[${ipset}]}"     ] && IPSET_MIN_UPDATE_TIME[${ipset}]=${IPSET_AVERAGE_UPDATE_TIME[${ipset}]}
	[ -z "${IPSET_MAX_UPDATE_TIME[${ipset}]}"     ] && IPSET_MAX_UPDATE_TIME[${ipset}]=${IPSET_AVERAGE_UPDATE_TIME[${ipset}]}
}

ipset_json() {
	local ipset="${1}" geolite2= ipdeny= ip2location= ipip= comparison= info=

	[ -f "${RUN_DIR}/${ipset}_geolite2_country.json"    ] && geolite2="${ipset}_geolite2_country.json"
	[ -f "${RUN_DIR}/${ipset}_ipdeny_country.json"      ] && ipdeny="${ipset}_ipdeny_country.json"
	[ -f "${RUN_DIR}/${ipset}_ip2location_country.json" ] && ip2location="${ipset}_ip2location_country.json"
	[ -f "${RUN_DIR}/${ipset}_ipip_country.json"        ] && ipip="${ipset}_ipip_country.json"
	[ -f "${RUN_DIR}/${ipset}_comparison.json"          ] && comparison="${ipset}_comparison.json"

	info="${IPSET_INFO[${ipset}]}"
	info="$(echo "${info}" | $SED_CMD "s/)/)\n/g" | $SED_CMD "s|\[\(.*\)\](\(.*\))|<a href=\"\2\">\1</a>|g" | $TR_CMD "\n\t" "  ")"
	info="${info//\"/\\\"}"

	local file_local= commit_history= url=
	if [ -z "${IPSET_TMP_DO_NOT_REDISTRIBUTE[${ipset}]}" ]
		then
		url="${IPSET_URL[${ipset}]}"
		file_local="${LOCAL_COPY_URL}${IPSET_FILE[${ipset}]}"
		commit_history="${GITHUB_CHANGES_URL}${IPSET_FILE[${ipset}]}"
	fi

	ipset_normalize_for_json "${ipset}"

	ipset_verbose "${ipset}" "generating JSON info..."

	$CAT_CMD <<EOFJSON
{
	"name": "${ipset}",
	"entries": ${IPSET_ENTRIES[${ipset}]},
	"entries_min": ${IPSET_ENTRIES_MIN[${ipset}]},
	"entries_max": ${IPSET_ENTRIES_MAX[${ipset}]},
	"ips": ${IPSET_IPS[${ipset}]},
	"ips_min": ${IPSET_IPS_MIN[${ipset}]},
	"ips_max": ${IPSET_IPS_MAX[${ipset}]},
	"ipv": "${IPSET_IPV[${ipset}]}",
	"hash": "${IPSET_HASH[${ipset}]}",
	"frequency": ${IPSET_MINS[${ipset}]},
	"aggregation": ${IPSET_HISTORY_MINS[${ipset}]},
	"started": ${IPSET_STARTED_DATE[${ipset}]}000,
	"updated": ${IPSET_SOURCE_DATE[${ipset}]}000,
	"processed": ${IPSET_PROCESSED_DATE[${ipset}]}000,
	"checked": ${IPSET_CHECKED_DATE[${ipset}]}000,
	"clock_skew": $[ IPSET_CLOCK_SKEW[${ipset}] * 1000 ],
	"category": "${IPSET_CATEGORY[${ipset}]}",
	"maintainer": "${IPSET_MAINTAINER[${ipset}]}",
	"maintainer_url": "${IPSET_MAINTAINER_URL[${ipset}]}",
	"info": "${info}",
	"source": "${url}",
	"file": "${IPSET_FILE[${ipset}]}",
	"history": "${ipset}_history.csv",
	"geolite2": "${geolite2}",
	"ipdeny": "${ipdeny}",
	"ip2location": "${ip2location}",
	"ipip": "${ipip}",
	"comparison": "${comparison}",
	"file_local": "${file_local}",
	"commit_history": "${commit_history}",
	"license": "${IPSET_LICENSE[${ipset}]}",
	"grade": "${IPSET_GRADE[${ipset}]}",
	"protection": "${IPSET_PROTECTION[${ipset}]}",
	"intended_use": "${IPSET_INTENDED_USE[${ipset}]}",
	"false_positives": "${IPSET_FALSE_POSITIVES[${ipset}]}",
	"poisoning": "${IPSET_POISONING[${ipset}]}",
	"services": [ $(ipset_services_to_json_array ${IPSET_SERVICES[${ipset}]}) ],
	"errors": ${IPSET_DOWNLOAD_FAILURES[${ipset}]},
	"version": ${IPSET_VERSION[${ipset}]},
	"average_update": ${IPSET_AVERAGE_UPDATE_TIME[${ipset}]},
	"min_update": ${IPSET_MIN_UPDATE_TIME[${ipset}]},
	"max_update": ${IPSET_MAX_UPDATE_TIME[${ipset}]},
	"downloader": "${IPSET_DOWNLOADER[${ipset}]}"
}
EOFJSON
}

ipset_json_index() {
	local ipset="${1}" checked=

	ipset_normalize_for_json "${ipset}"

	checked=${IPSET_CHECKED_DATE[${ipset}]}
	[ ${IPSET_CHECKED_DATE[${ipset}]} -lt ${IPSET_PROCESSED_DATE[${ipset}]} ] && checked=${IPSET_PROCESSED_DATE[${ipset}]}

	ipset_verbose "${ipset}" "generating JSON index..."

$CAT_CMD <<EOFALL
	{
		"ipset": "${ipset}",
		"category": "${IPSET_CATEGORY[${ipset}]}",
		"maintainer": "${IPSET_MAINTAINER[${ipset}]}",
		"started": ${IPSET_STARTED_DATE[${ipset}]}000,
		"updated": ${IPSET_SOURCE_DATE[${ipset}]}000,
		"checked": ${checked}000,
		"clock_skew": $[ IPSET_CLOCK_SKEW[${ipset}] * 1000 ],
		"ips": ${IPSET_IPS[${ipset}]},
		"errors": ${IPSET_DOWNLOAD_FAILURES[${ipset}]}
EOFALL
printf "	}"
}

# array to store hourly retention of past IPs
declare -a RETENTION_HISTOGRAM=()

# array to store hourly age of currently listed IPs
declare -a RETENTION_HISTOGRAM_REST=()

# the timestamp we started monitoring this ipset
declare RETENTION_HISTOGRAM_STARTED=

# if set to 0, the ipset has been completely refreshed
# i.e. all IPs have been removed / recycled at least once
declare RETENTION_HISTOGRAM_INCOMPLETE=1

# should only be called from retention_detect()
# because it needs the RETENTION_HISTOGRAM array loaded
retention_print() {
	local ipset="${1}"

	printf "{\n	\"ipset\": \"${ipset}\",\n	\"started\": ${RETENTION_HISTOGRAM_STARTED}000,\n	\"updated\": ${IPSET_SOURCE_DATE[${ipset}]}000,\n	\"incomplete\": ${RETENTION_HISTOGRAM_INCOMPLETE},\n"

	ipset_verbose "${ipset}" "calculating retention hours..."
	local x= hours= ips= sum=0 pad="\n\t\t\t"
	for x in "${!RETENTION_HISTOGRAM[@]}"
	do
		(( sum += ${RETENTION_HISTOGRAM[${x}]} ))
		hours="${hours}${pad}${x}"
		ips="${ips}${pad}${RETENTION_HISTOGRAM[${x}]}"
		pad=",\n\t\t\t"
	done
	printf "	\"past\": {\n		\"hours\": [ ${hours} ],\n		\"ips\": [ ${ips} ],\n		\"total\": ${sum}\n	},\n"

	ipset_verbose "${ipset}" "calculating current hours..."
	local x= hours= ips= sum=0 pad="\n\t\t\t"
	for x in "${!RETENTION_HISTOGRAM_REST[@]}"
	do
		(( sum += ${RETENTION_HISTOGRAM_REST[${x}]} ))
		hours="${hours}${pad}${x}"
		ips="${ips}${pad}${RETENTION_HISTOGRAM_REST[${x}]}"
		pad=",\n\t\t\t"
	done
	printf "	\"current\": {\n		\"hours\": [ ${hours} ],\n		\"ips\": [ ${ips} ],\n		\"total\": ${sum}\n	}\n}\n"
}

retention_detect() {
	cd "${BASE_DIR}" || return 1

	local ipset="${1}"

	# can we do it?
	[ -z "${IPSET_FILE[${ipset}]}" -o -z "${LIB_DIR}" -o ! -d "${LIB_DIR}" ] && return 1

	# load the ipset retention histogram
	RETENTION_HISTOGRAM=()
	RETENTION_HISTOGRAM_REST=()
	RETENTION_HISTOGRAM_STARTED="${IPSET_SOURCE_DATE[${ipset}]}"
	RETENTION_HISTOGRAM_INCOMPLETE=1

	if [ -f "${LIB_DIR}/${ipset}/histogram" ]
		then
		ipset_verbose "${ipset}" "loading old data"
		source "${LIB_DIR}/${ipset}/histogram"
	fi

	ndate=$($DATE_CMD -r "${IPSET_FILE[${ipset}]}" +%s)
	ipset_silent "${ipset}" "generating histogram for ${ndate} update..."

	# create the cache directory for this ipset
	if [ ! -d "${LIB_DIR}/${ipset}" ]
		then
		$MKDIR_CMD -p "${LIB_DIR}/${ipset}" || return 2
	fi

	if [ ! -d "${LIB_DIR}/${ipset}/new" ]
		then
		$MKDIR_CMD -p "${LIB_DIR}/${ipset}/new" || return 2
	fi

	if [ ! -f "${LIB_DIR}/${ipset}/latest" ]
		then
		# we don't have an older version
		ipset_verbose "${ipset}" "this is a new ipset - initializing"

		$TOUCH_CMD -r "${IPSET_FILE[${ipset}]}" "${LIB_DIR}/${ipset}/latest"
		RETENTION_HISTOGRAM_STARTED="${IPSET_SOURCE_DATE[${ipset}]}"

	elif [ ! "${IPSET_FILE[${ipset}]}" -nt "${LIB_DIR}/${ipset}/latest" ]
		# the new file is older than the latest, return
		then
		ipset_verbose "${ipset}" "new ipset file is not newer than latest"
		retention_print "${ipset}"
		return 0
	fi

	if [ -f "${LIB_DIR}/${ipset}/new/${ndate}" ]
		then
		# we already have a file for this date, return
		ipset_warning "${ipset}" "we already have a file for date ${ndate}"
		retention_print "${ipset}"
		return 0
	fi

	# find the new ips in this set
	ipset_verbose "${ipset}" "finding the new IPs in this update..."
	${IPRANGE_CMD} "${IPSET_FILE[${ipset}]}" --exclude-next "${LIB_DIR}/${ipset}/latest" --print-binary >"${LIB_DIR}/${ipset}/new/${ndate}" || ipset_error "${ipset}" "cannot find the new IPs in this update."
	$TOUCH_CMD -r "${IPSET_FILE[${ipset}]}" "${LIB_DIR}/${ipset}/new/${ndate}"

	local ips_added=0
	if [ ! -s "${LIB_DIR}/${ipset}/new/${ndate}" ]
		then
		# there are no new IPs included
		ipset_verbose "${ipset}" "no new IPs in this update"
		$RM_CMD "${LIB_DIR}/${ipset}/new/${ndate}"
	else
		ips_added=$(${IPRANGE_CMD} -C "${LIB_DIR}/${ipset}/new/${ndate}")
		ips_added=${ips_added/*,/}
		ipset_verbose "${ipset}" "added ${ips_added} new IPs"
	fi

	ipset_verbose "${ipset}" "finding the removed IPs in this update..."
	local ips_removed=$(${IPRANGE_CMD} "${LIB_DIR}/${ipset}/latest" --exclude-next "${IPSET_FILE[${ipset}]}" | ${IPRANGE_CMD} -C)
	ips_removed=${ips_removed/*,/}
	ipset_verbose "${ipset}" "removed ${ips_removed} IPs"

	ipset_silent "${ipset}" "added ${ips_added}, removed ${ips_removed} unique IPs"

	ipset_verbose "${ipset}" "saving in changesets (${ndate})"
	[ ! -f "${LIB_DIR}/${ipset}/changesets.csv" ] && echo >"${LIB_DIR}/${ipset}/changesets.csv" "DateTime,IPsAdded,IPsRemoved"
	echo >>"${LIB_DIR}/${ipset}/changesets.csv" "${ndate},${ips_added},${ips_removed}"

	# ok keep it
	ipset_silent "${ipset}" "keeping this update as the latest..."
	${IPRANGE_CMD} "${IPSET_FILE[${ipset}]}" --print-binary >"${LIB_DIR}/${ipset}/latest" || ipset_error "${ipset}" "failed to keep the ${ndate} update as the latest"
	$TOUCH_CMD -r "${IPSET_FILE[${ipset}]}" "${LIB_DIR}/${ipset}/latest"

	if [ ! -f "${LIB_DIR}/${ipset}/retention.csv" ]
		then
		ipset_verbose "${ipset}" "generating the retention file"
		echo "date_removed,date_added,hours,ips" >"${LIB_DIR}/${ipset}/retention.csv"
	fi

	# -------------------------------------------------------------------------

	ipset_silent "${ipset}" "comparing this update against all past"

	# find the new/* files that are affected
	local -a new_files=("${LIB_DIR}/${ipset}/new"/*)
	local name1= name2= entries1= entries2= ips1= ips2= combined= common= odate= hours= removed=
	if [ ${#new_files[@]} -gt 0 ]
		then
		# we are searching for the affected files
		# to find them we compare:
		#
		# > ips1 (the number of IPs in the latest)
		# > combined (the number of IPs in both the latest and the history file in question)
		#   when ips1 = combined, all IPs in the history file in question are still in the latest
		#
		# > ips2 (the number of IPs in the history file in question)
		# > common (the IPs common in latest and the history file in question)
		#   when ips2 = common, all IPs in the history file in question are still in the latest
		#
		${IPRANGE_CMD} "${LIB_DIR}/${ipset}/latest" --compare-next "${new_files[@]}" |\
			while IFS="," read name1 name2 entries1 entries2 ips1 ips2 combined common
			do
				[ $[ combined - ips1 ] -ne 0 -o $[ ips2 - common ] -ne 0 ] && echo "${name2}"
			done | $SORT_CMD -u >"${RUN_DIR}/retention_affected_updates"

		[ $? -ne 0 ] && ipset_error "${ipset}" "cannot find its affected updates"
	else
		[ -f "${RUN_DIR}/retention_affected_updates" ] && ${RM_CMD} "${RUN_DIR}/retention_affected_updates"
		${TOUCH_CMD} "${RUN_DIR}/retention_affected_updates"
	fi

	local x=
	for x in $($CAT_CMD "${RUN_DIR}/retention_affected_updates")
	do
		# find how many hours have passed
		odate="${x/*\//}"
		hours=$[ (ndate + 1800 - odate) / 3600 ]

		# are all the IPs of this file still the latest?
		${IPRANGE_CMD} --common "${x}" "${LIB_DIR}/${ipset}/latest" --print-binary >"${x}.stillthere" || ipset_error "${ipset}" "cannot find IPs still present in ${x}"
		${IPRANGE_CMD} "${x}" --exclude-next "${x}.stillthere" --print-binary >"${x}.removed" || ipset_error "${ipset}" "cannot find IPs removed from ${x}"
		if [ -s "${x}.removed" ]
			then
			# no, something removed, find it
			removed=$(${IPRANGE_CMD} -C "${x}.removed")
			$RM_CMD "${x}.removed"

			# these are the unique IPs removed
			removed="${removed/*,/}"
			ipset_verbose "${ipset}" "${x}: ${removed} IPs removed"

			echo "${ndate},${odate},${hours},${removed}" >>"${LIB_DIR}/${ipset}/retention.csv"

			# update the histogram
			# only if the date added is after the date we started
			[ ${odate} -gt ${RETENTION_HISTOGRAM_STARTED} ] && RETENTION_HISTOGRAM[${hours}]=$[ ${RETENTION_HISTOGRAM[${hours}]} + removed ]
		else
			removed=0
			# yes, nothing removed from this run
			ipset_verbose "${ipset}" "${x}: nothing removed"
			$RM_CMD "${x}.removed"
		fi

		# check if there is something still left
		if [ ! -s "${x}.stillthere" ]
			then
			# nothing left for this timestamp, remove files
			ipset_verbose "${ipset}" "${x}: nothing left in this"
			$RM_CMD "${x}" "${x}.stillthere"
		else
			ipset_verbose "${ipset}" "${x}: there is still something in it"
			$TOUCH_CMD -r "${x}" "${x}.stillthere"
			$MV_CMD "${x}.stillthere" "${x}" || ipset_error "${ipset}" "cannot replace ${x} with updated data"
		fi
	done

	ipset_verbose "${ipset}" "cleaning up retention cache..."
	# cleanup empty slots in our arrays
	for x in "${!RETENTION_HISTOGRAM[@]}"
	do
		if [ $[ RETENTION_HISTOGRAM[${x}] ] -eq 0 ]
			then
			unset RETENTION_HISTOGRAM[${x}]
		fi
	done

	# -------------------------------------------------------------------------

	ipset_verbose "${ipset}" "determining the age of currently listed IPs..."

	if [ "${#RETENTION_HISTOGRAM[@]}" -eq 0 ]
		then
		RETENTION_HISTOGRAM=()
	fi

	# empty the remaining IPs counters
	# they will be re-calculated below
	RETENTION_HISTOGRAM_REST=()
	RETENTION_HISTOGRAM_INCOMPLETE=0

	# find the IPs in all new/*
	local -a new_files=("${LIB_DIR}/${ipset}/new"/*)
	if [ "${#new_files[@]}" -gt 0 ]
		then
		${IPRANGE_CMD} --count-unique-all "${new_files[@]}" >"${RUN_DIR}/retention_rest" 2>/dev/null
	else
		[ -f "${RUN_DIR}/retention_rest" ] && ${RM_CMD} "${RUN_DIR}/retention_rest"
		${TOUCH_CMD} "${RUN_DIR}/retention_rest"
	fi

	local entries= ips=
	while IFS="," read x entries ips
	do
		odate="${x/*\//}"
		hours=$[ (ndate + 1800 - odate) / 3600 ]
		ipset_verbose "${ipset}" "${x}: ${hours} hours have passed"

		[ ${odate} -le ${RETENTION_HISTOGRAM_STARTED} ] && RETENTION_HISTOGRAM_INCOMPLETE=1

		RETENTION_HISTOGRAM_REST[${hours}]=$[ ${RETENTION_HISTOGRAM_REST[${hours}]} + ips ]
	done <"${RUN_DIR}/retention_rest"

	# -------------------------------------------------------------------------

	# save the histogram
	ipset_verbose "${ipset}" "saving retention cache..."
	declare -p RETENTION_HISTOGRAM_STARTED RETENTION_HISTOGRAM_INCOMPLETE RETENTION_HISTOGRAM RETENTION_HISTOGRAM_REST >"${LIB_DIR}/${ipset}/histogram"

	ipset_verbose "${ipset}" "printing retention..."
	retention_print "${ipset}"

	ipset_verbose "${ipset}" "printed retention histogram"
	return 0
}

sitemap_init() {
	local sitemap_date="${1}"

$CAT_CMD >${RUN_DIR}/sitemap.xml <<EOFSITEMAPA
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
	<url>
		<loc>${WEB_URL/\?*/}</loc>
		<lastmod>${sitemap_date}</lastmod>
		<changefreq>always</changefreq>
	</url>
EOFSITEMAPA
}

sitemap_ipset() {
	local ipset="${1}" sitemap_date="${2}"

$CAT_CMD >>"${RUN_DIR}/sitemap.xml" <<EOFSITEMAP1
	<url>
		<loc>${WEB_URL}${ipset}</loc>
		<lastmod>${sitemap_date}</lastmod>
		<changefreq>always</changefreq>
	</url>
EOFSITEMAP1
}

history_statistics() {
	# the file should be in this format:
	# DateTime,Entries,IPs

	local 	ipset="${1}" file="${2}" \
			xdate xentries xips \
			xlast xdt \
			xavg xlo xhi xelo xehi xilo xihi \
			xtotal=0 count=0

	# calculate the average update time of the list
	# and the min/max entries and IPs
	while IFS="," read xdate xentries xips
	do
		# skip the header
		[ "${xdate}" = "DateTime" ] && continue

		# skip invalids
		[  $[xdate] -le 0 ] && continue

		# the first valid entry
		# set xlast and the lo/hi entries and IPs
		if [ ${count} -eq 0 ]
			then
			xlast=${xdate}
			xelo=${xentries}
			xehi=${xentries}
			xilo=${xips}
			xihi=${xips}
			count=$[count + 1]
			continue
		fi

		# skip entries that are not in the valid order
		# in this case, the new date is older than the last
		[ $[xdate] -le $[xlast] ] && continue

		# calculate the time diff
		xdt=$[ xdate - xlast ]
		[ ${xdt} -le 0 ] && continue

		# the second line
		# set the lo/hi dt
		if [ ${count} -eq 1 ]
			then
			xlo=${xdt}
			xhi=${xdt}
		fi

		# for all the rest of the lines
		xtotal=$[ xtotal + xdt ]
		xlast=${xdate}

		count=$[ count + 1 ]

		# dt
		[ ${xdt} -lt ${xlo} ] && xlo=${xdt}
		[ ${xdt} -gt ${xhi} ] && xhi=${xdt}

		# entries
		[ ${xentries} -lt ${xelo} ] && xelo=${xentries}
		[ ${xentries} -gt ${xehi} ] && xehi=${xentries}

		# IPs
		[ ${xips} -lt ${xilo} ] && xilo=${xips}
		[ ${xips} -gt ${xihi} ] && xihi=${xips}

	done <"${file}"

	local update_mins=$[ IPSET_MINS[${ipset}] ]

	# the average update time, in minutes
	if [ ${count} -eq 1 ]
		then
		xavg=${update_mins}
	else
		xavg=$[(xtotal / (count - 1) + 60) / 60]
	fi

	# the lo/hi update time, in minutes
	xlo=$[(xlo + 60) / 60]
	xhi=$[(xhi + 60) / 60]

	IPSET_AVERAGE_UPDATE_TIME[${ipset}]=$[xavg]
	IPSET_MIN_UPDATE_TIME[${ipset}]=$[xlo]
	IPSET_MAX_UPDATE_TIME[${ipset}]=$[xhi]
	ipset_silent "${ipset}" "last ${count} updates: avg: ${xavg} mins (${xlo} - ${xhi}) - config: ${update_mins} mins"

	IPSET_ENTRIES_MIN[${ipset}]=$[xelo]
	IPSET_ENTRIES_MAX[${ipset}]=$[xehi]
	IPSET_IPS_MIN[${ipset}]=$[xilo]
	IPSET_IPS_MAX[${ipset}]=$[xihi]
	ipset_silent "${ipset}" "entries: ${xelo} to ${xehi}, IPs: ${xilo} to ${xihi}"

	# if the list is downloaded, try to figure out
	# if we download it too frequently or too late
	if [ ! -z "${IPSET_URL[${ipset}]}" -a ${count} -gt $[WEB_CHARTS_ENTRIES / 10] ]
		then
		if [ $[xavg] -lt $[ update_mins * 5 / 4 ] ]
			then
			ipset_warning "${ipset}" "may need to lower update freq from ${update_mins} to $[ xavg * 2 / 3 ] mins"
		elif [ $[xavg] -gt $[ update_mins * 3 ] ]
			then
			ipset_warning "${ipset}" "may need to increase update freq from ${update_mins} to $[ update_mins * 3 / 2 ] mins"
		fi
	fi

	return 0
}

update_web() {
	cd "${BASE_DIR}" || return 1

	print_ipset_reset
	echo >&2

	if [ -z "${WEB_DIR}" -o ! -d "${WEB_DIR}" -o -z "${LIB_DIR}" -o ! -d "${LIB_DIR}" ]
		then
		return 1
	fi

	if [ "${#UPDATED_SETS[@]}" -eq 0 -a ! ${FORCE_WEB_REBUILD} -eq 1 ]
		then
		echo >&2 "Not updating web site - nothing updated in this run."
		return 1
	fi

	local all=() updated=() geolite2_country=() ipdeny_country=() ip2location_country=() ipip_country=() \
		x= i= to_all= all_count=0 \
		sitemap_date="$($DATE_CMD -I)"

	# the sitemap is re-generated on each run
	sitemap_init "${sitemap_date}"

	echo >&2 "-------------------------------------------------------------------------------"
	echo >&2 "Updating History..."

	for x in $(params_sort "${!IPSET_FILE[@]}")
	do
		if [ -z "${IPSET_FILE[$x]}" ]
			then
			ipset_warning "${x}" "empty filename - skipping it"
			continue
		fi

		# remove deleted files
		if [ ! -f "${IPSET_FILE[$x]}" ]
			then
			ipset_warning "${x}" "file ${IPSET_FILE[$x]} not found - removing it from cache"
			cache_remove_ipset "${x}"
			continue
		fi

		## check if it has been updated in a previous run
		## and has not been copied to our cache
		#if [ -z "${UPDATED_SETS[${x}]}" -a -f "${LIB_DIR}/${x}/latest" -a "${IPSET_FILE[$x]}" -nt "${LIB_DIR}/${x}/latest" ]
		#	then
		#	silent "${x}: found unupdated cache $($DATE_CMD -r "${IPSET_FILE[$x]}" +%s) vs $($DATE_CMD -r "${LIB_DIR}/${x}/latest" +%s)"
		#	# UPDATED_SETS[${x}]="${IPSET_FILE[$x]}"
		#fi

		if [ ! -d "${LIB_DIR}/${x}" ]
			then
			ipset_silent "${x}" "creating lib directory for tracking it"
			$MKDIR_CMD -p "${LIB_DIR}/${x}" || continue
		fi

		# update the history CSV files
		if [ ! -z "${UPDATED_SETS[${x}]}" -o ! -f "${LIB_DIR}/${x}/history.csv" ]
			then
			if [ ! -f "${LIB_DIR}/${x}/history.csv" ]
				then
				ipset_verbose "${x}" "creating history file header"
				echo "DateTime,Entries,UniqueIPs" >"${LIB_DIR}/${x}/history.csv"
				# $TOUCH_CMD "${LIB_DIR}/${x}/history.csv"
				$CHMOD_CMD 0644 "${LIB_DIR}/${x}/history.csv"
			fi

			ipset_silent "${x}" "entries: ${IPSET_ENTRIES[${x}]}, unique IPs: ${IPSET_IPS[${x}]}"
			echo >>"${LIB_DIR}/${x}/history.csv" "$($DATE_CMD -r "${IPSET_SOURCE[${x}]}" +%s),${IPSET_ENTRIES[${x}]},${IPSET_IPS[${x}]}"

			ipset_verbose "${x}" "preparing web history file (last ${WEB_CHARTS_ENTRIES} entries)"
			echo >"${RUN_DIR}/${x}_history.csv" "DateTime,Entries,UniqueIPs"
			$TAIL_CMD -n ${WEB_CHARTS_ENTRIES} "${LIB_DIR}/${x}/history.csv" | $GREP_CMD -v "^DateTime" | $SORT_CMD -n >>"${RUN_DIR}/${x}_history.csv"

			history_statistics "${x}" "${RUN_DIR}/${x}_history.csv"
		fi

		to_all=1

		# prepare the parameters for iprange to compare the sets
		if [[ "${IPSET_FILE[$x]}" =~ ^geolite2.* ]]
			then
			ipset_verbose "${x}" "is a GeoLite2 file"
			to_all=0
			case "${x}" in
				country_*)		i=${x/country_/} ;;
				continent_*)	i= ;;
				anonymous)		to_all=1; i= ;;
				satellite)		to_all=1; i= ;;
				*)				i= ;;
			esac
			[ ! -z "${i}" ] && geolite2_country=("${geolite2_country[@]}" "${IPSET_FILE[$x]}" "as" "${i^^}")

		elif [[ "${IPSET_FILE[$x]}" =~ ^ipdeny_country.* ]]
			then
			ipset_verbose "${x}" "is an IPDeny file"
			to_all=0
			case "${x}" in
				id_country_*)	i=${x/id_country_/} ;;
				id_continent_*)	i= ;;
				*)				i= ;;
			esac
			[ ! -z "${i}" ] && ipdeny_country=("${ipdeny_country[@]}" "${IPSET_FILE[$x]}" "as" "${i^^}")

		elif [[ "${IPSET_FILE[$x]}" =~ ^ip2location_country.* ]]
			then
			ipset_verbose "${x}" "is an IP2Location file"
			to_all=0
			case "${x}" in
				ip2location_country_*)		i=${x/ip2location_country_/} ;;
				ip2location_continent_*)	i= ;;
				*)							i= ;;
			esac
			[ ! -z "${i}" ] && ip2location_country=("${ip2location_country[@]}" "${IPSET_FILE[$x]}" "as" "${i^^}")

		elif [[ "${IPSET_FILE[$x]}" =~ ^ipip_country.* ]]
			then
			ipset_verbose "${x}" "is an IPIP file"
			to_all=0
			case "${x}" in
				ipip_country_*)				i=${x/ipip_country_/} ;;
				ipip_continent_*)			i= ;;
				*)							i= ;;
			esac
			[ ! -z "${i}" ] && ipip_country=("${ipip_country[@]}" "${IPSET_FILE[$x]}" "as" "${i^^}")
		fi

		if [ ${to_all} -eq 1 ]
			then
			cache_save_metadata_backup "${x}"

			ipset_verbose "${x}" "ipset will be compared with all others"
			all=("${all[@]}" "${IPSET_FILE[$x]}" "as" "${x}")
			all_count=$[ all_count + 1 ]

			# if we need a full rebuild, pretend all are updated
			[ ${FORCE_WEB_REBUILD} -eq 1 ] && UPDATED_SETS[${x}]="${IPSET_FILE[${x}]}"

			if [ ! -z "${UPDATED_SETS[${x}]}" ]
				then
				ipset_verbose "${x}" "ipset has been updated in this run"
				updated=("${updated[@]}" "${IPSET_FILE[$x]}" "as" "${x}")
			fi

			ipset_verbose "${x}" "adding ipset to web all-ipsets.json"
			if [ ! -f "${RUN_DIR}/all-ipsets.json" ]
				then
				printf >"${RUN_DIR}/all-ipsets.json" "[\n"
			else
				printf >>"${RUN_DIR}/all-ipsets.json" ",\n"
			fi
			ipset_json_index "${x}" >>"${RUN_DIR}/all-ipsets.json"
			sitemap_ipset "${x}" "${sitemap_date}"
		fi
	done
	printf >>"${RUN_DIR}/all-ipsets.json" "\n]\n"
	echo '</urlset>' >>"${RUN_DIR}/sitemap.xml"
	echo >&2

	# to save the calculated IPSET_*_UPDATE_TIME
	cache_save

	#info "ALL: ${all[@]}"
	#info "UPDATED: ${updated[@]}"

	print_ipset_reset

	echo >&2 "-------------------------------------------------------------------------------"
	echo >&2 "Comparing all ipsets (${all_count} x ${all_count} = $[all_count * (all_count - 1) / 2 - 1] unique comparisons)..."

	local before=$($DATE_CMD +%s)
	${IPRANGE_CMD} --compare "${all[@]}" |\
		${GREP_CMD} -v ",0$" |\
		$SORT_CMD |\
		while IFS="," read name1 name2 entries1 entries2 ips1 ips2 combined common
		do
			if [ ! -f "${RUN_DIR}/${name1}_comparison.json" ]
				then
				printf >"${RUN_DIR}/${name1}_comparison.json" "[\n"
			else
				printf >>"${RUN_DIR}/${name1}_comparison.json" ",\n"
			fi
			printf >>"${RUN_DIR}/${name1}_comparison.json" "	{\n		\"name\": \"${name2}\",\n		\"category\": \"${IPSET_CATEGORY[${name2}]}\",\n		\"ips\": ${ips2},\n		\"common\": ${common}\n	}"

			if [ ! -f "${RUN_DIR}/${name2}_comparison.json" ]
				then
				printf >"${RUN_DIR}/${name2}_comparison.json" "[\n"
			else
				printf >>"${RUN_DIR}/${name2}_comparison.json" ",\n"
			fi
			printf >>"${RUN_DIR}/${name2}_comparison.json" "	{\n		\"name\": \"${name1}\",\n		\"category\": \"${IPSET_CATEGORY[${name1}]}\",\n		\"ips\": ${ips1},\n		\"common\": ${common}\n	}"
		done
	for x in $($FIND_CMD "${RUN_DIR}" -name \*_comparison.json)
	do
		printf "\n]\n" >>${x}
	done
	local after=$($DATE_CMD +%s)
	[ ${after} -eq ${before} ] && after=$[before + 1]

	echo >&2 "$[all_count * (all_count - 1) / 2 - 1] ipset comparisons made in $[after - before] seconds ($[(all_count * (all_count - 1) / 2 - 1) / (after - before)] ipset comparisons/s)"
	echo >&2

	if [ "${#updated[*]}" -ne 0 -a "${#geolite2_country[*]}" -ne 0 ]
		then
		print_ipset_reset

		echo >&2 "-------------------------------------------------------------------------------"
		echo >&2 "Comparing updated ipsets with GeoLite2 country..."

		${IPRANGE_CMD} "${updated[@]}" --compare-next "${geolite2_country[@]}" |\
			${GREP_CMD} -v ",0$" |\
			$SORT_CMD |\
			while IFS="," read name1 name2 entries1 entries2 ips1 ips2 combined common
			do
				if [ ! -f "${RUN_DIR}/${name1}_geolite2_country.json" ]
					then
					printf "[\n" >"${RUN_DIR}/${name1}_geolite2_country.json"
				else
					printf ",\n" >>"${RUN_DIR}/${name1}_geolite2_country.json"
				fi

				printf "	{\n		\"code\": \"${name2}\",\n		\"value\": ${common}\n	}" >>"${RUN_DIR}/${name1}_geolite2_country.json"
			done
		echo >&2
		for x in $($FIND_CMD "${RUN_DIR}" -name \*_geolite2_country.json)
		do
			printf "\n]\n" >>${x}
		done
	fi

	if [ "${#updated[*]}" -ne 0 -a "${#ipdeny_country[*]}" -ne 0 ]
		then
		echo >&2 "-------------------------------------------------------------------------------"
		echo >&2 "Comparing updated ipsets with IPDeny country..."

		${IPRANGE_CMD} "${updated[@]}" --compare-next "${ipdeny_country[@]}" |\
			${GREP_CMD} -v ",0$" |\
			$SORT_CMD |\
			while IFS="," read name1 name2 entries1 entries2 ips1 ips2 combined common
			do
				if [ ! -f "${RUN_DIR}/${name1}_ipdeny_country.json" ]
					then
					printf "[\n" >"${RUN_DIR}/${name1}_ipdeny_country.json"
				else
					printf ",\n" >>"${RUN_DIR}/${name1}_ipdeny_country.json"
				fi

				printf "	{\n		\"code\": \"${name2}\",\n		\"value\": ${common}\n	}" >>"${RUN_DIR}/${name1}_ipdeny_country.json"
			done
		echo >&2
		for x in $($FIND_CMD "${RUN_DIR}" -name \*_ipdeny_country.json)
		do
			printf "\n]\n" >>${x}
		done
	fi

	if [ "${#updated[*]}" -ne 0 -a "${#ip2location_country[*]}" -ne 0 ]
		then
		print_ipset_reset

		echo >&2 "-------------------------------------------------------------------------------"
		echo >&2 "Comparing updated ipsets with IP2Location country..."

		${IPRANGE_CMD} "${updated[@]}" --compare-next "${ip2location_country[@]}" |\
			${GREP_CMD} -v ",0$" |\
			$SORT_CMD |\
			while IFS="," read name1 name2 entries1 entries2 ips1 ips2 combined common
			do
				if [ ! -f "${RUN_DIR}/${name1}_ip2location_country.json" ]
					then
					printf "[\n" >"${RUN_DIR}/${name1}_ip2location_country.json"
				else
					printf ",\n" >>"${RUN_DIR}/${name1}_ip2location_country.json"
				fi

				printf "	{\n		\"code\": \"${name2}\",\n		\"value\": ${common}\n	}" >>"${RUN_DIR}/${name1}_ip2location_country.json"
			done
		echo >&2
		for x in $($FIND_CMD "${RUN_DIR}" -name \*_ip2location_country.json)
		do
			printf "\n]\n" >>${x}
		done
	fi

	if [ "${#updated[*]}" -ne 0 -a "${#ipip_country[*]}" -ne 0 ]
		then
		print_ipset_reset

		echo >&2 "-------------------------------------------------------------------------------"
		echo >&2 "Comparing updated ipsets with IPIP country..."

		${IPRANGE_CMD} "${updated[@]}" --compare-next "${ipip_country[@]}" |\
			${GREP_CMD} -v ",0$" |\
			$SORT_CMD |\
			while IFS="," read name1 name2 entries1 entries2 ips1 ips2 combined common
			do
				if [ ! -f "${RUN_DIR}/${name1}_ipip_country.json" ]
					then
					printf "[\n" >"${RUN_DIR}/${name1}_ipip_country.json"
				else
					printf ",\n" >>"${RUN_DIR}/${name1}_ipip_country.json"
				fi

				printf "	{\n		\"code\": \"${name2}\",\n		\"value\": ${common}\n	}" >>"${RUN_DIR}/${name1}_ipip_country.json"
			done
		echo >&2
		for x in $($FIND_CMD "${RUN_DIR}" -name \*_ipip_country.json)
		do
			printf "\n]\n" >>${x}
		done
	fi

	echo >&2 "-------------------------------------------------------------------------------"
	echo >&2 "Generating updated ipsets JSON files..."

	print_ipset_reset

	for x in $(params_sort "${!UPDATED_SETS[@]}")
	do
		ipset_json "${x}" >"${RUN_DIR}/${x}.json"
	done
	echo >&2

	echo >&2 "-------------------------------------------------------------------------------"
	echo >&2 "Generating retention histograms for updated ipsets..."

	print_ipset_reset

	for x in $(params_sort "${!UPDATED_SETS[@]}")
	do
		[[ "${IPSET_FILE[$x]}" =~ ^geolite2.* ]] && continue
		[[ "${IPSET_FILE[$x]}" =~ ^ipdeny.* ]] && continue
		[[ "${IPSET_FILE[$x]}" =~ ^ip2location.* ]] && continue
		[[ "${IPSET_FILE[$x]}" =~ ^ipip.* ]] && continue

		retention_detect "${x}" >"${RUN_DIR}/${x}_retention.json" || $RM_CMD "${RUN_DIR}/${x}_retention.json"

		# this has to be done after retention_detect()
		echo >"${RUN_DIR}"/${x}_changesets.csv "DateTime,AddedIPs,RemovedIPs"
		$TAIL_CMD -n $[ WEB_CHARTS_ENTRIES + 1] "${LIB_DIR}/${x}/changesets.csv" | $GREP_CMD -v "^DateTime" | $TAIL_CMD -n +2 >>"${RUN_DIR}/${x}_changesets.csv"
	done
	echo >&2

	echo >&2 "-------------------------------------------------------------------------------"
	echo >&2 "Saving generated web files..."

	print_ipset_reset

	$CHMOD_CMD 0644 "${RUN_DIR}"/*.{json,csv,xml}
	$MV_CMD -f "${RUN_DIR}"/*.{json,csv,xml} "${WEB_DIR}/"
	[ ! -z "${WEB_OWNER}" ] && $CHOWN_CMD ${WEB_OWNER} "${WEB_DIR}"/*.{json,csv,xml}

}

ipset_apply_counter=0
ipset_apply() {
	local ipset="${1}" ipv="${2}" hash="${3}" file="${4}" entries= tmpname= opts= ret= ips=

	if [ ${IPSETS_APPLY} -eq 0 ]
		then
		ipset_saved "${ipset}" "I am not allowed to talk to the kernel."
		return 0
	fi

	ipset_apply_counter=$[ipset_apply_counter + 1]
	tmpname="tmp-$$-${RANDOM}-${ipset_apply_counter}"

	if [ "${ipv}" = "ipv4" ]
		then
		if [ -z "${sets[$ipset]}" ]
			then
			ipset_saved "${ipset}" "no need to load ipset in kernel"
			# $IPSET_CMD --create ${ipset} "${hash}hash" || return 1
			return 0
		fi

		if [ "${hash}" = "net" ]
			then
			${IPRANGE_CMD} "${file}" \
				--ipset-reduce ${IPSET_REDUCE_FACTOR} \
				--ipset-reduce-entries ${IPSET_REDUCE_ENTRIES} \
				--print-prefix "-A ${tmpname} " >"${RUN_DIR}/${tmpname}"
			ret=$?
		elif [ "${hash}" = "ip" ]
			then
			${IPRANGE_CMD} -1 "${file}" --print-prefix "-A ${tmpname} " >"${RUN_DIR}/${tmpname}"
			ret=$?
		fi

		if [ ${ret} -ne 0 ]
			then
			ipset_error "${ipset}" "iprange failed"
			$RM_CMD "${RUN_DIR}/${tmpname}"
			return 1
		fi

		entries=$($WC_CMD -l <"${RUN_DIR}/${tmpname}")
		ips=$($IPRANGE_CMD -C "${file}")
		ips=${ips/*,/}

		# this is needed for older versions of ipset
		echo "COMMIT" >>"${RUN_DIR}/${tmpname}"

		ipset_info "${ipset}" "loading to kernel (to temporary ipset)..."

		opts=
		if [ ${entries} -gt 65536 ]
			then
			opts="maxelem ${entries}"
		fi

		$IPSET_CMD create "${tmpname}" ${hash}hash ${opts}
		if [ $? -ne 0 ]
			then
			ipset_error "${ipset}" "failed to create temporary ipset ${tmpname}"
			$RM_CMD "${RUN_DIR}/${tmpname}"
			return 1
		fi

		$IPSET_CMD --flush "${tmpname}"
		$IPSET_CMD --restore <"${RUN_DIR}/${tmpname}"
		ret=$?
		$RM_CMD "${RUN_DIR}/${tmpname}"

		if [ ${ret} -ne 0 ]
			then
			ipset_error "${ipset}" "failed to restore ipset from ${tmpname}"
			$IPSET_CMD --destroy "${tmpname}"
			return 1
		fi

		ipset_info "${ipset}" "swapping temporary ipset to production"
		$IPSET_CMD --swap "${tmpname}" "${ipset}"
		ret=$?
		$IPSET_CMD --destroy "${tmpname}"
		if [ $? -ne 0 ]
			then
			ipset_error "${ipset}" "failed to destroy temporary ipset"
			return 1
		fi

		if [ $ret -ne 0 ]
			then
			ipset_error "${ipset}" "failed to swap temporary ipset ${tmpname}"
			return 1
		fi

		ipset_loaded "${ipset}" "${entries} entries, ${ips} unique IPs"
	else
		ipset_error "${ipset}" "CANNOT HANDLE IPv6 IPSETS YET"
		return 1
	fi

	return 0
}

IPSET_PUBLIC_URL=
ipset_attributes() {
	local ipset="${1}"
	shift

	ipset_verbose "${ipset}" "parsing attributes: ${*}"

	while [ ! -z "${1}" ]
	do
		case "${1}" in
			redistribute)			unset IPSET_TMP_DO_NOT_REDISTRIBUTE[${ipset}]; shift; continue ;;
			dont_redistribute)		IPSET_TMP_DO_NOT_REDISTRIBUTE[${ipset}]="1"; shift; continue ;;
			can_be_empty|empty)		IPSET_TMP_ACCEPT_EMPTY[${ipset}]="1"; shift; continue ;;
			never_empty|no_empty)	unset IPSET_TMP_ACCEPT_EMPTY[${ipset}]; shift; continue ;;
			no_if_modified_since)	IPSET_TMP_NO_IF_MODIFIED_SINCE[${ipset}]="1"; shift; continue ;;
			dont_enable_with_all)	IPSET_TMP_DO_NOT_ENABLE_WITH_ALL[${ipset}]="1"; shift; continue ;;

			inbound|outbound)		IPSET_PROTECTION[${ipset}]="${1}"; shift; continue ;;

			downloader)				IPSET_DOWNLOADER[${ipset}]="${2}" ;;
			downloader_options)		IPSET_DOWNLOADER_OPTIONS[${ipset}]="${2}" ;;
			category)				IPSET_CATEGORY[${ipset}]="${2}" ;;
			maintainer)				IPSET_MAINTAINER[${ipset}]="${2}" ;;
			maintainer_url)			IPSET_MAINTAINER_URL[${ipset}]="${2}" ;;
			license)				IPSET_LICENSE[${ipset}]="${2}" ;;
			grade)					IPSET_GRADE[${ipset}]="${2}" ;;
			protection)				IPSET_PROTECTION[${ipset}]="${2}" ;;
			intended_use)			IPSET_INTENDED_USE[${ipset}]="${2}" ;;
			false_positives)		IPSET_FALSE_POSITIVES[${ipset}]="${2}" ;;
			poisoning)				IPSET_POISONING[${ipset}]="${2}" ;;
			service|services)		IPSET_SERVICES[${ipset}]="${2}" ;;

			# we use IPSET_PUBLIC_URL to replace / hide the actual URL we use
			public_url)				IPSET_URL[${ipset}]="${2}"; IPSET_PUBLIC_URL="${2}" ;;

			*)						ipset_warning "${ipset}" "unknown ipset option '${1}' with value '${2}'." ;;
		esac

		shift 2
	done

	[ -z "${IPSET_LICENSE[${ipset}]}"         ] && IPSET_LICENSE[${ipset}]="unknown"
	[ -z "${IPSET_GRADE[${ipset}]}"           ] && IPSET_GRADE[${ipset}]="unknown"
	[ -z "${IPSET_PROTECTION[${ipset}]}"      ] && IPSET_PROTECTION[${ipset}]="unknown"
	[ -z "${IPSET_INTENDED_USE[${ipset}]}"    ] && IPSET_INTENDED_USE[${ipset}]="unknown"
	[ -z "${IPSET_FALSE_POSITIVES[${ipset}]}" ] && IPSET_FALSE_POSITIVES[${ipset}]="unknown"
	[ -z "${IPSET_POISONING[${ipset}]}"       ] && IPSET_POISONING[${ipset}]="unknown"
	[ -z "${IPSET_SERVICES[${ipset}]}"        ] && IPSET_SERVICES[${ipset}]="unknown"

	return 0
}

# -----------------------------------------------------------------------------
# finalize() is called when a successful download and convertion completes
# to update the ipset in the kernel and possibly commit it to git
finalize() {
	local 	ipset="${1}" tmp="${2}" \
			src="${3}" dst="${4}" \
			mins="${5}" history_mins="${6}" \
			ipv="${7}" limit="${8}" hash="${9}" \
			url="${10}" category="${11}" info="${12}" \
			maintainer="${13}" maintainer_url="${14}"
	shift 14

	# ipset 		the ipset name
	# tmp 			the processed source, ready to be used
	# src 			the source, as downloaded (we need the date)
	# dst 			the destination to save the final ipset

	if [ ! -f "${BASE_DIR}/${src}" ]
		then
		ipset_error "${ipset}" "source file '${BASE_DIR}/${src}' does not exist"
		return 1
	fi

	if [ ! -f "${tmp}" ]
		then
		ipset_error "${ipset}" "tmp file '${tmp}' does not exist"
		return 1
	fi

	ipset_attributes "${ipset}" "${@}"

	# check
	if [ -z "${info}" ]
		then
		ipset_warning "${ipset}" "INTERNAL ERROR (finalize): no info supplied"
		info="${category}"
	fi

	if [ -f "${BASE_DIR}/${dst}" -a ! -z "${IPSET_FILE[${ipset}]}" -a ${REPROCESS_ALL} -eq 0 ]
		then
		${IPRANGE_CMD} "${BASE_DIR}/${dst}" --diff "${tmp}" --quiet
		if [ $? -eq 0 ]
		then
			# they are the same
			$RM_CMD "${tmp}"
			ipset_same "${ipset}" "processed set is the same with the previous one."

			# keep the old set, but make it think it was from this source
			ipset_verbose "${ipset}" "touching ${dst} from ${src}."
			$TOUCH_CMD -r "${BASE_DIR}/${src}" "${BASE_DIR}/${dst}"

			check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
			return 0
	#	else
	#		ipset_info "${ipset}" "processed file differs from the last."
		fi
	#else
	#	ipset_info "${ipset}" "not comparing file with the last."
	fi

	# calculate how many entries/IPs are in it
	local ipset_opts=
	local entries=$(${IPRANGE_CMD} -C "${tmp}")
	local ips=${entries/*,/}
	local entries=${entries/,*/}

	if [ $[ ips ] -eq 0 ]
		then
		if [ -z "${IPSET_TMP_ACCEPT_EMPTY[${ipset}]}" ]
			then
			$RM_CMD "${tmp}"
			ipset_error "${ipset}" "processed file has no valid entries (zero unique IPs)"
			check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
			return 1
		else
			ipset_warning "${ipset}" "processed file has no valid entries (zero unique IPs)"
		fi
	fi

	ipset_apply ${ipset} ${ipv} ${hash} ${tmp}
	if [ $? -ne 0 ]
	then
		if [ ! -z "${ERRORS_DIR}" -a -d "${ERRORS_DIR}" ]
		then
			$MV_CMD "${tmp}" "${ERRORS_DIR}/${dst}"
			ipset_error "${ipset}" "failed to update ipset (error file left as '${ERRORS_DIR}/${dst}')."
		else
			$RM_CMD "${tmp}"
			ipset_error "${ipset}" "failed to update ipset."
		fi
		check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
		return 1
	fi

	local quantity="${ips} unique IPs"
	[ "${hash}" = "net" ] && quantity="${entries} subnets, ${ips} unique IPs"

	IPSET_FILE[${ipset}]="${dst}"
	IPSET_IPV[${ipset}]="${ipv}"
	IPSET_HASH[${ipset}]="${hash}"
	IPSET_MINS[${ipset}]="${mins}"
	IPSET_HISTORY_MINS[${ipset}]="${history_mins}"
	IPSET_INFO[${ipset}]="${info}"
	IPSET_ENTRIES[${ipset}]="${entries}"
	IPSET_IPS[${ipset}]="${ips}"
	IPSET_URL[${ipset}]="${url}"
	IPSET_SOURCE[${ipset}]="${src}"
	IPSET_SOURCE_DATE[${ipset}]=$($DATE_CMD -r "${BASE_DIR}/${src}" +%s)
	IPSET_PROCESSED_DATE[${ipset}]=$($DATE_CMD +%s)
	IPSET_CATEGORY[${ipset}]="${category}"
	IPSET_MAINTAINER[${ipset}]="${maintainer}"
	IPSET_MAINTAINER_URL[${ipset}]="${maintainer_url}"

	[ -z "${IPSET_ENTRIES_MIN[${ipset}]}" ] && IPSET_ENTRIES_MIN[${ipset}]="${IPSET_ENTRIES[${ipset}]}"
	[ "${IPSET_ENTRIES_MIN[${ipset}]}" -gt "${IPSET_ENTRIES[${ipset}]}" ] && IPSET_ENTRIES_MIN[${ipset}]="${IPSET_ENTRIES[${ipset}]}"

	[ -z "${IPSET_ENTRIES_MAX[${ipset}]}" ] && IPSET_ENTRIES_MAX[${ipset}]="${IPSET_ENTRIES[${ipset}]}"
	[ "${IPSET_ENTRIES_MAX[${ipset}]}" -lt "${IPSET_ENTRIES[${ipset}]}" ] && IPSET_ENTRIES_MAX[${ipset}]="${IPSET_ENTRIES[${ipset}]}"

	[ -z "${IPSET_IPS_MIN[${ipset}]}" ] && IPSET_IPS_MIN[${ipset}]="${IPSET_IPS[${ipset}]}"
	[ "${IPSET_IPS_MIN[${ipset}]}" -gt "${IPSET_IPS[${ipset}]}" ] && IPSET_IPS_MIN[${ipset}]="${IPSET_IPS[${ipset}]}"

	[ -z "${IPSET_IPS_MAX[${ipset}]}" ] && IPSET_IPS_MAX[${ipset}]="${IPSET_IPS[${ipset}]}"
	[ "${IPSET_IPS_MAX[${ipset}]}" -lt "${IPSET_IPS[${ipset}]}" ] && IPSET_IPS_MAX[${ipset}]="${IPSET_IPS[${ipset}]}"

	[ -z "${IPSET_STARTED_DATE[${ipset}]}" ] && IPSET_STARTED_DATE[${ipset}]="${IPSET_SOURCE_DATE[${ipset}]}"

	local version=${IPSET_VERSION[${ipset}]}
	[ -z "${version}" ] && version=0
	version=$[ version + 1 ]
	IPSET_VERSION[${ipset}]=${version}

	ipset_silent "${ipset}" "version ${version}, ${quantity}"

	local now="$($DATE_CMD +%s)"
	if [ "${now}" -lt "${IPSET_SOURCE_DATE[${ipset}]}" ]
		then
		IPSET_CLOCK_SKEW[${ipset}]=$[ IPSET_SOURCE_DATE[${ipset}] - now ]
		ipset_warning "${ipset}" "updated time is future (${IPSET_CLOCK_SKEW[${ipset}]} seconds)"
	else
		IPSET_CLOCK_SKEW[${ipset}]=0
	fi

	# generate the final file
	# we do this on another tmp file
	$CAT_CMD >"${tmp}.wh" <<EOFHEADER
#
# ${ipset}
#
# ${ipv} hash:${hash} ipset
#
`echo "${info}" | $SED_CMD "s|](|] (|g" | $FOLD_CMD -w 60 -s | $SED_CMD "s/^/# /g"`
#
# Maintainer      : ${maintainer}
# Maintainer URL  : ${maintainer_url}
# List source URL : ${url}
# Source File Date: `$DATE_CMD -r "${BASE_DIR}/${src}" -u`
#
# Category        : ${category}
# Version         : ${version}
#
# This File Date  : `$DATE_CMD -u`
# Update Frequency: `mins_to_text ${mins}`
# Aggregation     : `mins_to_text ${history_mins}`
# Entries         : ${quantity}
#
# Full list analysis, including geolocation map, history,
# retention policy, overlaps with other lists, etc.
# available at:
#
#  ${WEB_URL}${ipset}
#
# Generated by FireHOL's update-ipsets.sh
# Processed with FireHOL's iprange
#
EOFHEADER
# Intended Use    : ${IPSET_INTENDED_USE[${ipset}]}
# Services        : ${IPSET_SERVICES[${ipset}]}
# Protection      : ${IPSET_PROTECTION[${ipset}]}
# Grade           : ${IPSET_GRADE[${ipset}]}
# License         : ${IPSET_LICENSE[${ipset}]}
# False Positives : ${IPSET_FALSE_POSITIVES[${ipset}]}
# Poisoning       : ${IPSET_POISONING[${ipset}]}

	$CAT_CMD "${tmp}" >>"${tmp}.wh"
	$RM_CMD "${tmp}"
	$TOUCH_CMD -r "${BASE_DIR}/${src}" "${tmp}.wh"
	$MV_CMD "${tmp}.wh" "${BASE_DIR}/${dst}" || return 1

	UPDATED_SETS[${ipset}]="${dst}"
	local dir="`$DIRNAME_CMD "${dst}"`"
	UPDATED_DIRS[${dir}]="${dir}"

	cache_save

	return 0
}

# -----------------------------------------------------------------------------

update() {
	cd "${RUN_DIR}" || return 1

	local 	ipset="${1}" mins="${2}" history_mins="${3}" ipv="${4}" limit="${5}" \
			url="${6}" \
			processor="${7-$CAT_CMD}" \
			category="${8}" \
			info="${9}" \
			maintainer="${10}" maintainer_url="${11}" force=${REPROCESS_ALL}
	shift 11

	# read it attributes
	IPSET_PUBLIC_URL=
	ipset_attributes "${ipset}" "${@}"

	local	tmp= error=0 now= date= ret= \
			pre_filter="$CAT_CMD" post_filter="$CAT_CMD" post_filter2="$CAT_CMD" filter="$CAT_CMD" \
			src="${ipset}.source" dst=

	# check
	if [ -z "${info}" ]
		then
		ipset_warning "${ipset}" "INTERNAL ERROR (update): no info supplied"
		info="${category}"
	fi

	case "${ipv}" in
		ipv4)
			post_filter2="filter_invalid4"
			case "${limit}" in
				ip|ips)		# output is single ipv4 IPs without /
						hash="ip"
						limit="ip"
						pre_filter="$CAT_CMD"
						filter="filter_ip4"	# without this, '${IPRANGE_CMD} -1' may output huge number of IPs
						post_filter="${IPRANGE_CMD} -1"
						;;

				net|nets)	# output is full CIDRs without any single IPs (/32)
						hash="net"
						limit="net"
						pre_filter="filter_all4"
						filter="${IPRANGE_CMD}"
						post_filter="filter_net4"
						;;

				both|all)	# output is full CIDRs with single IPs in CIDR notation (with /32)
						hash="net"
						limit=""
						pre_filter="filter_all4"
						filter="${IPRANGE_CMD}"
						post_filter="$CAT_CMD"
						;;

				split)	;;

				*)		ipset_error "${ipset}" "unknown limit '${limit}'."
						return 1
						;;
			esac
			;;
		ipv6)
			ipset_error "${ipset}" "IPv6 is not yet supported."
			return 1
			;;

		*)	ipset_error "${ipset}" "unknown IP version '${ipv}'."
			return 1
			;;
	esac

	# the destination file
	# it must be a relative file (no path)
	dst="${ipset}.${hash}set"

	# check if it is enabled
	ipset_shall_be_run "${ipset}"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	# do we have something to download?
	if [ ! -z "${url}" ]
	then
		# download it
		download_manager "${ipset}" "${mins}" "${url}"
		ret=$?

		if [ \( -z "${IPSET_FILE[${ipset}]}" -o ! -f "${BASE_DIR}/${dst}" \) -a -s  "${BASE_DIR}/${src}" ]
			then
			force=1
			ipset_silent "${ipset}" "forced reprocessing (ignoring download status)"

		elif [ ${ret} -eq ${DOWNLOAD_FAILED} ]
			then
			ipset_silent "${ipset}" "download manager reports failure"
			check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
			return 1

		elif [ ${ret} -eq ${DOWNLOAD_NOT_UPDATED} -a ! -f "${BASE_DIR}/${dst}" ]
			then
			force=1
			ipset_silent "${ipset}" "download is the same, but we need to re-process it"

		elif [ ${ret} -eq ${DOWNLOAD_NOT_UPDATED} -a ${force} -eq 0 ]
			then
			ipset_silent "${ipset}" "download manager reports not updated source"
			check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
			return 1
		fi

		[ ! -z "${IPSET_PUBLIC_URL}" ] && url="${IPSET_PUBLIC_URL}"
	fi

	if [ -f "${BASE_DIR}/${dst}" ]
		then
		# check if the source file has been updated
		if [ ${force} -eq 0 -a ! "${BASE_DIR}/${src}" -nt "${BASE_DIR}/${dst}" ]
		then
			ipset_notupdated "${ipset}" "source file has not been updated"
			check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
			return 0
		fi

		if [ "${BASE_DIR}/${src}" -nt "${BASE_DIR}/${dst}" ]
			then
			ipset_silent "${ipset}" "source file has been updated"
		fi
	fi

	# support for older systems where hash:net cannot get hash:ip entries
	# if the .split file exists, create 2 ipsets, one for IPs and one for subnets
	if [ "${limit}" = "split" -o \( -z "${limit}" -a -f "${BASE_DIR}/${ipset}.split" \) ]
	then
		ipset_info "${ipset}" "spliting IPs and subnets..."
		test -f "${BASE_DIR}/${ipset}_ip.source" && $RM_CMD "${BASE_DIR}/${ipset}_ip.source"
		test -f "${BASE_DIR}/${ipset}_net.source" && $RM_CMD "${BASE_DIR}/${ipset}_net.source"
		(
			cd "${BASE_DIR}"
			$LN_CMD -s "${src}" "${ipset}_ip.source"
			$LN_CMD -s "${src}" "${ipset}_net.source"
		)

		update "${ipset}_ip" "${mins}" "${history_mins}" "${ipv}" ip  \
			"" \
			"${processor}" \
			"${category}" \
			"${info}" \
			"${maintainer}" "${maintainer_url}" \
			"${@}"

		update "${ipset}_net" "${mins}" "${history_mins}" "${ipv}" net \
			"" \
			"${processor}" \
			"${category}" \
			"${info}" \
			"${maintainer}" "${maintainer_url}" \
			"${@}"

		return $?
	fi

	# convert it
	ipset_silent "${ipset}" "converting with '${processor}'"
	tmp=`$MKTEMP_CMD "${RUN_DIR}/${ipset}.tmp-XXXXXXXXXX"` || return 1
	${processor} <"${BASE_DIR}/${src}" |\
		trim |\
		${pre_filter} |\
		${filter} |\
		${post_filter} |\
		${post_filter2} >"${tmp}"

	if [ $? -ne 0 ]
	then
		ipset_error "${ipset}" "failed to convert file."
		$RM_CMD "${tmp}"
		check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
		return 1
	fi

	# if the downloaded file is empty, but we don't accept empty files
	if [ ! -s "${tmp}" -a -z "${IPSET_TMP_ACCEPT_EMPTY[${ipset}]}" ]
		then
		ipset_error "${ipset}" "converted file is empty."
		$RM_CMD "${tmp}"
		check_file_too_old "${ipset}" "${BASE_DIR}/${dst}"
		return 1
	fi

	local h= hmax=-1
	[ "${history_mins}" = "0" ] && history_mins=

	if [ ! -z "${history_mins}" ]
		then
		history_keep "${ipset}" "${tmp}"
	fi

	ret=0
	for h in 0 ${history_mins/,/ }
	do
		local hmins=${h/\/*/}
		hmins=$[ hmins + 0 ]
		local htag=

		if [ ${hmins} -gt 0 ]
			then
			if [ ${hmins} -gt ${hmax} ]
				then
				hmax=${hmins}
			fi

			if [ ${hmins} -ge $[24 * 60] ]
				then
				local hd=$[ hmins / (24 * 60) ]
				htag="_${hd}d"

				if [ $[ hd * (24 * 60) ] -ne ${hmins} ]
					then
					htag="${htag}$[hmins - (hd * 1440)]h"
				fi
			else
				htag="_$[hmins/60]h"
			fi

			ipset_silent "${ipset}${htag}" "merging history files (${hmins} mins)"
			history_get "${ipset}" "${hmins}" >"${tmp}${htag}"

			$CP_CMD "${tmp}${htag}" "${BASE_DIR}/${ipset}${htag}.source"
			$TOUCH_CMD -r "${BASE_DIR}/${src}" "${BASE_DIR}/${ipset}${htag}.source"
		fi

		finalize "${ipset}${htag}" "${tmp}${htag}" \
			"${ipset}${htag}.source" "${ipset}${htag}.${hash}set" \
			"${mins}" "${hmins}" "${ipv}" "${limit}" "${hash}" \
			"${url}" \
			"${category}" \
			"${info}" \
			"${maintainer}" "${maintainer_url}" \
			"${@}"

		[ $? -ne 0 ] && ret=$[ ret + 1 ]
 	done

	if [ ! -z "${history_mins}" ]
		then
		history_cleanup "${ipset}" "${hmax}"
	fi

	return $ret
}


# -----------------------------------------------------------------------------
# IPSETS RENAMING

# FIXME
# Cannot rename ipsets in subdirectories
rename_ipset() {

	local old="${1}" new="${2}"

	[ ! -f "${BASE_DIR}/${old}.source" -o -f "${BASE_DIR}/${new}.source" ] && return 1

	cd "${BASE_DIR}" || return 1

	local x=
	for x in ipset netset
	do
		if [ -f "${BASE_DIR}/${old}.${x}" -a ! -f "${BASE_DIR}/${new}.${x}" ]
			then
			if [ -f "${BASE_DIR}/${old}.${x}" -a ! -f "${BASE_DIR}/${new}.${x}" ]
				then
				ipset_info "${old}" "renaming ${old}.${x} to ${new}.${x}..."
				$MV_CMD "${BASE_DIR}/${old}.${x}" "${BASE_DIR}/${new}.${x}" || exit 1
			fi

			# keep a link for the firewall
			ipset_info "${old}" "Linking ${new}.${x} to ${old}.${x}..."
			( cd "${BASE_DIR}" ; $LN_CMD -s "${new}.${x}" "${old}.${x}" )

			# now delete it, in order to be re-created this run
			$RM_CMD "${BASE_DIR}/${new}.${x}"

			# FIXME:
			# the ipset in kernel is wrong and will not be updated.
			# Probably the solution is to create an list:set ipset
			# which will link the old name with the new
		fi
	done

	for x in source split setinfo
	do
		if [ -f "${BASE_DIR}/${old}.${x}" -a ! -f "${BASE_DIR}/${new}.${x}" ]
			then
			$MV_CMD "${BASE_DIR}/${old}.${x}" "${BASE_DIR}/${new}.${x}" || exit 1
		fi
	done

	if [ -d "${HISTORY_DIR}/${old}" -a ! -d "${HISTORY_DIR}/${new}" ]
		then
		ipset_info "${old}" "renaming ${HISTORY_DIR}/${old} ${HISTORY_DIR}/${new}"
		$MV_CMD "${HISTORY_DIR}/${old}" "${HISTORY_DIR}/${new}"
	fi

	if [ ! -z "${LIB_DIR}" -a -d "${LIB_DIR}" -a -d "${LIB_DIR}/${old}" -a ! -d "${LIB_DIR}/${new}" ]
		then
		ipset_info "${old}" "renaming ${LIB_DIR}/${old} ${LIB_DIR}/${new}"
		$MV_CMD -f "${LIB_DIR}/${old}" "${LIB_DIR}/${new}" || exit 1
	fi

	if [ -d "${WEB_DIR}" ]
		then
		for x in _comparison.json _geolite2_country.json _ipdeny_country.json _ip2location_country.json _ipip_country.json _history.csv retention.json .json .html
		do
			if [ -f "${WEB_DIR}/${old}${x}" -a ! -f "${WEB_DIR}/${new}${x}" ]
				then
				ipset_info "${old}" "renaming ${WEB_DIR}/${old}${x} ${WEB_DIR}/${new}${x}"
				$MV_CMD -f "${old}${x}" "${new}${x}"
			fi
		done
	fi

	# rename the cache
	[ -z "${IPSET_INFO[${new}]}" ] && IPSET_INFO[${new}]="${IPSET_INFO[${old}]}"
	[ -z "${IPSET_SOURCE[${new}]}" ] && IPSET_SOURCE[${new}]="${IPSET_SOURCE[${old}]}"
	[ -z "${IPSET_URL[${new}]}" ] && IPSET_URL[${new}]="${IPSET_URL[${old}]}"
	[ -z "${IPSET_FILE[${new}]}" ] && IPSET_FILE[${new}]="${IPSET_FILE[${old}]}"
	[ -z "${IPSET_IPV[${new}]}" ] && IPSET_IPV[${new}]="${IPSET_IPV[${old}]}"
	[ -z "${IPSET_HASH[${new}]}" ] && IPSET_HASH[${new}]="${IPSET_HASH[${old}]}"
	[ -z "${IPSET_MINS[${new}]}" ] && IPSET_MINS[${new}]="${IPSET_MINS[${old}]}"
	[ -z "${IPSET_HISTORY_MINS[${new}]}" ] && IPSET_HISTORY_MINS[${new}]="${IPSET_HISTORY_MINS[${old}]}"
	[ -z "${IPSET_ENTRIES[${new}]}" ] && IPSET_ENTRIES[${new}]="${IPSET_ENTRIES[${old}]}"
	[ -z "${IPSET_IPS[${new}]}" ] && IPSET_IPS[${new}]="${IPSET_IPS[${old}]}"
	[ -z "${IPSET_SOURCE_DATE[${new}]}" ] && IPSET_SOURCE_DATE[${new}]="${IPSET_SOURCE_DATE[${old}]}"
	[ -z "${IPSET_CHECKED_DATE[${new}]}" ] && IPSET_CHECKED_DATE[${new}]="${IPSET_CHECKED_DATE[${old}]}"
	[ -z "${IPSET_PROCESSED_DATE[${new}]}" ] && IPSET_PROCESSED_DATE[${new}]="${IPSET_PROCESSED_DATE[${old}]}"
	[ -z "${IPSET_CATEGORY[${new}]}" ] && IPSET_CATEGORY[${new}]="${IPSET_CATEGORY[${old}]}"
	[ -z "${IPSET_MAINTAINER[${new}]}" ] && IPSET_MAINTAINER[${new}]="${IPSET_MAINTAINER[${old}]}"
	[ -z "${IPSET_MAINTAINER_URL[${new}]}" ] && IPSET_MAINTAINER_URL[${new}]="${IPSET_MAINTAINER_URL[${old}]}"
	[ -z "${IPSET_LICENSE[${new}]}" ] && IPSET_LICENSE[${new}]="${IPSET_LICENSE[${old}]}"
	[ -z "${IPSET_GRADE[${new}]}" ] && IPSET_GRADE[${new}]="${IPSET_GRADE[${old}]}"
	[ -z "${IPSET_PROTECTION[${new}]}" ] && IPSET_PROTECTION[${new}]="${IPSET_PROTECTION[${old}]}"
	[ -z "${IPSET_INTENDED_USE[${new}]}" ] && IPSET_INTENDED_USE[${new}]="${IPSET_INTENDED_USE[${old}]}"
	[ -z "${IPSET_FALSE_POSITIVES[${new}]}" ] && IPSET_FALSE_POSITIVES[${new}]="${IPSET_FALSE_POSITIVES[${old}]}"
	[ -z "${IPSET_POISONING[${new}]}" ] && IPSET_POISONING[${new}]="${IPSET_POISONING[${old}]}"
	[ -z "${IPSET_SERVICES[${new}]}" ] && IPSET_SERVICES[${new}]="${IPSET_SERVICES[${old}]}"
	[ -z "${IPSET_ENTRIES_MIN[${new}]}" ] && IPSET_ENTRIES_MIN[${new}]="${IPSET_ENTRIES_MIN[${old}]}"
	[ -z "${IPSET_ENTRIES_MAX[${new}]}" ] && IPSET_ENTRIES_MAX[${new}]="${IPSET_ENTRIES_MAX[${old}]}"
	[ -z "${IPSET_IPS_MIN[${new}]}" ] && IPSET_IPS_MIN[${new}]="${IPSET_IPS_MIN[${old}]}"
	[ -z "${IPSET_IPS_MAX[${new}]}" ] && IPSET_IPS_MAX[${new}]="${IPSET_IPS_MAX[${old}]}"
	[ -z "${IPSET_STARTED_DATE[${new}]}" ] && IPSET_STARTED_DATE[${new}]="${IPSET_STARTED_DATE[${old}]}"
	[ -z "${IPSET_CLOCK_SKEW[${new}]}" ] && IPSET_CLOCK_SKEW[${new}]="${IPSET_CLOCK_SKEW[${old}]}"
	[ -z "${IPSET_DOWNLOAD_FAILURES[${new}]}" ] && IPSET_DOWNLOAD_FAILURES[${new}]="${IPSET_DOWNLOAD_FAILURES[${old}]}"
	[ -z "${IPSET_VERSION[${new}]}" ] && IPSET_VERSION[${new}]="${IPSET_VERSION[${old}]}"
	[ -z "${IPSET_AVERAGE_UPDATE_TIME[${new}]}" ] && IPSET_AVERAGE_UPDATE_TIME[${new}]="${IPSET_AVERAGE_UPDATE_TIME[${old}]}"
	[ -z "${IPSET_MIN_UPDATE_TIME[${new}]}" ] && IPSET_MIN_UPDATE_TIME[${new}]="${IPSET_MIN_UPDATE_TIME[${old}]}"
	[ -z "${IPSET_MAX_UPDATE_TIME[${new}]}" ] && IPSET_MAX_UPDATE_TIME[${new}]="${IPSET_MAX_UPDATE_TIME[${old}]}"
	[ -z "${IPSET_DOWNLOADER[${new}]}" ] && IPSET_DOWNLOADER[${new}]="${IPSET_DOWNLOADER[${old}]}"
	[ -z "${IPSET_DOWNLOADER_OPTIONS[${new}]}" ] && IPSET_DOWNLOADER_OPTIONS[${new}]="${IPSET_DOWNLOADER_OPTIONS[${old}]}"
	cache_remove_ipset "${old}" # this also saves the cache

	cd "${RUN_DIR}"
	return 0
}

delete_ipset() {
	local ipset="${1}"

	[ -z "${ipset}" ] && return 1
	[ "${CLEANUP_OLD}" != "1" ] && return 0

	cd "${BASE_DIR}" || return 1

	for x in ipset netset source split setinfo
	do
		if [ -f "${BASE_DIR}/${ipset}.${x}" ]
			then

			if [ -f "${BASE_DIR}/${ipset}.${x}" ]
				then
				ipset_info "${ipset}" "deleting ${BASE_DIR}/${ipset}.${x}"
				$RM_CMD "${BASE_DIR}/${ipset}.${x}" || exit 1
			fi
		fi
	done

	if [ -d "${HISTORY_DIR}/${ipset}" ]
		then
		ipset_info "${ipset}" "deleting ${HISTORY_DIR}/${ipset}"
		cd "${HISTORY_DIR}" && $RM_CMD -rf "${ipset}"
		cd "${BASE_DIR}" || return 1
	fi

	if [ ! -z "${LIB_DIR}" -a -d "${LIB_DIR}" -a -d "${LIB_DIR}/${ipset}" ]
		then
		ipset_info "${ipset}" "deleting ${LIB_DIR}/${ipset}"
		cd "${LIB_DIR}" && $RM_CMD -rf "${ipset}"
		cd "${BASE_DIR}" || return 1
	fi

	if [ -d "${WEB_DIR}" ]
		then
		for x in _comparison.json _geolite2_country.json _ipdeny_country.json _ip2location_country.json _ipip_country.json _history.csv retention.json .json .html
		do
			if [ -f "${WEB_DIR}/${ipset}${x}" ]
				then

				if [ -f "${WEB_DIR}/${ipset}${x}" ]
					then
					ipset_info "${ipset}" "deleting ${WEB_DIR}/${ipset}${x}"
					$RM_CMD -f "${WEB_DIR}/${ipset}${x}"
				fi
			fi
		done
	fi

	cache_remove_ipset "${ipset}" # this also saves the cache

	cd "${RUN_DIR}"
	return 0
}

# rename the emerging threats ipsets to their right names
rename_ipset tor et_tor
rename_ipset compromised et_compromised
rename_ipset botnet et_botcc
rename_ipset et_botnet et_botcc
rename_ipset emerging_block et_block
rename_ipset rosi_web_proxies ri_web_proxies
rename_ipset rosi_connect_proxies ri_connect_proxies
rename_ipset danmetor dm_tor
rename_ipset autoshun shunlist
rename_ipset tor_servers bm_tor
rename_ipset stop_forum_spam stopforumspam
rename_ipset stop_forum_spam_1h stopforumspam_1d
rename_ipset stop_forum_spam_7d stopforumspam_7d
rename_ipset stop_forum_spam_30d stopforumspam_30d
rename_ipset stop_forum_spam_90d stopforumspam_90d
rename_ipset stop_forum_spam_180d stopforumspam_180d
rename_ipset stop_forum_spam_365d stopforumspam_365d
rename_ipset clean_mx_viruses cleanmx_viruses

rename_ipset ib_bluetack_proxies iblocklist_proxies
rename_ipset ib_bluetack_spyware iblocklist_spyware
rename_ipset ib_bluetack_badpeers iblocklist_badpeers
rename_ipset ib_bluetack_hijacked iblocklist_hijacked
rename_ipset ib_bluetack_webexploit iblocklist_webexploit
rename_ipset ib_bluetack_level1 iblocklist_level1
rename_ipset ib_bluetack_level2 iblocklist_level2
rename_ipset ib_bluetack_level3 iblocklist_level3
rename_ipset ib_bluetack_edu iblocklist_edu
rename_ipset ib_bluetack_rangetest iblocklist_rangetest
rename_ipset ib_bluetack_bogons iblocklist_bogons
rename_ipset ib_bluetack_ads iblocklist_ads
rename_ipset ib_bluetack_ms iblocklist_org_microsoft
rename_ipset ib_bluetack_spider iblocklist_spider
rename_ipset ib_bluetack_dshield iblocklist_dshield
rename_ipset ib_bluetack_iana_reserved iblocklist_iana_reserved
rename_ipset ib_bluetack_iana_private iblocklist_iana_private
rename_ipset ib_bluetack_iana_multicast iblocklist_iana_multicast
rename_ipset ib_bluetack_fornonlancomputers iblocklist_fornonlancomputers
rename_ipset ib_bluetack_exclusions iblocklist_exclusions
rename_ipset ib_bluetack_forumspam iblocklist_forumspam
rename_ipset ib_pedophiles iblocklist_pedophiles
rename_ipset ib_cruzit_web_attacks iblocklist_cruzit_web_attacks
rename_ipset ib_yoyo_adservers iblocklist_yoyo_adservers
rename_ipset ib_spamhaus_drop iblocklist_spamhaus_drop
rename_ipset ib_abuse_zeus iblocklist_abuse_zeus
rename_ipset ib_abuse_spyeye iblocklist_abuse_spyeye
rename_ipset ib_abuse_palevo iblocklist_abuse_palevo
rename_ipset ib_ciarmy_malicious iblocklist_ciarmy_malicious
rename_ipset ib_malc0de iblocklist_malc0de
rename_ipset ib_cidr_report_bogons iblocklist_cidr_report_bogons
rename_ipset ib_onion_router iblocklist_onion_router
rename_ipset ib_org_apple iblocklist_org_apple
rename_ipset ib_org_logmein iblocklist_org_logmein
rename_ipset ib_org_steam iblocklist_org_steam
rename_ipset ib_org_xfire iblocklist_org_xfire
rename_ipset ib_org_blizzard iblocklist_org_blizzard
rename_ipset ib_org_ubisoft iblocklist_org_ubisoft
rename_ipset ib_org_nintendo iblocklist_org_nintendo
rename_ipset ib_org_activision iblocklist_org_activision
rename_ipset ib_org_sony_online iblocklist_org_sony_online
rename_ipset ib_org_crowd_control iblocklist_org_crowd_control
rename_ipset ib_org_linden_lab iblocklist_org_linden_lab
rename_ipset ib_org_electronic_arts iblocklist_org_electronic_arts
rename_ipset ib_org_square_enix iblocklist_org_square_enix
rename_ipset ib_org_ncsoft iblocklist_org_ncsoft
rename_ipset ib_org_riot_games iblocklist_org_riot_games
rename_ipset ib_org_punkbuster iblocklist_org_punkbuster
rename_ipset ib_org_joost iblocklist_org_joost
rename_ipset ib_org_pandora iblocklist_org_pandora
rename_ipset ib_org_pirate_bay iblocklist_org_pirate_bay
rename_ipset ib_isp_aol iblocklist_isp_aol
rename_ipset ib_isp_comcast iblocklist_isp_comcast
rename_ipset ib_isp_cablevision iblocklist_isp_cablevision
rename_ipset ib_isp_verizon iblocklist_isp_verizon
rename_ipset ib_isp_att iblocklist_isp_att
rename_ipset ib_isp_twc iblocklist_isp_twc
rename_ipset ib_isp_charter iblocklist_isp_charter
rename_ipset ib_isp_qwest iblocklist_isp_qwest
rename_ipset ib_isp_embarq iblocklist_isp_embarq
rename_ipset ib_isp_suddenlink iblocklist_isp_suddenlink
rename_ipset ib_isp_sprint iblocklist_isp_sprint


# -----------------------------------------------------------------------------
# INTERNAL FILTERS
# all these should be used with pipes

# grep and egrep return 1 if they match nothing
# this will break the filters if the source is empty
# so we make them return 0 always

# match a single IPv4 IP
# zero prefix is not permitted 0 - 255, not 000, 010, etc
IP4_MATCH="(((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9]))"

# match a single IPv4 net mask (/32 allowed, /0 not allowed)
MK4_MATCH="(3[0-2]|[12][0-9]|[1-9])"

# strict checking of IPv4 IPs - all subnets excluded
# we remove /32 before matching
filter_ip4()  { remove_slash32 | $EGREP_CMD "^${IP4_MATCH}$"; return 0; }

# strict checking of IPv4 CIDRs, except /32
# this is to support older ipsets that do not accept /32 in hash:net ipsets
filter_net4() { remove_slash32 | $EGREP_CMD "^${IP4_MATCH}/${MK4_MATCH}$"; return 0; }

# strict checking of IPv4 IPs or CIDRs
# hosts may or may not have /32
filter_all4() { $EGREP_CMD "^${IP4_MATCH}(/${MK4_MATCH})?$"; return 0; }

filter_ip6()  { remove_slash128 | $EGREP_CMD "^([0-9a-fA-F:]+)$"; return 0; }
filter_net6() { remove_slash128 | $EGREP_CMD "^([0-9a-fA-F:]+/[0-9]+)$"; return 0; }
filter_all6() { $EGREP_CMD "^([0-9a-fA-F:]+(/[0-9]+)?)$"; return 0; }

remove_slash32() { $SED_CMD "s|/32$||g"; }
remove_slash128() { $SED_CMD "s|/128$||g"; }

append_slash32() {
	# this command appends '/32' to all the lines
	# that do not include a slash
	$GAWK_CMD '/\// {print $1; next}; // {print $1 "/32" }'
}

append_slash128() {
	# this command appends '/32' to all the lines
	# that do not include a slash
	$GAWK_CMD '/\// {print $1; next}; // {print $1 "/128" }'
}

filter_invalid4() {
	$EGREP_CMD -v "^(0\.0\.0\.0|.*/0)$"
	return 0
}


# -----------------------------------------------------------------------------
# XML DOM PARSER

# excellent article about XML parsing is BASH
# http://stackoverflow.com/questions/893585/how-to-parse-xml-in-bash

XML_ENTITY=
XML_CONTENT=
XML_TAG_NAME=
XML_ATTRIBUTES=
read_xml_dom () {
	local IFS=\>
	read -d \< XML_ENTITY XML_CONTENT
	local ret=$?
	XML_TAG_NAME=${ENTITY%% *}
	XML_ATTRIBUTES=${ENTITY#* }
	return $ret
}


# -----------------------------------------------------------------------------
# XML DOM FILTERS
# all these are to be used in pipes
# they extract IPs from the XML

parse_rss_rosinstrument() {
	while read_xml_dom
	do
		if [ "${XML_ENTITY}" = "title" ]
		then
			[[ "${XML_CONTENT}" =~ ^.*:[0-9]+$ ]] && echo "${XML_CONTENT/:*/}"
		fi
	done |\
	hostname_resolver
}

parse_rss_proxy() {
	while read_xml_dom
	do
		if [ "${XML_ENTITY}" = "prx:ip" ]
		then
			if [[ "${XML_CONTENT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
			then
				echo "${XML_CONTENT}"
			fi
		fi
	done
}

parse_php_rss() {
	while read_xml_dom
	do
		if [ "${XML_ENTITY}" = "title" ]
		then
			if [[ "${XML_CONTENT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*$ ]]
			then
				echo "${XML_CONTENT/|*/}"
			fi
		fi
	done
}

parse_xml_clean_mx() {
	while read_xml_dom
	do
		case "${XML_ENTITY}" in
			ip) echo "${XML_CONTENT}"
		esac
	done
}

parse_dshield_api() {
	while read_xml_dom
		do
		case "${XML_ENTITY}" in
			ip) echo "${XML_CONTENT}"
		esac
	done |\
		$SED_CMD -e "s|0\([1-9][1-9]\)|\1|g" -e "s|00\([1-9]\)|\1|g" -e "s|000|0|g"
}


# -----------------------------------------------------------------------------
# CONVERTERS
# These functions are used to convert from various sources
# to IP or NET addresses

# convert netmask to CIDR format
subnet_to_bitmask() {
	$SED_CMD	-e "s|/255\.255\.255\.255|/32|g" -e "s|/255\.255\.255\.254|/31|g" -e "s|/255\.255\.255\.252|/30|g" \
		-e "s|/255\.255\.255\.248|/29|g" -e "s|/255\.255\.255\.240|/28|g" -e "s|/255\.255\.255\.224|/27|g" \
		-e "s|/255\.255\.255\.192|/26|g" -e "s|/255\.255\.255\.128|/25|g" -e "s|/255\.255\.255\.0|/24|g" \
		-e "s|/255\.255\.254\.0|/23|g"   -e "s|/255\.255\.252\.0|/22|g"   -e "s|/255\.255\.248\.0|/21|g" \
		-e "s|/255\.255\.240\.0|/20|g"   -e "s|/255\.255\.224\.0|/19|g"   -e "s|/255\.255\.192\.0|/18|g" \
		-e "s|/255\.255\.128\.0|/17|g"   -e "s|/255\.255\.0\.0|/16|g"     -e "s|/255\.254\.0\.0|/15|g" \
		-e "s|/255\.252\.0\.0|/14|g"     -e "s|/255\.248\.0\.0|/13|g"     -e "s|/255\.240\.0\.0|/12|g" \
		-e "s|/255\.224\.0\.0|/11|g"     -e "s|/255\.192\.0\.0|/10|g"     -e "s|/255\.128\.0\.0|/9|g" \
		-e "s|/255\.0\.0\.0|/8|g"        -e "s|/254\.0\.0\.0|/7|g"        -e "s|/252\.0\.0\.0|/6|g" \
		-e "s|/248\.0\.0\.0|/5|g"        -e "s|/240\.0\.0\.0|/4|g"        -e "s|/224\.0\.0\.0|/3|g" \
		-e "s|/192\.0\.0\.0|/2|g"        -e "s|/128\.0\.0\.0|/1|g"        -e "s|/0\.0\.0\.0|/0|g"
}

# trim leading, trailing, double spacing, empty lines
trim() {
	$SED_CMD -e "s/[\t ]\+/ /g" -e "s/^ \+//g" -e "s/ \+$//g" |\
		$GREP_CMD -v "^$"
}

# remove comments starting with ';' and trim()
remove_comments_semi_colon() {
	# remove:
	# 1. replace \r with \n
	# 2. everything on the same line after a ;
	# 3. multiple white space (tabs and spaces)
	# 4. leading spaces
	# 5. trailing spaces
	# 6. empty lines
	$TR_CMD "\r" "\n" |\
		$SED_CMD -e "s/;.*$//g" -e "s/[\t ]\+/ /g" -e "s/^ \+//g" -e "s/ \+$//g" |\
		$GREP_CMD -v "^$"
}

# remove comments starting with '#' and trim()
remove_comments() {
	# remove:
	# 1. replace \r with \n
	# 2. everything on the same line after a #
	# 3. multiple white space (tabs and spaces)
	# 4. leading spaces
	# 5. trailing spaces
	# 6. empty lines
	$TR_CMD "\r" "\n" |\
		$SED_CMD -e "s/#.*$//g" -e "s/[\t ]\+/ /g" -e "s/^ \+//g" -e "s/ \+$//g" |\
		$GREP_CMD -v "^$"
}

# ungzip and remove comments
gz_remove_comments() {
	$ZCAT_CMD | remove_comments
}

# convert snort rules to a list of IPs
snort_alert_rules_to_ipv4() {
	remove_comments |\
		$GREP_CMD ^alert |\
		$SED_CMD -e "s|^alert .* \[\([0-9/,\.]\+\)\] any -> \$HOME_NET any .*$|\1|g" -e "s|,|\n|g" |\
		$GREP_CMD -v ^alert
}

# extract IPs from PIX access list deny rules
pix_deny_rules_to_ipv4() {
	remove_comments |\
		$GREP_CMD ^access-list |\
		$SED_CMD -e "s|^access-list .* deny ip \([0-9\.]\+\) \([0-9\.]\+\) any$|\1/\2|g" \
		    -e "s|^access-list .* deny ip host \([0-9\.]\+\) any$|\1|g" |\
		$GREP_CMD -v ^access-list |\
		subnet_to_bitmask
}

# extract CIDRs from the dshield table format
dshield_parser() {
	local net= mask=
	remove_comments |\
		$GREP_CMD "^[1-9]" |\
		$CUT_CMD -d ' ' -f 1,3 |\
		while read net mask
		do
			echo "${net}/${mask}"
		done
}

# unzip the first file in the zip and convert comma to new lines
unzip_and_split_csv() {
	if [ -z "${FUNZIP_CMD}" ]
	then
		error "command 'funzip' is not installed"
		return 1
	fi

	$FUNZIP_CMD | $TR_CMD ",\r" "\n\n"
}

# unzip the first file in the zip
unzip_and_extract() {
	if [ -z "${FUNZIP_CMD}" ]
	then
		error "command 'funzip' is not installed"
		return 1
	fi

	$FUNZIP_CMD
}

# extract IPs from the P2P blocklist
p2p_gz() {
	$ZCAT_CMD |\
		$CUT_CMD -d ':' -f 2 |\
		$EGREP_CMD "^${IP4_MATCH}-${IP4_MATCH}$" |\
		${IPRANGE_CMD}
}

p2p_gz_ips() {
	$ZCAT_CMD |\
		$CUT_CMD -d ':' -f 2 |\
		$EGREP_CMD "^${IP4_MATCH}-${IP4_MATCH}$" |\
		${IPRANGE_CMD} -1
}

# extract only the lines starting with Proxy from the P2P blocklist
p2p_gz_proxy() {
	$ZCAT_CMD |\
		$GREP_CMD "^Proxy" |\
		$CUT_CMD -d ':' -f 2 |\
		$EGREP_CMD "^${IP4_MATCH}-${IP4_MATCH}$" |\
		${IPRANGE_CMD} -1
}

# get the first column from the csv
csv_comma_first_column() {
	$GREP_CMD "^[0-9]" |\
		$CUT_CMD -d ',' -f 1
}

# get the second word from the compressed file
gz_second_word() {
	$ZCAT_CMD |\
		$TR_CMD '\r' '\n' |\
		$CUT_CMD -d ' ' -f 2
}

# extract IPs for the proxyrss file
gz_proxyrss() {
	$ZCAT_CMD |\
		remove_comments |\
		$CUT_CMD -d ':' -f 1
}

# extract IPs from the maxmind proxy fraud page
parse_maxmind_proxy_fraud() {
	$GREP_CMD "href=\"high-risk-ip-sample/" |\
		$CUT_CMD -d '>' -f 2 |\
		$CUT_CMD -d '<' -f 1
}

extract_ipv4_from_any_file() {
	$GREP_CMD --text -oP "(^|[[:punct:]]|[[:space:]]|[[:cntrl:]])${IP4_MATCH}([[:punct:]]|[[:space:]]|[[:cntrl:]]|$)" |\
		$EGREP_CMD -v "${IP4_MATCH}\." |\
		$EGREP_CMD -v "\.${IP4_MATCH}" |\
		$GREP_CMD -oP "${IP4_MATCH}"
}

# process a list of IPs, IP ranges, hostnames
# this is capable of resolving hostnames to IPs
# using parallel DNS queries
hostname_resolver() {
	local opts="--dns-silent --dns-progress"
	if [ ${VERBOSE} -eq 1 ]
		then
		opts=
	elif [ ${SILENT}  -eq 1 ]
		then
		opts="--dns-silent"
	else
		printf >&2 "${print_ipset_spacer}DNS: "
	fi

	${IPRANGE_CMD} -1 --dns-threads ${PARALLEL_DNS_QUERIES} ${opts}
}

# convert hphosts file to IPs, by resolving all IPs
hphosts2ips() {
	remove_comments |\
		$CUT_CMD -d ' ' -f 2- |\
		$TR_CMD " " "\n" |\
		hostname_resolver
}

geolite2_asn() {
	if [ -z "${UNZIP_CMD}" ]
	then
		ipset_error "geolite2_asn" "Command 'unzip' is not installed."
		return 1
	fi

	cd "${RUN_DIR}" || return 1

	local ipset="geolite2_asn" limit="" hash="net" ipv="ipv4" \
		mins=$[24 * 60 * 7] history_mins=0 \
		url="http://geolite.maxmind.com/download/geoip/database/GeoLite2-ASN-CSV.zip" \
		info="[MaxMind GeoLite2 ASN](https://dev.maxmind.com/geoip/geoip2/geolite2/)" \
		ret=

	ipset_shall_be_run "${ipset}"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	# download it
	download_manager "${ipset}" "${mins}" "${url}"
	ret=$?
	if [ $ret -eq ${DOWNLOAD_FAILED} -o $ret -eq ${DOWNLOAD_NOT_UPDATED} ]
		then
		[ ! -s "${BASE_DIR}/${ipset}.source" ] && return 1
		[ -d "${BASE_DIR}/${ipset}" -a ${REPROCESS_ALL} -eq 0 ] && return 1
	fi

	# create a temp dir
	[ -d "${ipset}.tmp" ] && $RM_CMD -rf "${ipset}.tmp"
	$MKDIR_CMD "${ipset}.tmp" || return 1
	cd "${ipset}.tmp" || return 1

	# create the final dir
	if [ ! -d "${BASE_DIR}/${ipset}" ]
	then
		$MKDIR_CMD "${BASE_DIR}/${ipset}" || return 1
	fi

	# extract it

	# The ASN db has the following columns:
	# 1. network 				the subnet
	# 2. autonomous_system_number 			the ASN
	# 3. autonomous_system_organization 	the name of the company that owns this ASN

	ipset_info "${ipset}" "extracting ASN netsets..."
	$UNZIP_CMD -jpx "${BASE_DIR}/${ipset}.source" "*/GeoLite2-ASN-Blocks-IPv4.csv" |\
		$GAWK_CMD -F, '{ print $1 >>$2".source.tmp"; close($2".source.tmp"); }'

	# remove the files created of the header line
	[ -f "ASautonomous_system_number.source.tmp"         ] && $RM_CMD "ASautonomous_system_number.source.tmp"

	ipset_info "${ipset}" "extracting ASN names..."
	$UNZIP_CMD -jpx "${BASE_DIR}/${ipset}.source" "*/GeoLite2-ASN-Blocks-IPv4.csv" |\
		$CUT_CMD -d ',' -f 2,3- |\
		$SORT_CMD -u |\
		$TR_CMD '`$' "'_" |\
		$SED_CMD -e 's|"||g' -e "s|^\([0-9]\+\),\(.*\)$|geolite2_asn_names[\1]=\"\2\"|g" |\
		$GREP_CMD "^geolite2_asn_names" >names.sh

	ipset_info "${ipset}" "reading ASN names..."
	declare -A geolite2_asn_names=()
	source names.sh
	$RM_CMD names.sh

	CACHE_SAVE_ENABLED=0
	ipset_info "${ipset}" "generating ASN netsets..."
	local x i info2 tmp
	for x in *.source.tmp
	do
		i="AS${x/.source.tmp/}"
		tmp="${i}.source"

		ipset_verbose "${i}" "Generating file '${tmp}'"

		$CAT_CMD "${x}" |\
			filter_all4 |\
			${IPRANGE_CMD} |\
			filter_invalid4 >"${tmp}"

		$TOUCH_CMD -r "${BASE_DIR}/${ipset}.source" "${tmp}"
		$RM_CMD "${x}"

		info2="${geolite2_asn_names[${i/AS/}]} -- ${info}"

		finalize "${i}" \
			"${tmp}" \
			"${ipset}.source" \
			"${ipset}/${i}.netset" \
			"${mins}" \
			"${history_mins}" \
			"${ipv}" \
			"${limit}" \
			"${hash}" \
			"${url}" \
			"geolocation" \
			"${info2}" \
			"MaxMind.com" \
			"http://www.maxmind.com/" \
			service "geolocation"

		[ -f "${BASE_DIR}/${i}.setinfo" ] && $MV_CMD -f "${BASE_DIR}/${i}.setinfo" "${BASE_DIR}/${ipset}/${i}.setinfo"

	done
	CACHE_SAVE_ENABLED=1
	cache_save

	# remove the temporary dir
	cd "${RUN_DIR}"
	$RM_CMD -rf "${ipset}.tmp"

	return 0
}

geolite2_country() {
	if [ -z "${UNZIP_CMD}" ]
	then
		ipset_error "geolite2_country" "Command 'unzip' is not installed."
		return 1
	fi

	cd "${RUN_DIR}" || return 1

	local ipset="geolite2_country" limit="" hash="net" ipv="ipv4" \
		mins=$[24 * 60 * 7] history_mins=0 \
		url="http://geolite.maxmind.com/download/geoip/database/GeoLite2-Country-CSV.zip" \
		info="[MaxMind GeoLite2](http://dev.maxmind.com/geoip/geoip2/geolite2/)" \
		ret=

	ipset_shall_be_run "${ipset}"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	# download it
	download_manager "${ipset}" "${mins}" "${url}"
	ret=$?
	if [ $ret -eq ${DOWNLOAD_FAILED} -o $ret -eq ${DOWNLOAD_NOT_UPDATED} ]
		then
		[ ! -s "${BASE_DIR}/${ipset}.source" ] && return 1
		[ -d "${BASE_DIR}/${ipset}" -a ${REPROCESS_ALL} -eq 0 ] && return 1
	fi

	# create a temp dir
	[ -d "${ipset}.tmp" ] && $RM_CMD -rf "${ipset}.tmp"
	$MKDIR_CMD "${ipset}.tmp" || return 1
	cd "${ipset}.tmp" || return 1

	# create the final dir
	if [ ! -d "${BASE_DIR}/${ipset}" ]
	then
		$MKDIR_CMD "${BASE_DIR}/${ipset}" || return 1
	fi

	# get the old version of README-EDIT.md, if any

	# extract it

	# The country db has the following columns:
	# 1. network 				the subnet
	# 2. geoname_id 			the country code it is used
	# 3. registered_country_geoname_id 	the country code it is registered
	# 4. represented_country_geoname_id 	the country code it belongs to (army bases)
	# 5. is_anonymous_proxy 		boolean: VPN providers, etc
	# 6. is_satellite_provider 		boolean: cross-country providers

	ipset_info "${ipset}" "extracting country and continent netsets..."
	$UNZIP_CMD -jpx "${BASE_DIR}/${ipset}.source" "*/GeoLite2-Country-Blocks-IPv4.csv" |\
		$GAWK_CMD -F, '
		{
			if( $2 )        { print $1 >"country."$2".source.tmp" }
			if( $3 )        { print $1 >"country."$3".source.tmp" }
			if( $4 )        { print $1 >"country."$4".source.tmp" }
			if( $5 == "1" ) { print $1 >"anonymous.source.tmp" }
			if( $6 == "1" ) { print $1 >"satellite.source.tmp" }
		}'

	# remove the files created of the header line
	[ -f "country.geoname_id.source.tmp"                     ] && $RM_CMD "country.geoname_id.source.tmp"
	[ -f "country.registered_country_geoname_id.source.tmp"  ] && $RM_CMD "country.registered_country_geoname_id.source.tmp"
	[ -f "country.represented_country_geoname_id.source.tmp" ] && $RM_CMD "country.represented_country_geoname_id.source.tmp"

	# The localization db has the following columns:
	# 1. geoname_id
	# 2. locale_code
	# 3. continent_code
	# 4. continent_name
	# 5. country_iso_code
	# 6. country_name

	ipset_info "${ipset}" "grouping country and continent netsets..."
	$UNZIP_CMD -jpx "${BASE_DIR}/${ipset}.source" "*/GeoLite2-Country-Locations-en.csv" |\
	(
		IFS=","
		while read id locale cid cname iso name
		do
			[ "${id}" = "geoname_id" ] && continue

			cname="${cname//\"/}"
			cname="${cname//[/(}"
			cname="${cname//]/)}"
			name="${name//\"/}"
			name="${name//[/(}"
			name="${name//]/)}"

			ipset_verbose "${ipset}" "extracting country '${id}' (code='${iso}', name='${name}')..."
			if [ -f "country.${id}.source.tmp" ]
			then
				[ "${name}" = "Macedonia" ] && name="F.Y.R.O.M."

				[ ! -z "${cid}" ] && $CAT_CMD "country.${id}.source.tmp" >>"continent_${cid,,}.source.tmp"
				[ ! -z "${iso}" ] && $CAT_CMD "country.${id}.source.tmp" >>"country_${iso,,}.source.tmp"
				$RM_CMD "country.${id}.source.tmp"

				[ ! -f "continent_${cid,,}.source.tmp.info" ] && printf "%s" "${cname} (${cid}), with countries: " >"continent_${cid,,}.source.tmp.info"
				printf "%s" "${name} (${iso}), " >>"continent_${cid,,}.source.tmp.info"
				printf "%s" "${name} (${iso})" >"country_${iso,,}.source.tmp.info"
			else
				ipset_warning "${ipset}" "geoname_id ${id} does not exist!"
			fi
		done
	)
	printf "%s" "Anonymous Service Providers" >"anonymous.source.tmp.info"
	printf "%s" "Satellite Service Providers" >"satellite.source.tmp.info"

	CACHE_SAVE_ENABLED=0
	ipset_info "${ipset}" "aggregating country and continent netsets..."
	local x i info2 tmp
	for x in *.source.tmp
	do
		i=${x/.source.tmp/}
		tmp="${i}.source"

		ipset_verbose "${i}" "Generating file '${tmp}'"

		$CAT_CMD "${x}" |\
			filter_all4 |\
			${IPRANGE_CMD} |\
			filter_invalid4 >"${tmp}"

		$TOUCH_CMD -r "${BASE_DIR}/${ipset}.source" "${tmp}"
		$RM_CMD "${x}"

		info2="`$CAT_CMD "${x}.info"` -- ${info}"

		finalize "${i}" \
			"${tmp}" \
			"${ipset}.source" \
			"${ipset}/${i}.netset" \
			"${mins}" \
			"${history_mins}" \
			"${ipv}" \
			"${limit}" \
			"${hash}" \
			"${url}" \
			"geolocation" \
			"${info2}" \
			"MaxMind.com" \
			"http://www.maxmind.com/" \
			service "geolocation"

		[ -f "${BASE_DIR}/${i}.setinfo" ] && $MV_CMD -f "${BASE_DIR}/${i}.setinfo" "${BASE_DIR}/${ipset}/${i}.setinfo"

	done
	CACHE_SAVE_ENABLED=1
	cache_save

	# remove the temporary dir
	cd "${RUN_DIR}"
	$RM_CMD -rf "${ipset}.tmp"

	return 0
}

declare -A IPDENY_COUNTRY_NAMES='([eu]="European Union" [ap]="African Regional Industrial Property Organization" [as]="American Samoa" [ge]="Georgia" [ar]="Argentina" [gd]="Grenada" [dm]="Dominica" [kp]="North Korea" [rw]="Rwanda" [gg]="Guernsey" [qa]="Qatar" [ni]="Nicaragua" [do]="Dominican Republic" [gf]="French Guiana" [ru]="Russia" [kr]="Republic of Korea" [aw]="Aruba" [ga]="Gabon" [rs]="Serbia" [no]="Norway" [nl]="Netherlands" [au]="Australia" [kw]="Kuwait" [dj]="Djibouti" [at]="Austria" [gb]="United Kingdom" [dk]="Denmark" [ky]="Cayman Islands" [gm]="Gambia" [ug]="Uganda" [gl]="Greenland" [de]="Germany" [nc]="New Caledonia" [az]="Azerbaijan" [hr]="Croatia" [na]="Namibia" [gn]="Guinea" [kz]="Kazakhstan" [et]="Ethiopia" [ht]="Haiti" [es]="Spain" [gi]="Gibraltar" [nf]="Norfolk Island" [ng]="Nigeria" [gh]="Ghana" [hu]="Hungary" [er]="Eritrea" [ua]="Ukraine" [ne]="Niger" [yt]="Mayotte" [gu]="Guam" [nz]="New Zealand" [om]="Oman" [gt]="Guatemala" [gw]="Guinea-Bissau" [hk]="Hong Kong" [re]="Réunion" [ag]="Antigua and Barbuda" [gq]="Equatorial Guinea" [ke]="Kenya" [gp]="Guadeloupe" [uz]="Uzbekistan" [af]="Afghanistan" [hn]="Honduras" [uy]="Uruguay" [dz]="Algeria" [kg]="Kyrgyzstan" [ae]="United Arab Emirates" [ad]="Andorra" [gr]="Greece" [ki]="Kiribati" [nr]="Nauru" [eg]="Egypt" [kh]="Cambodia" [ro]="Romania" [ai]="Anguilla" [np]="Nepal" [ee]="Estonia" [us]="United States" [ec]="Ecuador" [gy]="Guyana" [ao]="Angola" [km]="Comoros" [am]="Armenia" [ye]="Yemen" [nu]="Niue" [kn]="Saint Kitts and Nevis" [al]="Albania" [si]="Slovenia" [fr]="France" [bf]="Burkina Faso" [mw]="Malawi" [cy]="Cyprus" [vc]="Saint Vincent and the Grenadines" [mv]="Maldives" [bg]="Bulgaria" [pr]="Puerto Rico" [sk]="Slovak Republic" [bd]="Bangladesh" [mu]="Mauritius" [ps]="Palestine" [va]="Vatican City" [cz]="Czech Republic" [be]="Belgium" [mt]="Malta" [zm]="Zambia" [ms]="Montserrat" [bb]="Barbados" [sm]="San Marino" [pt]="Portugal" [io]="British Indian Ocean Territory" [vg]="British Virgin Islands" [sl]="Sierra Leone" [mr]="Mauritania" [la]="Laos" [in]="India" [ws]="Samoa" [mq]="Martinique" [im]="Isle of Man" [lb]="Lebanon" [tz]="Tanzania" [so]="Somalia" [mp]="Northern Mariana Islands" [ve]="Venezuela" [lc]="Saint Lucia" [ba]="Bosnia and Herzegovina" [sn]="Senegal" [pw]="Palau" [il]="Israel" [tt]="Trinidad and Tobago" [bn]="Brunei" [sa]="Saudi Arabia" [bo]="Bolivia" [py]="Paraguay" [bl]="Saint-Barthélemy" [tv]="Tuvalu" [sc]="Seychelles" [vi]="U.S. Virgin Islands" [cr]="Costa Rica" [bm]="Bermuda" [sb]="Solomon Islands" [tw]="Taiwan" [cu]="Cuba" [se]="Sweden" [bj]="Benin" [vn]="Vietnam" [li]="Liechtenstein" [mz]="Mozambique" [sd]="Sudan" [cw]="Curaçao" [ie]="Ireland" [sg]="Singapore" [jp]="Japan" [my]="Malaysia" [tr]="Turkey" [bh]="Bahrain" [mx]="Mexico" [cv]="Cape Verde" [id]="Indonesia" [lk]="Sri Lanka" [za]="South Africa" [bi]="Burundi" [ci]="Ivory Coast" [tl]="East Timor" [mg]="Madagascar" [lt]="Republic of Lithuania" [sy]="Syria" [sx]="Sint Maarten" [pa]="Panama" [mf]="Saint Martin" [lu]="Luxembourg" [ch]="Switzerland" [tm]="Turkmenistan" [bw]="Botswana" [jo]="Hashemite Kingdom of Jordan" [me]="Montenegro" [tn]="Tunisia" [ck]="Cook Islands" [bt]="Bhutan" [lv]="Latvia" [wf]="Wallis and Futuna" [to]="Tonga" [jm]="Jamaica" [sz]="Swaziland" [md]="Republic of Moldova" [br]="Brazil" [mc]="Monaco" [cm]="Cameroon" [th]="Thailand" [pe]="Peru" [cl]="Chile" [bs]="Bahamas" [pf]="French Polynesia" [co]="Colombia" [ma]="Morocco" [lr]="Liberia" [tj]="Tajikistan" [bq]="Bonaire, Sint Eustatius, and Saba" [tk]="Tokelau" [vu]="Vanuatu" [pg]="Papua New Guinea" [cn]="China" [ls]="Lesotho" [ca]="Canada" [is]="Iceland" [td]="Chad" [fj]="Fiji" [mo]="Macao" [ph]="Philippines" [mn]="Mongolia" [zw]="Zimbabwe" [ir]="Iran" [ss]="South Sudan" [mm]="Myanmar (Burma)" [iq]="Iraq" [sr]="Suriname" [je]="Jersey" [ml]="Mali" [tg]="Togo" [pk]="Pakistan" [fi]="Finland" [bz]="Belize" [pl]="Poland" [mk]="F.Y.R.O.M." [pm]="Saint Pierre and Miquelon" [fo]="Faroe Islands" [st]="São Tomé and Príncipe" [ly]="Libya" [cd]="Congo" [cg]="Republic of the Congo" [sv]="El Salvador" [tc]="Turks and Caicos Islands" [it]="Italy" [fm]="Federated States of Micronesia" [mh]="Marshall Islands" [by]="Belarus" [cf]="Central African Republic" [cx]="Christmas Island" [xk]="Kosovo" [aq]="Antarctic")'
declare -A IPDENY_COUNTRY_CONTINENTS='([eu]="eu" [ap]="af" [as]="oc" [ge]="as" [ar]="sa" [gd]="na" [dm]="na" [kp]="as" [rw]="af" [gg]="eu" [qa]="as" [ni]="na" [do]="na" [gf]="sa" [ru]="eu" [kr]="as" [aw]="na" [ga]="af" [rs]="eu" [no]="eu" [nl]="eu" [au]="oc" [kw]="as" [dj]="af" [at]="eu" [gb]="eu" [dk]="eu" [ky]="na" [gm]="af" [ug]="af" [gl]="na" [de]="eu" [nc]="oc" [az]="as" [hr]="eu" [na]="af" [gn]="af" [kz]="as" [et]="af" [ht]="na" [es]="eu" [gi]="eu" [nf]="oc" [ng]="af" [gh]="af" [hu]="eu" [er]="af" [ua]="eu" [ne]="af" [yt]="af" [gu]="oc" [nz]="oc" [om]="as" [gt]="na" [gw]="af" [hk]="as" [re]="af" [ag]="na" [gq]="af" [ke]="af" [gp]="na" [uz]="as" [af]="as" [hn]="na" [uy]="sa" [dz]="af" [kg]="as" [ae]="as" [ad]="eu" [gr]="eu" [ki]="oc" [nr]="oc" [eg]="af" [kh]="as" [ro]="eu" [ai]="na" [np]="as" [ee]="eu" [us]="na" [ec]="sa" [gy]="sa" [ao]="af" [km]="af" [am]="as" [ye]="as" [nu]="oc" [kn]="na" [al]="eu" [si]="eu" [fr]="eu" [bf]="af" [mw]="af" [cy]="eu" [vc]="na" [mv]="as" [bg]="eu" [pr]="na" [sk]="eu" [bd]="as" [mu]="af" [ps]="as" [va]="eu" [cz]="eu" [be]="eu" [mt]="eu" [zm]="af" [ms]="na" [bb]="na" [sm]="eu" [pt]="eu" [io]="as" [vg]="na" [sl]="af" [mr]="af" [la]="as" [in]="as" [ws]="oc" [mq]="na" [im]="eu" [lb]="as" [tz]="af" [so]="af" [mp]="oc" [ve]="sa" [lc]="na" [ba]="eu" [sn]="af" [pw]="oc" [il]="as" [tt]="na" [bn]="as" [sa]="as" [bo]="sa" [py]="sa" [bl]="na" [tv]="oc" [sc]="af" [vi]="na" [cr]="na" [bm]="na" [sb]="oc" [tw]="as" [cu]="na" [se]="eu" [bj]="af" [vn]="as" [li]="eu" [mz]="af" [sd]="af" [cw]="na" [ie]="eu" [sg]="as" [jp]="as" [my]="as" [tr]="as" [bh]="as" [mx]="na" [cv]="af" [id]="as" [lk]="as" [za]="af" [bi]="af" [ci]="af" [tl]="oc" [mg]="af" [lt]="eu" [sy]="as" [sx]="na" [pa]="na" [mf]="na" [lu]="eu" [ch]="eu" [tm]="as" [bw]="af" [jo]="as" [me]="eu" [tn]="af" [ck]="oc" [bt]="as" [lv]="eu" [wf]="oc" [to]="oc" [jm]="na" [sz]="af" [md]="eu" [br]="sa" [mc]="eu" [cm]="af" [th]="as" [pe]="sa" [cl]="sa" [bs]="na" [pf]="oc" [co]="sa" [ma]="af" [lr]="af" [tj]="as" [bq]="na" [tk]="oc" [vu]="oc" [pg]="oc" [cn]="as" [ls]="af" [ca]="na" [is]="eu" [td]="af" [fj]="oc" [mo]="as" [ph]="as" [mn]="as" [zw]="af" [ir]="as" [ss]="af" [mm]="as" [iq]="as" [sr]="sa" [je]="eu" [ml]="af" [tg]="af" [pk]="as" [fi]="eu" [bz]="na" [pl]="eu" [mk]="eu" [pm]="na" [fo]="eu" [st]="af" [ly]="af" [cd]="af" [cg]="af" [sv]="na" [tc]="na" [it]="eu" [fm]="oc" [mh]="oc" [by]="eu" [cf]="af" [xk]="eu" [cx]="as")'
declare -A IPDENY_COUNTRIES=()
declare -A IPDENY_CONTINENTS=()
ipdeny_country() {
	cd "${RUN_DIR}" || return 1

	local ipset="ipdeny_country" limit="" hash="net" ipv="ipv4" \
		mins=$[24 * 60 * 1] history_mins=0 \
		url="http://www.ipdeny.com/ipblocks/data/countries/all-zones.tar.gz" \
		info="[IPDeny.com](http://www.ipdeny.com/)" \
		ret=

	ipset_shall_be_run "${ipset}"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	# download it
	download_manager "${ipset}" "${mins}" "${url}"
	ret=$?
	if [ $ret -eq ${DOWNLOAD_FAILED} -o $ret -eq ${DOWNLOAD_NOT_UPDATED} ]
		then
		[ ! -s "${BASE_DIR}/${ipset}.source" ] && return 1
		[ -d "${BASE_DIR}/${ipset}" -a ${REPROCESS_ALL} -eq 0 ] && return 1
	fi

	# create a temp dir
	[ -d "${ipset}.tmp" ] && $RM_CMD -rf "${ipset}.tmp"
	$MKDIR_CMD "${ipset}.tmp" || return 1
	cd "${ipset}.tmp" || return 1

	# create the final dir
	if [ ! -d "${BASE_DIR}/${ipset}" ]
	then
		$MKDIR_CMD "${BASE_DIR}/${ipset}" || return 1
	fi

	# get the old version of README-EDIT.md, if any
	# extract it
	$TAR_CMD -zxpf "${BASE_DIR}/${ipset}.source"

	# move them inside the tmp, and fix continents
	local x=
	for x in $($FIND_CMD . -type f -a -name \*.zone)
	do
		x=${x/*\//}
		x=${x/.zone/}
		IPDENY_COUNTRIES[${x}]="1"

		ipset_verbose "${ipset}" "extracting country '${x}' (code='${x^^}', name='${IPDENY_COUNTRY_NAMES[${x}]}')..."

		if [ ! -z "${IPDENY_COUNTRY_CONTINENTS[${x}]}" ]
			then
			[ ! -f "id_continent_${IPDENY_COUNTRY_CONTINENTS[${x}]}.source.tmp.info" ] && \
				printf "%s" "Continent ${IPDENY_COUNTRY_CONTINENTS[${x}]}, with countries: " >"id_continent_${IPDENY_COUNTRY_CONTINENTS[${x}]}.source.tmp.info"

			printf "%s" "${IPDENY_COUNTRY_NAMES[${x}]} (${x^^}), " >>"id_continent_${IPDENY_COUNTRY_CONTINENTS[${x}]}.source.tmp.info"

			$CAT_CMD "${x}.zone" >>"id_continent_${IPDENY_COUNTRY_CONTINENTS[${x}]}.source.tmp"
			IPDENY_CONTINENTS[${IPDENY_COUNTRY_CONTINENTS[${x}]}]="1"
		else
			ipset_warning "${ipset}" "I don't know the continent of country ${x}."
		fi

		printf "%s" "${IPDENY_COUNTRY_NAMES[${x}]} (${x^^})" >"id_country_${x}.source.tmp.info"
		$MV_CMD "${x}.zone" "id_country_${x}.source.tmp"
	done

	ipset_info "${ipset}" "aggregating country and continent netsets..."
	local i info2 tmp
	for x in *.source.tmp
	do
		i="${x/.source.tmp/}"
		tmp="${i}.source"
		info2="`$CAT_CMD "${x}.info"` -- ${info}"

		ipset_verbose "${i}" "Generating file '${tmp}'"

		$CAT_CMD "${x}" |\
			filter_all4 |\
			${IPRANGE_CMD} |\
			filter_invalid4 >"${tmp}"

		$TOUCH_CMD -r "${BASE_DIR}/${ipset}.source" "${tmp}"
		$RM_CMD "${x}"

		finalize "${i}" \
			"${tmp}" \
			"${ipset}.source" \
			"${ipset}/${i}.netset" \
			"${mins}" \
			"${history_mins}" \
			"${ipv}" \
			"${limit}" \
			"${hash}" \
			"${url}" \
			"geolocation" \
			"${info2}" \
			"IPDeny.com" \
			"http://www.ipdeny.com/" \
			service "geolocation"

		[ -f "${BASE_DIR}/${i}.setinfo" ] && $MV_CMD -f "${BASE_DIR}/${i}.setinfo" "${BASE_DIR}/${ipset}/${i}.setinfo"

	done

	# remove the temporary dir
	cd "${RUN_DIR}"
	$RM_CMD -rf "${ipset}.tmp"

	return 0
}

declare -A IP2LOCATION_COUNTRY_NAMES=()
declare -A IP2LOCATION_COUNTRY_CONTINENTS='([aq]="aq" [gs]="eu" [um]="na" [fk]="sa" [ax]="eu" [as]="oc" [ge]="as" [ar]="sa" [gd]="na" [dm]="na" [kp]="as" [rw]="af" [gg]="eu" [qa]="as" [ni]="na" [do]="na" [gf]="sa" [ru]="eu" [kr]="as" [aw]="na" [ga]="af" [rs]="eu" [no]="eu" [nl]="eu" [au]="oc" [kw]="as" [dj]="af" [at]="eu" [gb]="eu" [dk]="eu" [ky]="na" [gm]="af" [ug]="af" [gl]="na" [de]="eu" [nc]="oc" [az]="as" [hr]="eu" [na]="af" [gn]="af" [kz]="as" [et]="af" [ht]="na" [es]="eu" [gi]="eu" [nf]="oc" [ng]="af" [gh]="af" [hu]="eu" [er]="af" [ua]="eu" [ne]="af" [yt]="af" [gu]="oc" [nz]="oc" [om]="as" [gt]="na" [gw]="af" [hk]="as" [re]="af" [ag]="na" [gq]="af" [ke]="af" [gp]="na" [uz]="as" [af]="as" [hn]="na" [uy]="sa" [dz]="af" [kg]="as" [ae]="as" [ad]="eu" [gr]="eu" [ki]="oc" [nr]="oc" [eg]="af" [kh]="as" [ro]="eu" [ai]="na" [np]="as" [ee]="eu" [us]="na" [ec]="sa" [gy]="sa" [ao]="af" [km]="af" [am]="as" [ye]="as" [nu]="oc" [kn]="na" [al]="eu" [si]="eu" [fr]="eu" [bf]="af" [mw]="af" [cy]="eu" [vc]="na" [mv]="as" [bg]="eu" [pr]="na" [sk]="eu" [bd]="as" [mu]="af" [ps]="as" [va]="eu" [cz]="eu" [be]="eu" [mt]="eu" [zm]="af" [ms]="na" [bb]="na" [sm]="eu" [pt]="eu" [io]="as" [vg]="na" [sl]="af" [mr]="af" [la]="as" [in]="as" [ws]="oc" [mq]="na" [im]="eu" [lb]="as" [tz]="af" [so]="af" [mp]="oc" [ve]="sa" [lc]="na" [ba]="eu" [sn]="af" [pw]="oc" [il]="as" [tt]="na" [bn]="as" [sa]="as" [bo]="sa" [py]="sa" [bl]="na" [tv]="oc" [sc]="af" [vi]="na" [cr]="na" [bm]="na" [sb]="oc" [tw]="as" [cu]="na" [se]="eu" [bj]="af" [vn]="as" [li]="eu" [mz]="af" [sd]="af" [cw]="na" [ie]="eu" [sg]="as" [jp]="as" [my]="as" [tr]="as" [bh]="as" [mx]="na" [cv]="af" [id]="as" [lk]="as" [za]="af" [bi]="af" [ci]="af" [tl]="oc" [mg]="af" [lt]="eu" [sy]="as" [sx]="na" [pa]="na" [mf]="na" [lu]="eu" [ch]="eu" [tm]="as" [bw]="af" [jo]="as" [me]="eu" [tn]="af" [ck]="oc" [bt]="as" [lv]="eu" [wf]="oc" [to]="oc" [jm]="na" [sz]="af" [md]="eu" [br]="sa" [mc]="eu" [cm]="af" [th]="as" [pe]="sa" [cl]="sa" [bs]="na" [pf]="oc" [co]="sa" [ma]="af" [lr]="af" [tj]="as" [bq]="na" [tk]="oc" [vu]="oc" [pg]="oc" [cn]="as" [ls]="af" [ca]="na" [is]="eu" [td]="af" [fj]="oc" [mo]="as" [ph]="as" [mn]="as" [zw]="af" [ir]="as" [ss]="af" [mm]="as" [iq]="as" [sr]="sa" [je]="eu" [ml]="af" [tg]="af" [pk]="as" [fi]="eu" [bz]="na" [pl]="eu" [mk]="eu" [pm]="na" [fo]="eu" [st]="af" [ly]="af" [cd]="af" [cg]="af" [sv]="na" [tc]="na" [it]="eu" [fm]="oc" [mh]="oc" [by]="eu" [cf]="af" [xk]="eu" [cx]="as" )'
declare -A IP2LOCATION_COUNTRIES=()
declare -A IP2LOCATION_CONTINENTS=()
ip2location_country() {
	if [ -z "${UNZIP_CMD}" ]
	then
		ipset_error "ip2location_country" "Command 'unzip' is not installed."
		return 1
	fi

	cd "${RUN_DIR}" || return 1

	local ipset="ip2location_country" limit="" hash="net" ipv="ipv4" \
		mins=$[24 * 60 * 1] history_mins=0 \
		url="http://download.ip2location.com/lite/IP2LOCATION-LITE-DB1.CSV.ZIP" \
		info="[IP2Location.com](http://lite.ip2location.com/database-ip-country)" \
		ret=

	ipset_shall_be_run "${ipset}"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	# download it
	download_manager "${ipset}" "${mins}" "${url}"
	ret=$?
	if [ $ret -eq ${DOWNLOAD_FAILED} -o $ret -eq ${DOWNLOAD_NOT_UPDATED} ]
		then
		[ ! -s "${BASE_DIR}/${ipset}.source" ] && return 1
		[ -d "${BASE_DIR}/${ipset}" -a ${REPROCESS_ALL} -eq 0 ] && return 1
	fi

	# create a temp dir
	[ -d "${ipset}.tmp" ] && $RM_CMD -rf "${ipset}.tmp"
	$MKDIR_CMD "${ipset}.tmp" || return 1
	cd "${ipset}.tmp" || return 1

	# extract it - in a subshell to do it in the tmp dir
	$UNZIP_CMD -x "${BASE_DIR}/${ipset}.source"
	local file="IP2LOCATION-LITE-DB1.CSV"

	if [ ! -f "${file}" ]
		then
		ipset_error "${ipset}" "failed to find file '${file}' in downloaded archive"
		return 1
	fi

	# create the final dir
	if [ ! -d "${BASE_DIR}/${ipset}" ]
	then
		$MKDIR_CMD "${BASE_DIR}/${ipset}" || return 1
	fi

	# find all the countries in the file
	ipset_info "${ipset}" "finding included countries..."
	$CAT_CMD "${file}" |\
		$CUT_CMD -d ',' -f 3,4 |\
		$SORT_CMD -u |\
		$SED_CMD 's/","/|/g' |\
		$TR_CMD '"\r' '  ' |\
		trim >countries

	local code= name=
	while IFS="|" read code name
	do
		if [ "a${code}" = "a-" ]
			then
			name="IPs that do not belong to any country"
		fi

		[ "${name}" = "Macedonia" ] && name="F.Y.R.O.M."
		IP2LOCATION_COUNTRY_NAMES[${code}]="${name}"
	done <countries

	ipset_info "${ipset}" "extracting countries..."
	local x=
	for x in ${!IP2LOCATION_COUNTRY_NAMES[@]}
	do
		if [ "a${x}" = "a-" ]
			then
			code="countryless"
			name="IPs that do not belong to any country"
		else
			code="${x,,}"
			name=${IP2LOCATION_COUNTRY_NAMES[${x}]}
		fi

		ipset_verbose "${ipset}" "extracting country '${x}' (code='${code}', name='${name}')..."
		$CAT_CMD "${file}" 			|\
			$GREP_CMD ",\"${x}\"," 	|\
			$CUT_CMD -d ',' -f 1,2 	|\
			$SED_CMD 's/","/ - /g' 	|\
			$TR_CMD '"' ' ' 		|\
			${IPRANGE_CMD} 			|\
			filter_invalid4 >"ip2location_country_${code}.source.tmp"

		if [ ! -z "${IP2LOCATION_COUNTRY_CONTINENTS[${code}]}" ]
			then
			[ ! -f "id_continent_${IP2LOCATION_COUNTRY_CONTINENTS[${code}]}.source.tmp.info" ] && printf "%s" "Continent ${IP2LOCATION_COUNTRY_CONTINENTS[${code}]}, with countries: " >"id_continent_${IP2LOCATION_COUNTRY_CONTINENTS[${code}]}.source.tmp.info"
			printf "%s" "${IP2LOCATION_COUNTRY_NAMES[${x}]} (${code^^}), " >>"ip2location_continent_${IP2LOCATION_COUNTRY_CONTINENTS[${code}]}.source.tmp.info"
			$CAT_CMD "ip2location_country_${code}.source.tmp" >>"ip2location_continent_${IP2LOCATION_COUNTRY_CONTINENTS[${code}]}.source.tmp"
			IP2LOCATION_CONTINENTS[${IP2LOCATION_COUNTRY_CONTINENTS[${code}]}]="1"
		else
			[ ! "${code}" = "countryless" ] && ipset_warning "${ipset}" "I don't know the continent of country ${code}."
		fi

		printf "%s" "${IP2LOCATION_COUNTRY_NAMES[${x}]} (${code^^})" >"ip2location_country_${code}.source.tmp.info"
	done

	ipset_info "${ipset}" "aggregating country and continent netsets..."
	local i info tmp
	for x in *.source.tmp
	do
		i=${x/.source.tmp/}
		tmp="${i}.source"
		local info2="$($CAT_CMD "${x}.info") -- ${info}"

		$MV_CMD "${x}" "${tmp}"
		$TOUCH_CMD -r "${BASE_DIR}/${ipset}.source" "${tmp}"

		finalize "${i}" \
			"${tmp}" \
			"${ipset}.source" \
			"${ipset}/${i}.netset" \
			"${mins}" \
			"${history_mins}" \
			"${ipv}" \
			"${limit}" \
			"${hash}" \
			"${url}" \
			"geolocation" \
			"${info2}" \
			"IP2Location.com" \
			"http://lite.ip2location.com/database-ip-country" \
			service "geolocation"

		[ -f "${BASE_DIR}/${i}.setinfo" ] && $MV_CMD -f "${BASE_DIR}/${i}.setinfo" "${BASE_DIR}/${ipset}/${i}.setinfo"

	done

	# remove the temporary dir
	cd "${RUN_DIR}"
	$RM_CMD -rf ${ipset}.tmp

	return 0
}

declare -A IPIP_COUNTRY_NAMES='([eu]="European Union" [ap]="African Regional Industrial Property Organization" [as]="American Samoa" [ge]="Georgia" [ar]="Argentina" [gd]="Grenada" [dm]="Dominica" [kp]="North Korea" [rw]="Rwanda" [gg]="Guernsey" [qa]="Qatar" [ni]="Nicaragua" [do]="Dominican Republic" [gf]="French Guiana" [ru]="Russia" [kr]="Republic of Korea" [aw]="Aruba" [ga]="Gabon" [rs]="Serbia" [no]="Norway" [nl]="Netherlands" [au]="Australia" [kw]="Kuwait" [dj]="Djibouti" [at]="Austria" [gb]="United Kingdom" [dk]="Denmark" [ky]="Cayman Islands" [gm]="Gambia" [ug]="Uganda" [gl]="Greenland" [de]="Germany" [nc]="New Caledonia" [az]="Azerbaijan" [hr]="Croatia" [na]="Namibia" [gn]="Guinea" [kz]="Kazakhstan" [et]="Ethiopia" [ht]="Haiti" [es]="Spain" [gi]="Gibraltar" [nf]="Norfolk Island" [ng]="Nigeria" [gh]="Ghana" [hu]="Hungary" [er]="Eritrea" [ua]="Ukraine" [ne]="Niger" [yt]="Mayotte" [gu]="Guam" [nz]="New Zealand" [om]="Oman" [gt]="Guatemala" [gw]="Guinea-Bissau" [hk]="Hong Kong" [re]="Réunion" [ag]="Antigua and Barbuda" [gq]="Equatorial Guinea" [ke]="Kenya" [gp]="Guadeloupe" [uz]="Uzbekistan" [af]="Afghanistan" [hn]="Honduras" [uy]="Uruguay" [dz]="Algeria" [kg]="Kyrgyzstan" [ae]="United Arab Emirates" [ad]="Andorra" [gr]="Greece" [ki]="Kiribati" [nr]="Nauru" [eg]="Egypt" [kh]="Cambodia" [ro]="Romania" [ai]="Anguilla" [np]="Nepal" [ee]="Estonia" [us]="United States" [ec]="Ecuador" [gy]="Guyana" [ao]="Angola" [km]="Comoros" [am]="Armenia" [ye]="Yemen" [nu]="Niue" [kn]="Saint Kitts and Nevis" [al]="Albania" [si]="Slovenia" [fr]="France" [bf]="Burkina Faso" [mw]="Malawi" [cy]="Cyprus" [vc]="Saint Vincent and the Grenadines" [mv]="Maldives" [bg]="Bulgaria" [pr]="Puerto Rico" [sk]="Slovak Republic" [bd]="Bangladesh" [mu]="Mauritius" [ps]="Palestine" [va]="Vatican City" [cz]="Czech Republic" [be]="Belgium" [mt]="Malta" [zm]="Zambia" [ms]="Montserrat" [bb]="Barbados" [sm]="San Marino" [pt]="Portugal" [io]="British Indian Ocean Territory" [vg]="British Virgin Islands" [sl]="Sierra Leone" [mr]="Mauritania" [la]="Laos" [in]="India" [ws]="Samoa" [mq]="Martinique" [im]="Isle of Man" [lb]="Lebanon" [tz]="Tanzania" [so]="Somalia" [mp]="Northern Mariana Islands" [ve]="Venezuela" [lc]="Saint Lucia" [ba]="Bosnia and Herzegovina" [sn]="Senegal" [pw]="Palau" [il]="Israel" [tt]="Trinidad and Tobago" [bn]="Brunei" [sa]="Saudi Arabia" [bo]="Bolivia" [py]="Paraguay" [bl]="Saint-Barthélemy" [tv]="Tuvalu" [sc]="Seychelles" [vi]="U.S. Virgin Islands" [cr]="Costa Rica" [bm]="Bermuda" [sb]="Solomon Islands" [tw]="Taiwan" [cu]="Cuba" [se]="Sweden" [bj]="Benin" [vn]="Vietnam" [li]="Liechtenstein" [mz]="Mozambique" [sd]="Sudan" [cw]="Curaçao" [ie]="Ireland" [sg]="Singapore" [jp]="Japan" [my]="Malaysia" [tr]="Turkey" [bh]="Bahrain" [mx]="Mexico" [cv]="Cape Verde" [id]="Indonesia" [lk]="Sri Lanka" [za]="South Africa" [bi]="Burundi" [ci]="Ivory Coast" [tl]="East Timor" [mg]="Madagascar" [lt]="Republic of Lithuania" [sy]="Syria" [sx]="Sint Maarten" [pa]="Panama" [mf]="Saint Martin" [lu]="Luxembourg" [ch]="Switzerland" [tm]="Turkmenistan" [bw]="Botswana" [jo]="Hashemite Kingdom of Jordan" [me]="Montenegro" [tn]="Tunisia" [ck]="Cook Islands" [bt]="Bhutan" [lv]="Latvia" [wf]="Wallis and Futuna" [to]="Tonga" [jm]="Jamaica" [sz]="Swaziland" [md]="Republic of Moldova" [br]="Brazil" [mc]="Monaco" [cm]="Cameroon" [th]="Thailand" [pe]="Peru" [cl]="Chile" [bs]="Bahamas" [pf]="French Polynesia" [co]="Colombia" [ma]="Morocco" [lr]="Liberia" [tj]="Tajikistan" [bq]="Bonaire, Sint Eustatius, and Saba" [tk]="Tokelau" [vu]="Vanuatu" [pg]="Papua New Guinea" [cn]="China" [ls]="Lesotho" [ca]="Canada" [is]="Iceland" [td]="Chad" [fj]="Fiji" [mo]="Macao" [ph]="Philippines" [mn]="Mongolia" [zw]="Zimbabwe" [ir]="Iran" [ss]="South Sudan" [mm]="Myanmar (Burma)" [iq]="Iraq" [sr]="Suriname" [je]="Jersey" [ml]="Mali" [tg]="Togo" [pk]="Pakistan" [fi]="Finland" [bz]="Belize" [pl]="Poland" [mk]="F.Y.R.O.M." [pm]="Saint Pierre and Miquelon" [fo]="Faroe Islands" [st]="São Tomé and Príncipe" [ly]="Libya" [cd]="Congo" [cg]="Republic of the Congo" [sv]="El Salvador" [tc]="Turks and Caicos Islands" [it]="Italy" [fm]="Federated States of Micronesia" [mh]="Marshall Islands" [by]="Belarus" [cf]="Central African Republic" [cx]="Christmas Island" [xk]="Kosovo" [aq]="Antarctic")'
declare -A IPIP_COUNTRY_CONTINENTS='([aq]="aq" [gs]="eu" [um]="na" [fk]="sa" [ax]="eu" [as]="oc" [ge]="as" [ar]="sa" [gd]="na" [dm]="na" [kp]="as" [rw]="af" [gg]="eu" [qa]="as" [ni]="na" [do]="na" [gf]="sa" [ru]="eu" [kr]="as" [aw]="na" [ga]="af" [rs]="eu" [no]="eu" [nl]="eu" [au]="oc" [kw]="as" [dj]="af" [at]="eu" [gb]="eu" [dk]="eu" [ky]="na" [gm]="af" [ug]="af" [gl]="na" [de]="eu" [nc]="oc" [az]="as" [hr]="eu" [na]="af" [gn]="af" [kz]="as" [et]="af" [ht]="na" [es]="eu" [gi]="eu" [nf]="oc" [ng]="af" [gh]="af" [hu]="eu" [er]="af" [ua]="eu" [ne]="af" [yt]="af" [gu]="oc" [nz]="oc" [om]="as" [gt]="na" [gw]="af" [hk]="as" [re]="af" [ag]="na" [gq]="af" [ke]="af" [gp]="na" [uz]="as" [af]="as" [hn]="na" [uy]="sa" [dz]="af" [kg]="as" [ae]="as" [ad]="eu" [gr]="eu" [ki]="oc" [nr]="oc" [eg]="af" [kh]="as" [ro]="eu" [ai]="na" [np]="as" [ee]="eu" [us]="na" [ec]="sa" [gy]="sa" [ao]="af" [km]="af" [am]="as" [ye]="as" [nu]="oc" [kn]="na" [al]="eu" [si]="eu" [fr]="eu" [bf]="af" [mw]="af" [cy]="eu" [vc]="na" [mv]="as" [bg]="eu" [pr]="na" [sk]="eu" [bd]="as" [mu]="af" [ps]="as" [va]="eu" [cz]="eu" [be]="eu" [mt]="eu" [zm]="af" [ms]="na" [bb]="na" [sm]="eu" [pt]="eu" [io]="as" [vg]="na" [sl]="af" [mr]="af" [la]="as" [in]="as" [ws]="oc" [mq]="na" [im]="eu" [lb]="as" [tz]="af" [so]="af" [mp]="oc" [ve]="sa" [lc]="na" [ba]="eu" [sn]="af" [pw]="oc" [il]="as" [tt]="na" [bn]="as" [sa]="as" [bo]="sa" [py]="sa" [bl]="na" [tv]="oc" [sc]="af" [vi]="na" [cr]="na" [bm]="na" [sb]="oc" [tw]="as" [cu]="na" [se]="eu" [bj]="af" [vn]="as" [li]="eu" [mz]="af" [sd]="af" [cw]="na" [ie]="eu" [sg]="as" [jp]="as" [my]="as" [tr]="as" [bh]="as" [mx]="na" [cv]="af" [id]="as" [lk]="as" [za]="af" [bi]="af" [ci]="af" [tl]="oc" [mg]="af" [lt]="eu" [sy]="as" [sx]="na" [pa]="na" [mf]="na" [lu]="eu" [ch]="eu" [tm]="as" [bw]="af" [jo]="as" [me]="eu" [tn]="af" [ck]="oc" [bt]="as" [lv]="eu" [wf]="oc" [to]="oc" [jm]="na" [sz]="af" [md]="eu" [br]="sa" [mc]="eu" [cm]="af" [th]="as" [pe]="sa" [cl]="sa" [bs]="na" [pf]="oc" [co]="sa" [ma]="af" [lr]="af" [tj]="as" [bq]="na" [tk]="oc" [vu]="oc" [pg]="oc" [cn]="as" [ls]="af" [ca]="na" [is]="eu" [td]="af" [fj]="oc" [mo]="as" [ph]="as" [mn]="as" [zw]="af" [ir]="as" [ss]="af" [mm]="as" [iq]="as" [sr]="sa" [je]="eu" [ml]="af" [tg]="af" [pk]="as" [fi]="eu" [bz]="na" [pl]="eu" [mk]="eu" [pm]="na" [fo]="eu" [st]="af" [ly]="af" [cd]="af" [cg]="af" [sv]="na" [tc]="na" [it]="eu" [fm]="oc" [mh]="oc" [by]="eu" [cf]="af" [xk]="eu" [cx]="as" [eu]="eu" )'
declare -A IPIP_COUNTRIES=()
declare -A IPIP_CONTINENTS=()
ipip_country() {
	if [ -z "${UNZIP_CMD}" ]
	then
		ipset_error "ipip_country" "Command 'unzip' is not installed."
		return 1
	fi

	cd "${RUN_DIR}" || return 1

	local ipset="ipip_country" limit="" hash="net" ipv="ipv4" \
		mins=$[24 * 60 * 1] history_mins=0 \
		url="https://cdn.ipip.net/17mon/country.zip" \
		info="[ipip.net](http://ipip.net)" \
		ret=

	ipset_shall_be_run "${ipset}"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	# download it
	download_manager "${ipset}" "${mins}" "${url}"
	ret=$?
	if [ $ret -eq ${DOWNLOAD_FAILED} -o $ret -eq ${DOWNLOAD_NOT_UPDATED} ]
		then
		[ ! -s "${BASE_DIR}/${ipset}.source" ] && return 1
		[ -d "${BASE_DIR}/${ipset}" -a ${REPROCESS_ALL} -eq 0 ] && return 1
	fi

	# create a temp dir
	[ -d "${ipset}.tmp" ] && $RM_CMD -rf "${ipset}.tmp"
	$MKDIR_CMD "${ipset}.tmp" || return 1
	cd "${ipset}.tmp" || return 1

	# extract it - in a subshell to do it in the tmp dir
	$UNZIP_CMD -x "${BASE_DIR}/${ipset}.source"
	local file="country.txt"

	if [ ! -f "${file}" ]
		then
		ipset_error "${ipset}" "failed to find file '${file}' in downloaded archive"
		return 1
	fi

	# create the final dir
	if [ ! -d "${BASE_DIR}/${ipset}" ]
	then
		$MKDIR_CMD "${BASE_DIR}/${ipset}" || return 1
	fi

	# find all the countries in the file
	ipset_info "${ipset}" "finding included countries..."
	$CAT_CMD "${file}" |\
		$CUT_CMD -f 2 |\
		$SORT_CMD -u |\
		trim >countries

	local x= code= name=
	while read x
	do
		code="${x,,}"
		name="${IPIP_COUNTRY_NAMES[${code}]}"
		[ -z "${name}" ] && name="${code}"

		ipset_verbose "${ipset}" "extracting country '${x}' (code='${code}' name='${name}')..."
		$CAT_CMD "${file}" 			|\
			$GREP_CMD -E "[[:space:]]+${x}[[:space:]]*$" |\
			$CUT_CMD -f 1 			|\
			${IPRANGE_CMD} 			|\
			filter_invalid4 >"ipip_country_${code}.source.tmp"

		if [ ! -z "${IPIP_COUNTRY_CONTINENTS[${code}]}" ]
			then
			[ ! -f "id_continent_${IPIP_COUNTRY_CONTINENTS[${code}]}.source.tmp.info" ] && printf "%s" "Continent ${IPIP_COUNTRY_CONTINENTS[${code}]}, with countries: " >"id_continent_${IPIP_COUNTRY_CONTINENTS[${code}]}.source.tmp.info"
			printf "%s" "${IPIP_COUNTRY_NAMES[${code}]} (${code^^}), " >>"ipip_continent_${IPIP_COUNTRY_CONTINENTS[${code}]}.source.tmp.info"
			$CAT_CMD "ipip_country_${code}.source.tmp" >>"ipip_continent_${IPIP_COUNTRY_CONTINENTS[${code}]}.source.tmp"
			IPIP_CONTINENTS[${IPIP_COUNTRY_CONTINENTS[${code}]}]="1"
		else
			ipset_warning "${ipset}" "I don't know the continent of country '${x}'' (code='${code}')."
		fi

		printf "%s" "${IPIP_COUNTRY_NAMES[${code}]} (${code^^})" >"ipip_country_${code}.source.tmp.info"
	done <countries

	ipset_info "${ipset}" "aggregating country and continent netsets..."
	local i info tmp
	for x in *.source.tmp
	do
		i=${x/.source.tmp/}
		tmp="${i}.source"
		local info2="$($CAT_CMD "${x}.info") -- ${info}"

		$MV_CMD "${x}" "${tmp}"
		$TOUCH_CMD -r "${BASE_DIR}/${ipset}.source" "${tmp}"

		finalize "${i}" \
			"${tmp}" \
			"${ipset}.source" \
			"${ipset}/${i}.netset" \
			"${mins}" \
			"${history_mins}" \
			"${ipv}" \
			"${limit}" \
			"${hash}" \
			"${url}" \
			"geolocation" \
			"${info2}" \
			"ipip.net" \
			"http://ipip.net" \
			service "geolocation"

		[ -f "${BASE_DIR}/${i}.setinfo" ] && $MV_CMD -f "${BASE_DIR}/${i}.setinfo" "${BASE_DIR}/${ipset}/${i}.setinfo"

	done

	# remove the temporary dir
	cd "${RUN_DIR}"
	$RM_CMD -rf ${ipset}.tmp

	return 0
}

eSentire() {
	local base="https://raw.githubusercontent.com/eSentire/malfeed/master"

	cd "${RUN_DIR}" || return 1

	local ipset="esentire" limit="" hash="ip" ipv="ipv4" \
		mins=$[24 * 60 * 1] history_mins=0 \
		url="${base}/index.txt" \
		info="[eSentire](https://github.com/eSentire/malfeed)" \
		ret=

	ipset_shall_be_run "${ipset}"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	# download it
	download_manager "${ipset}" "${mins}" "${url}"
	ret=$?
	if [ $ret -eq ${DOWNLOAD_FAILED} -o $ret -eq ${DOWNLOAD_NOT_UPDATED} ]
		then
		[ ! -s "${BASE_DIR}/${ipset}.source" ] && return 1
		[ -d "${BASE_DIR}/${ipset}" -a ${REPROCESS_ALL} -eq 0 ] && return 1
	fi

	echo >"${RUN_DIR}/esentire.sh"
	$CAT_CMD "${BASE_DIR}/${ipset}.source" |\
		while IFS="," read file type description
		do
			name="$( echo "${file/_watch_ip.lst/}" | $TR_CMD -c "[a-zA-Z0-9\n]" "_")"
			
			$CAT_CMD >>"${RUN_DIR}/esentire.sh" <<EOF_ESENTIRE
update esentire_${name} "${mins}" 0 ipv4 ip \
	"${base}/${file}" \
	remove_comments \
	"malware" \
	"${description}" \
	"eSentire" "https://github.com/eSentire/malfeed"
EOF_ESENTIRE
		done

	source "${RUN_DIR}/esentire.sh"

	return 0
}



# -----------------------------------------------------------------------------
# Common source files for many ipsets

# make sure ipsets with common source files are linked to each other
# so that the source file will be downloaded only once from the maintainer
ipsets_with_common_source_file() {
	local real= x=

	# find the real file (the newest one, if many exist)
	for x in "${@}"
	do
		if [ -f "${x}.source" -a ! -h "${x}.source" ]
			then
			if [ -z "${real}" ]
				then
				real="${x}"
			elif [ "${x}.source" -nt "${real}.source" ]
				then
				real="${x}"
			fi
		fi
	done

	# nothing is present
	[ -z "${real}" ] && return 1

	# link the others to the chosen real one
	for x in "${@}"
	do
		[ "${x}" = "${real}" ] && continue

		if [ -f "${x}.source" -o -h "${x}.source" ]
			then
			$RM_CMD "${x}.source"
			$LN_CMD -s "${real}.source" "${x}.source"
		fi
	done

	return 0
}

# -----------------------------------------------------------------------------
# MERGE two or more ipsets

merge() {
	local 	to="${1}" ipv="${2}" filter="${3}" category="${4}" info="${5}" \
			maintainer="${6}" maintainer_url="${7}" \
			included=()
	shift 7

	if [ ! -f "${BASE_DIR}/${to}.source" ]
		then
		if [ ${ENABLE_ALL} -eq 1 ]
			then
			$TOUCH_CMD -t 0001010000 "${BASE_DIR}/${to}.source" || return 1
		else
			ipset_disabled "${to}"
			return 1
		fi
	fi

	cd "${BASE_DIR}"

	ipset_silent "${to}" "examining source ipsets:"
	local -a files=()
	local found_updated=0 max_date=0 date=
	for x in "${@}"
	do
		if [ ! -z "${IPSET_FILE[${x}]}" -a -f "${IPSET_FILE[${x}]}" ]
			then

			files=("${files[@]}" "${IPSET_FILE[${x}]}")
			included=("${included[@]}" "${x}")

			if [ "${IPSET_FILE[${x}]}" -nt "${to}.source" ]
				then
				found_updated=$[ found_updated + 1 ]

				# check if it is newer
				date=$($DATE_CMD -r "${IPSET_FILE[${x}]}" +%s)
				if [ ${date} -gt ${max_date} ]
					then
					max_date=${date}
				fi

				ipset_silent "${to}" " + ${x}"
			else
				ipset_silent "${to}" " - ${x}"
			fi
		else
			ipset_warning "${to}" "will be generated without '${x}' - enable '${x}' it to be included the next time"
		fi
	done

	if [ -z "${files[*]}" ]
		then
		ipset_error "${to}" "no files available to merge."
		cd "${RUN_DIR}"
		return 1
	fi

	if [ ${found_updated} -eq 0 ]
		then
		ipset_notupdated "${to}" "source files have not been updated."
		cd "${RUN_DIR}"
		return 1
	fi

	ipset_silent "${to}" "merging files..."

	$CAT_CMD "${files[@]}" >"${to}.source.tmp"
	[ $? -ne 0 ] && cd "${RUN_DIR}" && return 1

	$TOUCH_CMD --date=@${max_date} "${to}.source.tmp"
	[ $? -ne 0 ] && cd "${RUN_DIR}" && return 1

	$MV_CMD "${to}.source.tmp" "${to}.source"
	[ $? -ne 0 ] && cd "${RUN_DIR}" && return 1

	update "${to}" 1 0 "${ipv}" "${filter}" "" \
		"cat" \
		"${category}" \
		"${info} (includes: ${included[*]})" \
		"${maintainer}" "${maintainer_url}"

	cd "${RUN_DIR}"
}

echo >&2

# -----------------------------------------------------------------------------
# MaxMind

geolite2_country

geolite2_asn


# -----------------------------------------------------------------------------
# IPDeny.com

ipdeny_country


# -----------------------------------------------------------------------------
# IP2Location.com

ip2location_country


# -----------------------------------------------------------------------------
# ipip.net

ipip_country


# -----------------------------------------------------------------------------
# atlas.arbor.net

#atlas_parser() { ${EGREP_CMD} "^${IP4_MATCH}, \"" | ${CUT_CMD} -d ',' -f 1; }

delete_ipset atlas_attacks
delete_ipset atlas_attacks_2d
delete_ipset atlas_attacks_7d
delete_ipset atlas_attacks_30d
#update atlas_attacks $[24 * 60] "$[48*60] $[7*24*60] $[30*24*60]" ipv4 ip \
#	"https://atlas.arbor.net/summary/attacks.csv" \
#	atlas_parser \
#	"attacks" "[ATLAS Attacks](https://atlas.arbor.net/summary/attacks) - ATLAS uses lightweight honeypot sensors to detect and fingerprint the attacks launched by malicious sources on the Internet. In most cases the attacker is trying to take control of the target via a published exploit for a known vulnerability. A variety of exploit tools exist and are usually written specifically for each attack vector. Exploit attempts and attacks are most often launched from bots (hosts under an attacker's control), which will automatically try to exploit any possible host on the Internet. Attack origins are usually not spoofed, although the source host may be compromised or infected with malware." \
#	"Arbor Networks" "https://atlas.arbor.net/"

delete_ipset atlas_botnets
delete_ipset atlas_botnets_2d
delete_ipset atlas_botnets_7d
delete_ipset atlas_botnets_30d
#update atlas_botnets $[24 * 60] "$[48*60] $[7*24*60] $[30*24*60]" ipv4 ip \
#	"https://atlas.arbor.net/summary/botnets.csv" \
#	atlas_parser \
#	"attacks" "[ATLAS Botnets](https://atlas.arbor.net/summary/botnets) - Botnets are collections of compromised hosts that attackers remotely control for their own nefarious purposes. Once installed and running, a malicious bot will attempt to connect to a remote server to receive instructions on what actions to take. The most common command and control (C&C) protocol used for this is Internet Relay Chat (IRC). While a legitimate protocol for online chat, IRC is often used by attackers due to the relative simplicity of the protocol along with the ready availability of bot software written to use it. After connecting, a bot-controlled host can be controlled by an attacker and commanded to conduct malicious actions such as sending spam, scanning the Internet for other potentially controllable hosts, or launching DoS attacks. ATLAS maintains a real-time database of malicious botnet command and control servers that is continuously updated. This information comes from malware analysis, botnet infiltration, and other sources of data." \
#	"Arbor Networks" "https://atlas.arbor.net/"

delete_ipset atlas_fastflux
delete_ipset atlas_fastflux_2d
delete_ipset atlas_fastflux_7d
delete_ipset atlas_fastflux_30d
#update atlas_fastflux $[24 * 60] "$[48*60] $[7*24*60] $[30*24*60]" ipv4 ip \
#	"https://atlas.arbor.net/summary/fastflux.csv" \
#	atlas_parser \
#	"attacks" "[ATLAS Fastflux](https://atlas.arbor.net/summary/fastflux) - Fast flux hosting is a technique where the nodes in a botnet are used as the endpoints in a website hosting scheme. The DNS records change frequently, often every few minutes, to point to new bots. The actual nodes themselves simply proxy the request back to the central hosting location. This gives the botnet a robust hosting infrastructure. Many different kinds of botnets use fastflux DNS techniques, for malware hosting, for illegal content hosting, for phishing site hosting, and other such activities. These hosts are likely to be infected with some form of malware." \
#	"Arbor Networks" "https://atlas.arbor.net/"

delete_ipset atlas_phishing
delete_ipset atlas_phishing_2d
delete_ipset atlas_phishing_7d
delete_ipset atlas_phishing_30d
#update atlas_phishing $[24 * 60] "$[48*60] $[7*24*60] $[30*24*60]" ipv4 ip \
#	"https://atlas.arbor.net/summary/phishing.csv" \
#	atlas_parser \
#	"attacks" "[ATLAS Phishing](https://atlas.arbor.net/summary/fastflux) - Phishing servers host content that is designed to socially engineer unsuspecting users into surrendering private information used for identity theft. These servers are installed on compromised web servers or botnets, at times. Phishing Web sites mimic legitimate Web sites, often of a financial institution, in order to steal logins, passwords, and personal information. Attackers trick users into using the fake Web site by sending the intended victim an e-mail claiming to be a legitimate institution requesting the information for valid reasons, such as account verification. They may then use the stolen credentials to withdraw large amounts of money from the victim's account or commit other fraudulent acts. Most targeted brands are usually in the financial sector, including banks and online commerce sites." \
#	"Arbor Networks" "https://atlas.arbor.net/"

delete_ipset atlas_scans
delete_ipset atlas_scans_2d
delete_ipset atlas_scans_7d
delete_ipset atlas_scans_30d
#update atlas_scans $[24 * 60] "$[48*60] $[7*24*60] $[30*24*60]" ipv4 ip \
#	"https://atlas.arbor.net/summary/scans.csv" \
#	atlas_parser \
#	"attacks" "[ATLAS Scans](https://atlas.arbor.net/summary/scans) - Host scanning is a process whereby automated network sweeps are initiated in search of hosts running a particular service. This may be indicative of either legitimate host scanners (including network management systems and authorized vulnerability scanners) or an attacker (or automated malicious code, such as a worm) trying to enumerate potential hosts for subsequent compromise. Scans are often the prelude to an attack, and services scanned by attackers usually indicate known vulnerabilities for those services. Types of port scans include connect() scans, SYN scans, stealth scans, bounce scans, XMAS and Null scans. All reveal to the attacker which services on what hosts are listening for connections. Scans may be launched from compromised hosts, and their sources may be forged." \
#	"Arbor Networks" "https://atlas.arbor.net/"


# -----------------------------------------------------------------------------
# www.openbl.org
# Unfortunately, openbl does not exist any more.
#
delete_ipset openbl
#update openbl $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) default blacklist (currently it is the same with 90 days). OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications" \
#	"OpenBL.org" "http://www.openbl.org/" \
#	dont_enable_with_all
#
delete_ipset openbl_1d
#update openbl_1d $[1*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_1days.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last 24 hours IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
delete_ipset openbl_7d
#update openbl_7d $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_7days.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last 7 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
delete_ipset openbl_30d
#update openbl_30d $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_30days.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last 30 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
delete_ipset openbl_60d
#update openbl_60d $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_60days.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last 60 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
delete_ipset openbl_90d
#update openbl_90d $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_90days.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last 90 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
delete_ipset openbl_180d
#update openbl_180d $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_180days.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last 180 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
delete_ipset openbl_360d
#update openbl_360d $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_360days.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last 360 days IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
delete_ipset openbl_all
#update openbl_all $[4*60] 0 ipv4 ip \
#	"http://www.openbl.org/lists/base_all.txt" \
#	remove_comments \
#	"attacks" \
#	"[OpenBL.org](http://www.openbl.org/) last all IPs.  OpenBL.org is detecting, logging and reporting various types of internet abuse. Currently they monitor ports 21 (FTP), 22 (SSH), 23 (TELNET), 25 (SMTP), 110 (POP3), 143 (IMAP), 587 (Submission), 993 (IMAPS) and 995 (POP3S) for bruteforce login attacks as well as scans on ports 80 (HTTP) and 443 (HTTPS) for vulnerable installations of phpMyAdmin and other web applications." \
#	"OpenBL.org" "http://www.openbl.org/"
#
#
# -----------------------------------------------------------------------------
# www.dshield.org
# https://www.dshield.org/xml.html

# Top 20 attackers (networks) by www.dshield.org
update dshield 10 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 both \
	"http://feeds.dshield.org/block.txt" \
	dshield_parser \
	"attacks" \
	"[DShield.org](https://dshield.org/) top 20 attacking class C (/24) subnets over the last three days" \
	"DShield.org" "https://dshield.org/"

update dshield_top_1000 60 0 ipv4 ip \
	"https://isc.sans.edu/api/sources/attacks/1000/" \
	parse_dshield_api \
	"attacks" \
	"[DShield.org](https://dshield.org/) top 1000 attacking hosts in the last 30 days" \
	"DShield.org" "https://dshield.org/"

# -----------------------------------------------------------------------------
# TOR lists
# TOR is not necessary hostile, you may need this just for sensitive services.

# https://www.dan.me.uk/tornodes
# This contains a full TOR nodelist (no more than 30 minutes old).
# The page has download limit that does not allow download in less than 30 min.
update dm_tor 30 0 ipv4 ip \
	"https://www.dan.me.uk/torlist/" \
	remove_comments \
	"anonymizers" \
	"[dan.me.uk](https://www.dan.me.uk) dynamic list of TOR nodes" \
	"dan.me.uk" "https://www.dan.me.uk/"

update et_tor $[12*60] 0 ipv4 ip \
	"http://rules.emergingthreats.net/blockrules/emerging-tor.rules" \
	snort_alert_rules_to_ipv4 \
	"anonymizers" \
	"[EmergingThreats.net TOR list](http://doc.emergingthreats.net/bin/view/Main/TorRules) of TOR network IPs" \
	"Emerging Threats" "http://www.emergingthreats.net/"

update bm_tor 30 0 ipv4 ip \
	"https://torstatus.blutmagie.de/ip_list_all.php/Tor_ip_list_ALL.csv" \
	remove_comments \
	"anonymizers" \
	"[torstatus.blutmagie.de](https://torstatus.blutmagie.de) list of all TOR network servers" \
	"torstatus.blutmagie.de" "https://torstatus.blutmagie.de/"

torproject_exits() { $GREP_CMD "^ExitAddress " | $CUT_CMD -d ' ' -f 2; }
update tor_exits 5 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"https://check.torproject.org/exit-addresses" \
	torproject_exits \
	"anonymizers" \
	"[TorProject.org](https://www.torproject.org) list of all current TOR exit points (TorDNSEL)" \
	"TorProject.org" "https://www.torproject.org/"


# -----------------------------------------------------------------------------
# Darklist.de

update darklist_de $[24 * 60] 0 ipv4 both \
	"http://www.darklist.de/raw.php" \
	remove_comments \
	"attacks" \
	"[darklist.de](http://www.darklist.de/) ssh fail2ban reporting" \
	"darklist.de" "http://www.darklist.de/" \
	intended_use "inbound ssh blacklist" \
	protection "inbound" \
	services "ssh"


# -----------------------------------------------------------------------------
# botvrij.eu

update botvrij_dst $[24 * 60] 0 ipv4 ip \
	"http://www.botvrij.eu/data/ioclist.ip-dst.raw" \
	remove_comments \
	"attacks" \
	"[botvrij.eu](http://www.botvrij.eu/) Indicators of Compromise (IOCS) about malicious destination IPs, gathered via open source information feeds (blog pages and PDF documents) and then consolidated into different datasets. To ensure the quality of the data all entries older than approx. 6 months are removed." \
	"botvrij.eu" "http://www.botvrij.eu/" \
	can_be_empty

update botvrij_src $[24 * 60] 0 ipv4 ip \
	"http://www.botvrij.eu/data/ioclist.ip-src.raw" \
	remove_comments \
	"attacks" \
	"[botvrij.eu](http://www.botvrij.eu/) Indicators of Compromise (IOCS) about malicious source IPs, gathered via open source information feeds (blog pages and PDF documents) and then consolidated into different datasets. To ensure the quality of the data all entries older than approx. 6 months are removed." \
	"botvrij.eu" "http://www.botvrij.eu/" \
	can_be_empty

# -----------------------------------------------------------------------------
# cruzit.com

update cruzit_web_attacks $[12 * 60] 0 ipv4 ip \
	"http://www.cruzit.com/xwbl2txt.php" \
	$CAT_CMD \
	"attacks" \
	"[CruzIt.com](http://www.cruzit.com/wbl.php) IPs of compromised machines scanning for vulnerabilities and DDOS attacks" \
	"CruzIt.com" "http://www.cruzit.com/wbl.php"


# -----------------------------------------------------------------------------
# pgl.yoyo.org

update yoyo_adservers $[12 * 60] 0 ipv4 ip \
	"http://pgl.yoyo.org/adservers/iplist.php?ipformat=plain&showintro=0&mimetype=plaintext" \
	$CAT_CMD \
	"organizations" \
	"[Yoyo.org](http://pgl.yoyo.org/adservers/) IPs of ad servers" \
	"Yoyo.org" "http://pgl.yoyo.org/adservers/" \
	no_if_modified_since


# -----------------------------------------------------------------------------
# EmergingThreats

# http://doc.emergingthreats.net/bin/view/Main/CompromisedHost
# Includes: openbl, bruteforceblocker and sidreporter
update et_compromised $[12*60] 0 ipv4 ip \
	"http://rules.emergingthreats.net/blockrules/compromised-ips.txt" \
	remove_comments \
	"attacks" \
	"[EmergingThreats.net compromised hosts](http://doc.emergingthreats.net/bin/view/Main/CompromisedHost)" \
	"Emerging Threats" "http://www.emergingthreats.net/"

# Command & Control servers by shadowserver.org
update et_botcc $[12*60] 0 ipv4 ip \
	"http://rules.emergingthreats.net/fwrules/emerging-PIX-CC.rules" \
	pix_deny_rules_to_ipv4 \
	"reputation" \
	"[EmergingThreats.net Command and Control IPs](http://doc.emergingthreats.net/bin/view/Main/BotCC) These IPs are updates every 24 hours and should be considered VERY highly reliable indications that a host is communicating with a known and active Bot or Malware command and control server - (although they say this includes abuse.ch trackers, it does not - check its overlaps)" \
	"Emerging Threats" "http://www.emergingthreats.net/"

# This appears to be the SPAMHAUS DROP list
update et_spamhaus $[12*60] 0 ipv4 both \
	"http://rules.emergingthreats.net/fwrules/emerging-PIX-DROP.rules" \
	pix_deny_rules_to_ipv4 \
	"attacks" \
	"[EmergingThreats.net](http://www.emergingthreats.net/) spamhaus blocklist" \
	"Emerging Threats" "http://www.emergingthreats.net/"

# Top 20 attackers by www.dshield.org
# disabled - have direct feed above
update et_dshield $[12*60] 0 ipv4 both \
	"http://rules.emergingthreats.net/fwrules/emerging-PIX-DSHIELD.rules" \
	pix_deny_rules_to_ipv4 \
	"attacks" \
	"[EmergingThreats.net](http://www.emergingthreats.net/) dshield blocklist" \
	"Emerging Threats" "http://www.emergingthreats.net/"

# includes spamhaus and dshield
update et_block $[12*60] 0 ipv4 both \
	"http://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt" \
	remove_comments \
	"attacks" \
	"[EmergingThreats.net](http://www.emergingthreats.net/) default blacklist (at the time of writing includes spamhaus DROP, dshield and abuse.ch trackers, which are available separately too - prefer to use the direct ipsets instead of this, they seem to lag a bit in updates)" \
	"Emerging Threats" "http://www.emergingthreats.net/"


# -----------------------------------------------------------------------------
# Spamhaus
# http://www.spamhaus.org

# http://www.spamhaus.org/drop/
# These guys say that this list should be dropped at tier-1 ISPs globally!
update spamhaus_drop $[12*60] 0 ipv4 both \
	"http://www.spamhaus.org/drop/drop.txt" \
	remove_comments_semi_colon \
	"reputation" \
	"[Spamhaus.org](http://www.spamhaus.org) DROP list (according to their site this list should be dropped at tier-1 ISPs globally)" \
	"Spamhaus.org" "http://www.spamhaus.org/"

# extended DROP (EDROP) list.
# Should be used together with their DROP list.
update spamhaus_edrop $[12*60] 0 ipv4 both \
	"http://www.spamhaus.org/drop/edrop.txt" \
	remove_comments_semi_colon \
	"reputation" \
	"[Spamhaus.org](http://www.spamhaus.org) EDROP (extended matches that should be used with DROP)" \
	"Spamhaus.org" "http://www.spamhaus.org/"


# -----------------------------------------------------------------------------
# blocklist.de
# http://www.blocklist.de/en/export.html

# All IP addresses that have attacked one of their servers in the
# last 48 hours. Updated every 30 minutes.
# They also have lists of service specific attacks (ssh, apache, sip, etc).
update blocklist_de 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/all.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) IPs that have been detected by fail2ban in the last 48 hours" \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_ssh 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/ssh.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IP addresses which have been reported within the last 48 hours as having run attacks on the service SSH." \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_mail 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/mail.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IP addresses which have been reported within the last 48 hours as having run attacks on the service Mail, Postfix." \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_apache 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/apache.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IP addresses which have been reported within the last 48 hours as having run attacks on the service Apache, Apache-DDOS, RFI-Attacks." \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_imap 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/imap.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IP addresses which have been reported within the last 48 hours for attacks on the Service imap, sasl, pop3, etc." \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_ftp 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/ftp.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IP addresses which have been reported within the last 48 hours for attacks on the Service FTP." \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_sip 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/sip.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IP addresses that tried to login in a SIP, VOIP or Asterisk Server and are included in the IPs list from infiltrated.net" \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_bots 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/bots.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IP addresses which have been reported within the last 48 hours as having run attacks on the RFI-Attacks, REG-Bots, IRC-Bots or BadBots (BadBots = it has posted a Spam-Comment on a open Forum or Wiki)." \
	"Blocklist.de" "https://www.blocklist.de/"

update blocklist_de_strongips 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/strongips.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IPs which are older then 2 month and have more then 5.000 attacks." \
	"Blocklist.de" "https://www.blocklist.de/"

# it seems this is not active any more
delete_ipset blocklist_de_ircbot
#update blocklist_de_ircbot 15 0 ipv4 ip \
#	"http://lists.blocklist.de/lists/ircbot.txt" \
#	remove_comments \
#	"attacks" \
#	"[Blocklist.de](https://www.blocklist.de/) (no information supplied)" \
#	"Blocklist.de" "https://www.blocklist.de/" \
#	dont_enable_with_all

update blocklist_de_bruteforce 15 0 ipv4 ip \
	"http://lists.blocklist.de/lists/bruteforcelogin.txt" \
	remove_comments \
	"attacks" \
	"[Blocklist.de](https://www.blocklist.de/) All IPs which attacks Joomla, Wordpress and other Web-Logins with Brute-Force Logins." \
	"Blocklist.de" "https://www.blocklist.de/"


# -----------------------------------------------------------------------------
# Zeus trojan
# https://zeustracker.abuse.ch/blocklist.php
# by abuse.ch

# This blocklists only includes IPv4 addresses that are used by the ZeuS trojan.
update zeus_badips 30 0 ipv4 ip \
	"https://zeustracker.abuse.ch/blocklist.php?download=badips" \
	remove_comments \
	"malware" \
	"[Abuse.ch Zeus tracker](https://zeustracker.abuse.ch) badips includes IPv4 addresses that are used by the ZeuS trojan. It is the recommened blocklist if you want to block only ZeuS IPs. It excludes IP addresses that ZeuS Tracker believes to be hijacked (level 2) or belong to a free web hosting provider (level 3). Hence the false postive rate should be much lower compared to the standard ZeuS IP blocklist." \
	"Abuse.ch" "https://zeustracker.abuse.ch/" \
	can_be_empty

# This blocklist contains the same data as the ZeuS IP blocklist (BadIPs)
# but with the slight difference that it doesn't exclude hijacked websites
# (level 2) and free web hosting providers (level 3).
update zeus 30 0 ipv4 ip \
	"https://zeustracker.abuse.ch/blocklist.php?download=ipblocklist" \
	remove_comments \
	"malware" \
	"[Abuse.ch Zeus tracker](https://zeustracker.abuse.ch) standard, contains the same data as the ZeuS IP blocklist (zeus_badips) but with the slight difference that it doesn't exclude hijacked websites (level 2) and free web hosting providers (level 3). This means that this blocklist contains all IPv4 addresses associated with ZeuS C&Cs which are currently being tracked by ZeuS Tracker. Hence this blocklist will likely cause some false positives." \
	"Abuse.ch" "https://zeustracker.abuse.ch/" \
	can_be_empty


# -----------------------------------------------------------------------------
# Palevo worm
# https://palevotracker.abuse.ch/blocklists.php
# by abuse.ch
# DISCONTINUED
# includes IP addresses which are being used as botnet C&C for the Palevo crimeware
delete_ipset palevo
#update palevo 30 0 ipv4 ip \
#	"https://palevotracker.abuse.ch/blocklists.php?download=ipblocklist" \
#	remove_comments \
#	"malware" \
#	"[Abuse.ch Palevo tracker](https://palevotracker.abuse.ch) worm includes IPs which are being used as botnet C&C for the Palevo crimeware" \
#	"Abuse.ch" "https://palevotracker.abuse.ch/" \
#	can_be_empty


# -----------------------------------------------------------------------------
# Feodo trojan
# https://feodotracker.abuse.ch/blocklist/
# by abuse.ch

# Feodo (also known as Cridex or Bugat) is a Trojan used to commit ebanking fraud
# and steal sensitive information from the victims computer, such as credit card
# details or credentials.
update feodo 30 0 ipv4 ip \
	"https://feodotracker.abuse.ch/blocklist/?download=ipblocklist" \
	remove_comments \
	"malware" \
	"[Abuse.ch Feodo tracker](https://feodotracker.abuse.ch) trojan includes IPs which are being used by Feodo (also known as Cridex or Bugat) which commits ebanking fraud" \
	"Abuse.ch" "https://feodotracker.abuse.ch/" \
	can_be_empty

update feodo_badips 30 0 ipv4 ip \
	"https://feodotracker.abuse.ch/blocklist/?download=badips" \
	remove_comments \
	"malware" \
	"[Abuse.ch Feodo tracker BadIPs](https://feodotracker.abuse.ch) The Feodo Tracker Feodo BadIP Blocklist only contains IP addresses (IPv4) used as C&C communication channel by the Feodo Trojan version B. These IP addresses are usually servers rented by cybercriminals directly and used for the exclusive purpose of hosting a Feodo C&C server. Hence you should expect no legit traffic to those IP addresses. The site highly recommends you to block/drop any traffic towards any Feodo C&C using the Feodo BadIP Blocklist. Please consider that this blocklist only contains IP addresses used by version B of the Feodo Trojan. C&C communication channels used by version A, version C and version D are not covered by this blocklist." \
	"Abuse.ch" "https://feodotracker.abuse.ch/" \
	can_be_empty

# -----------------------------------------------------------------------------
# SSLBL
# https://sslbl.abuse.ch/
# by abuse.ch

# IPs with "bad" SSL certificates identified by abuse.ch to be associated with malware or botnet activities
update sslbl 30 0 ipv4 ip \
	"https://sslbl.abuse.ch/blacklist/sslipblacklist.csv" \
	csv_comma_first_column \
	"malware" \
	"[Abuse.ch SSL Blacklist](https://sslbl.abuse.ch/) bad SSL traffic related to malware or botnet activities" \
	"Abuse.ch" "https://sslbl.abuse.ch/" \
	can_be_empty

# The aggressive version of the SSL IP Blacklist contains all IPs that SSLBL ever detected being associated with a malicious SSL certificate. Since IP addresses can be reused (e.g. when the customer changes), this blacklist may cause false positives. Hence I highly recommend you to use the standard version instead of the aggressive one.
update sslbl_aggressive 30 0 ipv4 ip \
	"https://sslbl.abuse.ch/blacklist/sslipblacklist_aggressive.csv" \
	csv_comma_first_column \
	"malware" \
	"[Abuse.ch SSL Blacklist](https://sslbl.abuse.ch/) The aggressive version of the SSL IP Blacklist contains all IPs that SSLBL ever detected being associated with a malicious SSL certificate. Since IP addresses can be reused (e.g. when the customer changes), this blacklist may cause false positives. Hence I highly recommend you to use the standard version instead of the aggressive one." \
	"Abuse.ch" "https://sslbl.abuse.ch/" \
	can_be_empty


# -----------------------------------------------------------------------------
# ransomwaretracker.abuse.ch
# by abuse.ch

parse_ransomwaretracker_feed() {
	$SED_CMD -e 's/^[[:space:]]*#.*//g' \
		-e 's/"\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)"/\8/g' \
		-e 's/|/\n/g'
}

parse_ransomwaretracker_online() {
  $SED_CMD -n -e 's/^"\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)","\(online\)","\(.*\)","\(.*\)","\(.*\)","\(.*\)"$/\8/p' | \
  	$SED_CMD -e '/^[[:space:]]*$/d' -e 's/|/\n/g'
}

update ransomware_feed 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/feeds/csv/" \
	parse_ransomwaretracker_feed \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. The IPs in this list have been extracted from the tracker data feed." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty

if [ -f "${BASE_DIR}/ransomware_feed.source" -a -f "${BASE_DIR}/ransomware_online.source" ]
	then
	# copy ransomware_feed.source
	ransomware_online_downloader="copyfile"
	ransomware_online_downloader_options="${BASE_DIR}/ransomware_feed.source"
else
	# ransomware_feed is not enabled
	# ransomware_online is standalone
	ransomware_online_downloader="geturl"
	ransomware_online_downloader_options=""
fi

update ransomware_online 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/feeds/csv/" \
	parse_ransomwaretracker_online \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. The IPs in this list have been extracted from the tracker data feed, filtering only online IPs." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	downloader "${ransomware_online_downloader}" \
	downloader_options "${ransomware_online_downloader_options}" \
	can_be_empty

update ransomware_rw 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/downloads/RW_IPBL.txt" \
	remove_comments \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. This list includes TC_PS_IPBL, LY_C2_IPBL, TL_C2_IPBL, TL_PS_IPBL and it is the recommended blocklist. It might not catch everything, but the false positive rate should be low. However, false positives are possible, especially with regards to RW_IPBL. IP addresses associated with Ransomware Payment Sites (*_PS_IPBL) or Locky botnet C&Cs (LY_C2_IPBL) stay listed on RW_IPBL for a time of 30 days after the last appearance. This means that an IP address stays listed on RW_IPBL even after the threat has been eliminated (e.g. the VPS / server has been suspended by the hosting provider) for another 30 days." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty

update ransomware_cryptowall_ps 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/downloads/CW_PS_IPBL.txt" \
	remove_comments \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. This list is CW_PS_IPBL: CryptoWall Ransomware Payment Sites IP blocklist." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty

update ransomware_teslacrypt_ps 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/downloads/TC_PS_IPBL.txt" \
	remove_comments \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. This list is TC_PS_IPBL: TeslaCrypt Ransomware Payment Sites IP blocklist." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty

update ransomware_locky_c2 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/downloads/LY_C2_IPBL.txt" \
	remove_comments \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. This list is LY_C2_IPBL: Locky Ransomware C2 URL blocklist." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty

update ransomware_locky_ps 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/downloads/LY_PS_IPBL.txt" \
	remove_comments \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. This list is LY_PS_IPBL: Locky Ransomware Payment Sites IP blocklist." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty

update ransomware_torrentlocker_ps 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/downloads/TL_PS_IPBL.txt" \
	remove_comments \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. This list is TL_PS_IPBL: TorrentLocker Ransomware Payment Sites IP blocklist." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty

update ransomware_torrentlocker_c2 5 0 ipv4 ip \
	"https://ransomwaretracker.abuse.ch/downloads/TL_C2_IPBL.txt" \
	remove_comments \
	"malware" \
	"[Abuse.ch Ransomware Tracker](https://ransomwaretracker.abuse.ch) Ransomware Tracker tracks and monitors the status of domain names, IP addresses and URLs that are associated with Ransomware, such as Botnet C&C servers, distribution sites and payment sites. By using data provided by Ransomware Tracker, hosting- and internet service provider (ISPs), as well as national CERTs/CSIRTs, law enforcement agencies (LEA) and security researchers can receive an overview on infrastructure used by Ransomware and whether these are actively being used by miscreants to commit fraud. This list is TL_C2_IPBL: TorrentLocker Ransomware C2 IP blocklist." \
	"Abuse.ch" "https://ransomwaretracker.abuse.ch" \
	can_be_empty


# -----------------------------------------------------------------------------
# infiltrated.net
# http://www.infiltrated.net/blacklisted

# it appears to be permanently down
delete_ipset infiltrated
#update infiltrated $[12*60] 0 ipv4 ip \
#	"http://www.infiltrated.net/blacklisted" \
#	remove_comments \
#	"attacks" \
#	"[infiltrated.net](http://www.infiltrated.net) (this list seems to be updated frequently, but we found no information about it)" \
#	"infiltrated.net" "http://www.infiltrated.net/"

# -----------------------------------------------------------------------------
# malc0de
# http://malc0de.com

# updated daily and populated with the last 30 days of malicious IP addresses.
update malc0de $[24*60] 0 ipv4 ip \
	"http://malc0de.com/bl/IP_Blacklist.txt" \
	remove_comments \
	"malware" \
	"[Malc0de.com](http://malc0de.com) malicious IPs of the last 30 days" \
	"malc0de.com" "http://malc0de.com/"

# -----------------------------------------------------------------------------
# Threat Crowd
# http://threatcrowd.blogspot.gr/2016/02/crowdsourced-feeds-from-threatcrowd.html

update threatcrowd 60 0 ipv4 ip \
	"https://www.threatcrowd.org/feeds/ips.txt" \
	remove_comments \
	"malware" \
	"[Crowdsourced IP feed from ThreatCrowd](http://threatcrowd.blogspot.gr/2016/02/crowdsourced-feeds-from-threatcrowd.html). These feeds are not a substitute for the scale of auto-extracted command and control domains or the quality of some commercially provided feeds. But crowd-sourcing does go some way towards the quick sharing of threat intelligence between the community." \
	"Threat Crowd" "https://www.threatcrowd.org/"


# -----------------------------------------------------------------------------
# ASPROX
# http://atrack.h3x.eu/

parse_asprox() { $SED_CMD -e "s|<div class=code>|\n|g" -e "s|</div>|\n|g" | trim | $EGREP_CMD "^${IP4_MATCH}$"; }

# updated daily and populated with the last 30 days of malicious IP addresses.
update asprox_c2 $[24*60] 0 ipv4 ip \
	"http://atrack.h3x.eu/c2" \
	parse_asprox \
	"malware" \
	"[h3x.eu](http://atrack.h3x.eu/) ASPROX Tracker - Asprox C&C Sites" \
	"h3x.eu" "http://atrack.h3x.eu/" \
	can_be_empty


# -----------------------------------------------------------------------------
# Stop Forum Spam
# http://www.stopforumspam.com/downloads/

# toxic
update stopforumspam_toxic $[24*60] 0 ipv4 both \
	"http://www.stopforumspam.com/downloads/toxic_ip_cidr.txt" \
	remove_comments \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) Networks that have large amounts of spambots and are flagged as toxic. Toxic IP ranges are infrequently changed." \
	"StopForumSpam.com" "http://www.stopforumspam.com/"

# banned
update stopforumspam $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/bannedips.zip" \
	unzip_and_split_csv \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) Banned IPs used by forum spammers" \
	"StopForumSpam.com" "http://www.stopforumspam.com/"

# hourly update with IPs from the last 24 hours
update stopforumspam_1d 60 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_1.zip" \
	unzip_and_extract \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers in the last 24 hours" \
	"StopForumSpam.com" "http://www.stopforumspam.com/"

# daily update with IPs from the last 7 days
update stopforumspam_7d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_7.zip" \
	unzip_and_extract \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 7 days)" \
	"StopForumSpam.com" "http://www.stopforumspam.com/"

# daily update with IPs from the last 30 days
update stopforumspam_30d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_30.zip" \
	unzip_and_extract \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 30 days)" \
	"StopForumSpam.com" "http://www.stopforumspam.com/"

# daily update with IPs from the last 90 days
# you will have to add maxelem to ipset to fit it
update stopforumspam_90d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_90.zip" \
	unzip_and_extract \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 90 days)" \
	"StopForumSpam.com" "http://www.stopforumspam.com/"

# daily update with IPs from the last 180 days
# you will have to add maxelem to ipset to fit it
update stopforumspam_180d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_180.zip" \
	unzip_and_extract \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 180 days)" \
	"StopForumSpam.com" "http://www.stopforumspam.com/"

# daily update with IPs from the last 365 days
# you will have to add maxelem to ipset to fit it
update stopforumspam_365d $[24*60] 0 ipv4 ip \
	"http://www.stopforumspam.com/downloads/listed_ip_365.zip" \
	unzip_and_extract \
	"abuse" \
	"[StopForumSpam.com](http://www.stopforumspam.com) IPs used by forum spammers (last 365 days)" \
	"StopForumSpam.com" "http://www.stopforumspam.com/"


# -----------------------------------------------------------------------------
# sblam.com

update sblam $[24*60] 0 ipv4 ip \
	"http://sblam.com/blacklist.txt" \
	remove_comments \
	"abuse" \
	"[sblam.com](http://sblam.com) IPs used by web form spammers, during the last month" \
	"sblam.com" "http://sblam.com/"


# -----------------------------------------------------------------------------
# myip.ms

update myip $[24*60] 0 ipv4 ip \
	"http://www.myip.ms/files/blacklist/csf/latest_blacklist.txt" \
	remove_comments \
	"abuse" \
	"[myip.ms](http://www.myip.ms/info/about) IPs identified as web bots in the last 10 days, using several sites that require human action" \
	"MyIP.ms" "http://myip.ms/"


# -----------------------------------------------------------------------------
# Bogons
# Bogons are IP addresses that should not be routed because they are not
# allocated, or they are allocated for private use.
# IMPORTANT: THESE LISTS INCLUDE ${PRIVATE_IPS}
#            always specify an 'inface' when blacklisting in FireHOL

# http://www.team-cymru.org/bogon-reference.html
# private and reserved addresses defined by RFC 1918, RFC 5735, and RFC 6598
# and netblocks that have not been allocated to a regional internet registry
# (RIR) by the Internet Assigned Numbers Authority.
update bogons $[24*60] 0 ipv4 both \
	"http://www.team-cymru.org/Services/Bogons/bogon-bn-agg.txt" \
	remove_comments \
	"unroutable" \
	"[Team-Cymru.org](http://www.team-cymru.org) private and reserved addresses defined by RFC 1918, RFC 5735, and RFC 6598 and netblocks that have not been allocated to a regional internet registry" \
	"Team Cymru" "http://www.team-cymru.org/" \
	dont_redistribute


# http://www.team-cymru.org/bogon-reference.html
# Fullbogons are a larger set which also includes IP space that has been
# allocated to an RIR, but not assigned by that RIR to an actual ISP or other
# end-user.
update fullbogons $[24*60] 0 ipv4 both \
	"http://www.team-cymru.org/Services/Bogons/fullbogons-ipv4.txt" \
	remove_comments \
	"unroutable" \
	"[Team-Cymru.org](http://www.team-cymru.org) IP space that has been allocated to an RIR, but not assigned by that RIR to an actual ISP or other end-user" \
	"Team Cymru" "http://www.team-cymru.org/" \
	dont_redistribute

#update fullbogons6 $[24*60-10] ipv6 both \
#	"http://www.team-cymru.org/Services/Bogons/fullbogons-ipv6.txt" \
#	remove_comments \
#	"unroutable" \
#	"Team-Cymru.org provided" \
#	"Team Cymru" "http://www.team-cymru.org/" \
#	dont_redistribute

# -----------------------------------------------------------------------------
# CIDR Report.org

update cidr_report_bogons $[24*60] 0 ipv4 both \
	"http://www.cidr-report.org/bogons/freespace-prefix.txt" \
	remove_comments \
	"unroutable" \
	"Unallocated (Free) Address Space, generated on a daily basis using the IANA registry files, the Regional Internet Registry stats files and the Regional Internet Registry whois data." \
	"CIDR-Report.org" "http://www.cidr-report.org"


# -----------------------------------------------------------------------------
# Open Proxies from rosinstruments
# http://tools.rosinstrument.com/proxy/

update ri_web_proxies 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://tools.rosinstrument.com/proxy/l100.xml" \
	parse_rss_rosinstrument \
	"anonymizers" \
	"[rosinstrument.com](http://www.rosinstrument.com) open HTTP proxies (this list is composed using an RSS feed)" \
	"RosInstrument.com" "http://www.rosinstrument.com/"

update ri_connect_proxies 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://tools.rosinstrument.com/proxy/plab100.xml" \
	parse_rss_rosinstrument \
	"anonymizers" \
	"[rosinstrument.com](http://www.rosinstrument.com) open CONNECT proxies (this list is composed using an RSS feed)" \
	"RosInstrument.com" "http://www.rosinstrument.com/"


# -----------------------------------------------------------------------------
# Open Proxies from xroxy.com
# http://www.xroxy.com

update xroxy 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.xroxy.com/proxyrss.xml" \
	parse_rss_proxy \
	"anonymizers" \
	"[xroxy.com](http://www.xroxy.com) open proxies (this list is composed using an RSS feed)" \
	"Xroxy.com" "http://www.xroxy.com/"


# -----------------------------------------------------------------------------
# Free Proxy List

# http://www.sslproxies.org/
update sslproxies 10 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.sslproxies.org/" \
	extract_ipv4_from_any_file \
	"anonymizers" \
	"[SSLProxies.org](http://www.sslproxies.org/) open SSL proxies" \
	"Free Proxy List" "http://free-proxy-list.net/"

# http://www.socks-proxy.net/
update socks_proxy 10 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.socks-proxy.net/" \
	extract_ipv4_from_any_file \
	"anonymizers" \
	"[socks-proxy.net](http://www.socks-proxy.net/) open SOCKS proxies" \
	"Free Proxy List" "http://free-proxy-list.net/"

# -----------------------------------------------------------------------------
# Open Proxies from proxz.com
# http://www.proxz.com/

update proxz 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.proxz.com/proxylists.xml" \
	parse_rss_proxy \
	"anonymizers" \
	"[proxz.com](http://www.proxz.com) open proxies (this list is composed using an RSS feed)" \
	"ProxZ.com" "http://www.proxz.com/"


# -----------------------------------------------------------------------------
# Multiproxy.org
# http://multiproxy.org/txt_all/proxy.txt
# this seems abandoned
#
#parse_multiproxy() { remove_comments | $CUT_CMD -d ':' -f 1; }
delete_ipset multiproxy
#update multiproxy 60 0 ipv4 ip \
#	"http://multiproxy.org/txt_all/proxy.txt" \
#	parse_multiproxy \
#	"anonymizers" \
#	"Open proxies" \
#	"MultiProxy.org" "http://multiproxy.org/"


# -----------------------------------------------------------------------------
# Open Proxies from proxylists.net
# http://www.proxylists.net/proxylists.xml

update proxylists 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.proxylists.net/proxylists.xml" \
	parse_rss_proxy \
	"anonymizers" \
	"[proxylists.net](http://www.proxylists.net/) open proxies (this list is composed using an RSS feed)" \
	"ProxyLists.net" "http://www.proxylists.net/"


# -----------------------------------------------------------------------------
# Open Proxies from proxyspy.net
# http://spys.ru/en/

#parse_proxyspy() { remove_comments | $CUT_CMD -d ':' -f 1; }

delete_ipset proxyspy
#update proxyspy 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
#	"http://txt.proxyspy.net/proxy.txt" \
#	parse_proxyspy \
#	"anonymizers" \
#	"[ProxySpy](http://spys.ru/en/) open proxies (updated hourly)" \
#	"ProxySpy (spys.ru)" "http://spys.ru/en/"


# -----------------------------------------------------------------------------
# Open Proxies from proxyrss.com
# http://www.proxyrss.com/

update proxyrss $[4*60] "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.proxyrss.com/proxylists/all.gz" \
	gz_proxyrss \
	"anonymizers" \
	"[proxyrss.com](http://www.proxyrss.com) open proxies syndicated from multiple sources." \
	"ProxyRSS.com" "http://www.proxyrss.com/"


# -----------------------------------------------------------------------------
# Anonymous Proxies
# was: https://www.maxmind.com/en/anonymous-proxy-fraudulent-ip-address-list

update maxmind_proxy_fraud $[4*60] 0 ipv4 ip \
	"https://www.maxmind.com/en/high-risk-ip-sample-list" \
	parse_maxmind_proxy_fraud \
	"anonymizers" \
	"[MaxMind.com](https://www.maxmind.com/en/high-risk-ip-sample-list) sample list of high-risk IP addresses." \
	"MaxMind.com" "https://www.maxmind.com/en/high-risk-ip-sample-list"


# -----------------------------------------------------------------------------
# Project Honey Pot
# http://www.projecthoneypot.org/?rf=192670

update php_harvesters 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=h&rss=1" \
	parse_php_rss \
	"spam" \
	"[projecthoneypot.org](http://www.projecthoneypot.org/?rf=192670) harvesters (IPs that surf the internet looking for email addresses) (this list is composed using an RSS feed)" \
	"ProjectHoneypot.org" "http://www.projecthoneypot.org/"

update php_spammers 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=s&rss=1" \
	parse_php_rss \
	"spam" \
	"[projecthoneypot.org](http://www.projecthoneypot.org/?rf=192670) spam servers (IPs used by spammers to send messages) (this list is composed using an RSS feed)" \
	"ProjectHoneypot.org" "http://www.projecthoneypot.org/"

update php_bad 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=b&rss=1" \
	parse_php_rss \
	"spam" \
	"[projecthoneypot.org](http://www.projecthoneypot.org/?rf=192670) bad web hosts (this list is composed using an RSS feed)" \
	"ProjectHoneypot.org" "http://www.projecthoneypot.org/" \
	dont_enable_with_all

update php_commenters 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=c&rss=1" \
	parse_php_rss \
	"spam" \
	"[projecthoneypot.org](http://www.projecthoneypot.org/?rf=192670) comment spammers (this list is composed using an RSS feed)" \
	"ProjectHoneypot.org" "http://www.projecthoneypot.org/"

update php_dictionary 60 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.projecthoneypot.org/list_of_ips.php?t=d&rss=1" \
	parse_php_rss \
	"spam" \
	"[projecthoneypot.org](http://www.projecthoneypot.org/?rf=192670) directory attackers (this list is composed using an RSS feed)" \
	"ProjectHoneypot.org" "http://www.projecthoneypot.org/"


# -----------------------------------------------------------------------------
# Malware Domain List
# All IPs should be considered dangerous

update malwaredomainlist $[12*60] 0 ipv4 ip \
	"http://www.malwaredomainlist.com/hostslist/ip.txt" \
	remove_comments \
	"malware" \
	"[malwaredomainlist.com](http://www.malwaredomainlist.com) list of malware active ip addresses" \
	"MalwareDomainList.com" "http://www.malwaredomainlist.com/"


# -----------------------------------------------------------------------------
# blocklist.net.ua
# https://blocklist.net.ua

update blocklist_net_ua $[10] 0 ipv4 ip \
	"https://blocklist.net.ua/blocklist.csv" \
	remove_comments_semi_colon \
	"abuse" \
	"[blocklist.net.ua](https://blocklist.net.ua) The BlockList project was created to become protection against negative influence of the harmful and potentially dangerous events on the Internet. First of all this service will help internet and hosting providers to protect subscribers sites from being hacked. BlockList will help to stop receiving a large amount of spam from dubious SMTP relays or from attempts of brute force passwords to servers and network equipment." \
	"blocklist.net.ua" "https://blocklist.net.ua"


# -----------------------------------------------------------------------------
# Alien Vault
# Alienvault IP Reputation Database

# IMPORTANT: THIS IS A BIG LIST
# you will have to add maxelem to ipset to fit it
update alienvault_reputation $[6*60] 0 ipv4 ip \
	"https://reputation.alienvault.com/reputation.generic" \
	remove_comments \
	"reputation" \
	"[AlienVault.com](https://www.alienvault.com/) IP reputation database" \
	"Alien Vault" "https://www.alienvault.com/"


# -----------------------------------------------------------------------------
# Clean-MX

# Viruses
update cleanmx_viruses 30 0 ipv4 ip \
	"http://support.clean-mx.de/clean-mx/xmlviruses.php?response=alive&fields=ip" \
	parse_xml_clean_mx \
	"spam" \
	"[Clean-MX.de](http://support.clean-mx.de/clean-mx/viruses.php) IPs with viruses" \
	"Clean-MX.de" "http://support.clean-mx.de/clean-mx/viruses.php"


# Phishing
parse_cvs_clean_mx_phishing() { $SED_CMD -e 's/|/_/g' -e 's/","/|/g' | $CUT_CMD -d '|' -f 10; }
update cleanmx_phishing 30 0 ipv4 ip \
	"http://support.clean-mx.de/clean-mx/xmlphishing?response=alive&format=csv&domain=" \
	parse_cvs_clean_mx_phishing \
	"spam" \
	"[Clean-MX.de](http://support.clean-mx.de/) IPs sending phishing messages" \
	"Clean-MX.de" "http://support.clean-mx.de/"


# -----------------------------------------------------------------------------
# DynDNS

# Phishing
parse_cvs_dyndns_ponmocup() { $SED_CMD -e 's/|/_/g' -e 's/","/|/g' | $CUT_CMD -d '|' -f 2; }
update dyndns_ponmocup $[24 * 60] 0 ipv4 ip \
	"http://security-research.dyndns.org/pub/malware-feeds/ponmocup-infected-domains-shadowserver.csv" \
	parse_cvs_dyndns_ponmocup \
	"malware" \
	"[DynDNS.org](http://security-research.dyndns.org/pub/malware-feeds/) Ponmocup. The malware powering the botnet has been around since 2006 and it’s known under various names, including Ponmocup, Vundo, Virtumonde, Milicenso and Swisyn. It has been used for ad fraud, data theft and downloading additional threats to infected systems. Ponmocup is one of the largest currently active and, with nine consecutive years, also one of the longest running, but it is rarely noticed as the operators take care to keep it operating under the radar." \
	"DynDNS.org" "http://security-research.dyndns.org/pub/malware-feeds/"


# -----------------------------------------------------------------------------
# Turris

parse_turris_greylist() { $CUT_CMD -d ',' -f 1; }
update turris_greylist $[7 * 24 * 60] 0 ipv4 ip \
	"https://www.turris.cz/greylist-data/greylist-latest.csv" \
	parse_turris_greylist \
	"reputation" \
	"[Turris Greylist](https://www.turris.cz/en/greylist) IPs that are blocked on the firewalls of Turris routers. The data is processed and clasified every week and behaviour of IP addresses that accessed a larger number of Turris routers is evaluated. The result is a list of addresses that have tried to obtain information about services on the router or tried to gain access to them. We do not recommend to use these data as a list of addresses that should be blocked but it can be used for example in analysis of the traffic in other networks." \
	"Turris" "https://www.turris.cz/en/greylist"


# -----------------------------------------------------------------------------
# http://www.urlvir.com/

update urlvir $[24 * 60] 0 ipv4 ip \
	"http://www.urlvir.com/export-ip-addresses/" \
	remove_comments \
	"malware" \
	"[URLVir.com](http://www.urlvir.com/) Active Malicious IP Addresses Hosting Malware. URLVir is an online security service developed by NoVirusThanks Company Srl that automatically monitors changes of malicious URLs (executable files)." \
	"URLVir.com" "http://www.urlvir.com/"


# -----------------------------------------------------------------------------
# Taichung

update taichung $[24 * 60] 0 ipv4 ip \
	"https://www.tc.edu.tw/net/netflow/lkout/recent/30" \
	extract_ipv4_from_any_file \
	"attacks" \
	"[Taichung Education Center](https://www.tc.edu.tw/net/netflow/lkout/recent/30) Blocked IP Addresses (attacks and bots)." \
	"Taichung Education Center" "https://www.tc.edu.tw/net/netflow/lkout/recent/30"


# -----------------------------------------------------------------------------
# ImproWare
# http://antispam.imp.ch/

antispam_ips() { remove_comments | $CUT_CMD -d ' ' -f 2; }

update iw_spamlist 60 0 ipv4 ip \
	"http://antispam.imp.ch/spamlist" \
	antispam_ips \
	"spam" \
	"[ImproWare Antispam](http://antispam.imp.ch/) IPs sending spam, in the last 3 days" \
	"ImproWare Antispam" "http://antispam.imp.ch/" \
	can_be_empty

update iw_wormlist 60 0 ipv4 ip \
	"http://antispam.imp.ch/wormlist" \
	antispam_ips \
	"spam" \
	"[ImproWare Antispam](http://antispam.imp.ch/) IPs sending emails with viruses or worms, in the last 3 days" \
	"ImproWare Antispam" "http://antispam.imp.ch/" \
	can_be_empty


# -----------------------------------------------------------------------------
# CI Army
# http://ciarmy.com/

# The CI Army list is a subset of the CINS Active Threat Intelligence ruleset,
# and consists of IP addresses that meet two basic criteria:
# 1) The IP's recent Rogue Packet score factor is very poor, and
# 2) The InfoSec community has not yet identified the IP as malicious.
# We think this second factor is important: We don't want to waste peoples'
# time listing thousands of IPs that have already been placed on other reputation
# lists; our list is meant to supplement and enhance the InfoSec community's
# existing efforts by providing IPs that haven't been identified yet.
update ciarmy $[3*60] 0 ipv4 ip \
	"http://cinsscore.com/list/ci-badguys.txt" \
	remove_comments \
	"reputation" \
	"[CIArmy.com](http://ciarmy.com/) IPs with poor Rogue Packet score that have not yet been identified as malicious by the community" \
	"Collective Intelligence Network Security" "http://ciarmy.com/"


# -----------------------------------------------------------------------------
# Bruteforce Blocker
# http://danger.rulez.sk/projects/bruteforceblocker/

update bruteforceblocker $[3*60] 0 ipv4 ip \
	"http://danger.rulez.sk/projects/bruteforceblocker/blist.php" \
	remove_comments \
	"attacks" \
	"[danger.rulez.sk bruteforceblocker](http://danger.rulez.sk/index.php/bruteforceblocker/) (fail2ban alternative for SSH on OpenBSD). This is an automatically generated list from users reporting failed authentication attempts. An IP seems to be included if 3 or more users report it. Its retention pocily seems 30 days." \
	"danger.rulez.sk" "http://danger.rulez.sk/index.php/bruteforceblocker/"


# -----------------------------------------------------------------------------
# PacketMail
# https://www.packetmail.net/iprep.txt

parse_packetmail() { remove_comments | $CUT_CMD -d ';' -f 1; }

update packetmail $[4*60] 0 ipv4 ip \
	"https://www.packetmail.net/iprep.txt" \
	 parse_packetmail \
	"reputation" \
	"[PacketMail.net](https://www.packetmail.net/) IP addresses that have been detected performing TCP SYN to 206.82.85.196/30 to a non-listening service or daemon. No assertion is made, nor implied, that any of the below listed IP addresses are accurate, malicious, hostile, or engaged in nefarious acts. Use this list at your own risk." \
	"PacketMail.net" "https://www.packetmail.net/"

update packetmail_ramnode $[4*60] 0 ipv4 ip \
	"https://www.packetmail.net/iprep_ramnode.txt" \
	 parse_packetmail \
	"reputation" \
	"[PacketMail.net](https://www.packetmail.net/) IP addresses that have been detected performing TCP SYN to 81.4.103.251 to a non-listening service or daemon. No assertion is made, nor implied, that any of the below listed IP addresses are accurate, malicious, hostile, or engaged in nefarious acts. Use this list at your own risk." \
	"PacketMail.net" "https://www.packetmail.net/"

delete_ipset packetmail_carisirt
#update packetmail_carisirt $[4*60] 0 ipv4 ip \
#	"https://www.packetmail.net/iprep_CARISIRT.txt" \
#	 parse_packetmail \
#	"reputation" \
#	"[PacketMail.net](https://www.packetmail.net/) IP addresses that have been detected performing TCP SYN to 66.240.206.5 to a non-listening service or daemon. No assertion is made, nor implied, that any of the below listed IP addresses are accurate, malicious, hostile, or engaged in nefarious acts. Use this list at your own risk." \
#	"PacketMail.net" "https://www.packetmail.net/"

update packetmail_mail $[4*60] 0 ipv4 ip \
	"https://www.packetmail.net/iprep_mail.txt" \
	 parse_packetmail \
	"reputation" \
	"[PacketMail.net](https://www.packetmail.net/) IP addresses that have been detected performing behavior not in compliance with the requirements this system enforces for email acceptance. No assertion is made, nor implied, that any of the below listed IP addresses are accurate, malicious, hostile, or engaged in nefarious acts. Use this list at your own risk." \
	"PacketMail.net" "https://www.packetmail.net/"

parse_packetmail_emerging_ips() {
	$SED_CMD -e "s/#.*$//g" |\
		$GREP_CMD -v "^$" |\
		$CUT_CMD -d "	" -f 6
}

update packetmail_emerging_ips $[4*60] 0 ipv4 ip \
	"https://www.packetmail.net/iprep_emerging_ips.txt" \
	 parse_packetmail_emerging_ips \
	"reputation" \
	"[PacketMail.net](https://www.packetmail.net/) IP addresses that have been detected as potentially of interest based on the number of unique users of the packetmail IP Reputation system. No assertion is made, nor implied, that any of the below listed IP addresses are accurate, malicious, hostile, or engaged in nefarious acts. Use this list at your own risk." \
	"PacketMail.net" "https://www.packetmail.net/"


# -----------------------------------------------------------------------------
# Charles Haley
# http://charles.the-haleys.org/ssh_dico_attack_hdeny_format.php/hostsdeny.txt

haley_ssh() { $CUT_CMD -d ':' -f 2; }

update haley_ssh $[4*60] 0 ipv4 ip \
	"http://charles.the-haleys.org/ssh_dico_attack_hdeny_format.php/hostsdeny.txt" \
	haley_ssh \
	"attacks" \
	"[Charles Haley](http://charles.the-haleys.org) IPs launching SSH dictionary attacks." \
	"Charles Haley" "http://charles.the-haleys.org"


# -----------------------------------------------------------------------------
# Snort ipfilter
# http://labs.snort.org/feeds/ip-filter.blf

update snort_ipfilter $[12*60] 0 ipv4 ip \
	"http://labs.snort.org/feeds/ip-filter.blf" \
	remove_comments \
	"attacks" \
	"[labs.snort.org](https://labs.snort.org/) supplied IP blacklist (this list seems to be updated frequently, but we found no information about it)" \
	"Snort.org Labs" "https://labs.snort.org/"


# -----------------------------------------------------------------------------
# TalosIntel
# http://talosintel.com

update talosintel_ipfilter 15 0 ipv4 ip \
	"http://talosintel.com/feeds/ip-filter.blf" \
	remove_comments \
	"attacks" \
	"[TalosIntel.com](http://talosintel.com/additional-resources/) List of known malicious network threats" \
	"TalosIntel.com" "http://talosintel.com/"

# -----------------------------------------------------------------------------
# NiX Spam
# http://www.heise.de/ix/NiX-Spam-DNSBL-and-blacklist-for-download-499637.html

update nixspam 15 0 ipv4 ip \
	"http://www.dnsbl.manitu.net/download/nixspam-ip.dump.gz" \
	gz_second_word \
	"spam" \
	"[NiX Spam](http://www.heise.de/ix/NiX-Spam-DNSBL-and-blacklist-for-download-499637.html) IP addresses that sent spam in the last hour - automatically generated entries without distinguishing open proxies from relays, dialup gateways, and so on. All IPs are removed after 12 hours if there is no spam from there." \
	"NiX Spam" "http://www.heise.de/ix/NiX-Spam-DNSBL-and-blacklist-for-download-499637.html"


# -----------------------------------------------------------------------------
# VirBL
# http://virbl.bit.nl/
# DOES NOT EXIST ANYMORE
delete_ipset virbl
#update virbl 60 0 ipv4 ip \
#	"http://virbl.bit.nl/download/virbl.dnsbl.bit.nl.txt" \
#	remove_comments \
#	"spam" \
#	"[VirBL](http://virbl.bit.nl/) is a project of which the idea was born during the RIPE-48 meeting. The plan was to get reports of virus scanning mailservers, and put the IP-addresses that were reported to send viruses on a blacklist." \
#	"VirBL.bit.nl" "http://virbl.bit.nl/"


# -----------------------------------------------------------------------------
# AutoShun.org
# http://www.autoshun.org/

if [ ! -z "${AUTOSHUN_API_KEY}" ]
	then
	update shunlist $[4*60] 0 ipv4 ip \
		"https://www.autoshun.org/download/?api_key=${AUTOSHUN_API_KEY}&format=csv" \
		csv_comma_first_column \
		"attacks" \
		"[AutoShun.org](http://autoshun.org/) IPs identified as hostile by correlating logs from distributed snort installations running the autoshun plugin" \
		"AutoShun.org" "http://autoshun.org/" \
		license "Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International License" \
		dont_redistribute \
		dont_enable_with_all \
		no_if_modified_since
fi


# -----------------------------------------------------------------------------
# ip2proxy lite
# https://lite.ip2location.com/

ip2location_ip2proxy_px1lite() {
	$CAT_CMD >"${RUN_DIR}/ip2location_ip2proxy_px1lite.zip"
	$UNZIP_CMD -jpx "${RUN_DIR}/ip2location_ip2proxy_px1lite.zip" "IP2PROXY-LITE-PX1.CSV" |\
		$CUT_CMD -d ',' -f 1,2 |\
		$TR_CMD '",' ' -' |\
		$IPRANGE_CMD
}

if [ ! -z "${IP2LOCATION_API_KEY}" ]
	then
	update ip2proxy_px1lite $[24*60] 0 ipv4 both \
		"http://www.ip2location.com/download/?token=${IP2LOCATION_API_KEY}&file=PX1LITE" \
		ip2location_ip2proxy_px1lite \
		"anonymizers" \
		"[IP2Location.com](https://lite.ip2location.com/database/px1-ip-country) IP2Proxy LITE IP-COUNTRY Database contains IP addresses which are used as public proxies. The LITE edition is a free version of database that is limited to public proxies IP address." \
		"IP2Location.com" "https://lite.ip2location.com/database/px1-ip-country" \
		license "Creative Commons Attribution 4.0 International Public License" \
		public_url "http://www.ip2location.com/download/?token=APIKEY&file=PX1LITE" \
		dont_enable_with_all \
		dont_redistribute
fi


# -----------------------------------------------------------------------------
# VoIPBL.org
# http://www.voipbl.org/

update voipbl $[4*60] 0 ipv4 both \
	"http://www.voipbl.org/update/" \
	remove_comments \
	"attacks" \
	"[VoIPBL.org](http://www.voipbl.org/) a distributed VoIP blacklist that is aimed to protects against VoIP Fraud and minimizing abuse for network that have publicly accessible PBX's. Several algorithms, external sources and manual confirmation are used before they categorize something as an attack and determine the threat level." \
	"VoIPBL.org" "http://www.voipbl.org/"


# -----------------------------------------------------------------------------
# Stefan Gofferje
# http://stefan.gofferje.net/

update gofferje_sip $[6*60] 0 ipv4 both \
	"http://stefan.gofferje.net/sipblocklist.zone" \
	remove_comments \
	"attacks" \
	"[Stefan Gofferje](http://stefan.gofferje.net/it-stuff/sipfraud/sip-attacker-blacklist) A personal blacklist of networks and IPs of SIP attackers. To end up here, the IP or network must have been the origin of considerable and repeated attacks on my PBX and additionally, the ISP didn't react to any complaint. Note from the author: I don't give any guarantees of accuracy, completeness or even usability! USE AT YOUR OWN RISK! Also note that I block complete countries, namely China, Korea and Palestine with blocklists from ipdeny.com, so some attackers will never even get the chance to get noticed by me to be put on this blacklist. I also don't accept any liabilities related to this blocklist. If you're an ISP and don't like your IPs being listed here, too bad! You should have done something about your customers' behavior and reacted to my complaints. This blocklist is nothing but an expression of my personal opinion and exercising my right of free speech." \
	"Stefan Gofferje" "http://stefan.gofferje.net/it-stuff/sipfraud/sip-attacker-blacklist"


# -----------------------------------------------------------------------------
# LashBack Unsubscribe Blacklist
# http://blacklist.lashback.com/
# (this is a big list, more than 500.000 IPs)

update lashback_ubl $[24*60] 0 ipv4 ip \
	"http://www.unsubscore.com/blacklist.txt" \
	remove_comments \
	"spam" \
	"[The LashBack UBL](http://blacklist.lashback.com/) The Unsubscribe Blacklist (UBL) is a real-time blacklist of IP addresses which are sending email to names harvested from suppression files (this is a big list, more than 500.000 IPs)" \
	"The LashBack Unsubscribe Blacklist" "http://blacklist.lashback.com/"


# -----------------------------------------------------------------------------
# DataPlane.org
# DataPlane.org is a community-powered Internet data, feeds and measurement resource for operators, by operators. We provide reliable and trustworthy service at no cost.

dataplane_column3() { remove_comments | $CUT_CMD -d '|' -f 3 | trim; }

update dataplane_sipquery 60 0 ipv4 ip \
	"https://dataplane.org/sipquery.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that has been seen initiating a SIP OPTIONS query to a remote host. This report lists hosts that are suspicious of more than just port scanning. These hosts may be SIP server cataloging or conducting various forms of telephony abuse." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_sshpwauth 60 0 ipv4 ip \
	"https://dataplane.org/sshpwauth.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that has been seen attempting to remotely login to a host using SSH password authentication. This report lists hosts that are highly suspicious and are likely conducting malicious SSH password authentication attacks." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_sshclient 60 0 ipv4 ip \
	"https://dataplane.org/sshclient.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that has been seen initiating an SSH connection to a remote host. This report lists hosts that are suspicious of more than just port scanning.  These hosts may be SSH server cataloging or conducting authentication attack attempts." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_sipregistration 60 0 ipv4 ip \
	"https://dataplane.org/sipregistration.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that have been seen initiating a SIP REGISTER operation to a remote host. This report lists hosts that are suspicious of more than just port scanning.  These hosts may be SIP client cataloging or conducting various forms of telephony abuse." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_sipinvitation 60 0 ipv4 ip \
	"https://dataplane.org/sipinvitation.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that have been seen initiating a SIP INVITE operation to a remote host. This report lists hosts that are suspicious of more than just port scanning.  These hosts may be SIP client cataloging or conducting various forms of telephony abuse." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_vncrfb 60 0 ipv4 ip \
	"https://dataplane.org/vncrfb.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that have been seen initiating a VNC remote frame buffer (RFB) session to a remote host. This report lists hosts that are suspicious of more than just port scanning. These hosts may be VNC server cataloging or conducting various forms of remote access abuse." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_dnsrd 60 0 ipv4 ip \
	"https://dataplane.org/dnsrd.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that have been identified as sending recursive DNS queries to a remote host. This report lists addresses that may be cataloging open DNS resolvers or evaluating cache entries." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_dnsrdany 60 0 ipv4 ip \
	"https://dataplane.org/dnsrdany.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that have been identified as sending recursive DNS IN ANY queries to a remote host. This report lists addresses that may be cataloging open DNS resolvers for the purpose of later using them to facilitate DNS amplification and reflection attacks." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute

update dataplane_dnsversion 60 0 ipv4 ip \
	"https://dataplane.org/dnsversion.txt" \
	dataplane_column3 \
	"attacks" \
	"[DataPlane.org](https://dataplane.org/) IP addresses that have been identified as sending DNS CH TXT VERSION.BIND queries to a remote host. This report lists addresses that may be cataloging DNS software." \
	"DataPlane.org" "https://dataplane.org/" \
	dont_redistribute


# -----------------------------------------------------------------------------
# Dragon Research Group (DRG)
# HTTP report
# http://www.dragonresearchgroup.org/

#dragon_column3() { remove_comments | $CUT_CMD -d '|' -f 3 | trim; }

delete_ipset dragon_http
#update dragon_http 60 0 ipv4 both \
#	"http://www.dragonresearchgroup.org/insight/http-report.txt" \
#	dragon_column3 \
#	"attacks" \
#	"[Dragon Research Group](http://www.dragonresearchgroup.org/) IPs that have been seen sending HTTP requests to Dragon Research Pods in the last 7 days. This report lists hosts that are highly suspicious and are likely conducting malicious HTTP attacks. LEGITIMATE SEARCH ENGINE BOTS MAY BE IN THIS LIST. This report is informational.  It is not a blacklist, but some operators may choose to use it to help protect their networks and hosts in the forms of automated reporting and mitigation services." \
#	"Dragon Research Group (DRG)" "http://www.dragonresearchgroup.org/" \
#	dont_redistribute

delete_ipset dragon_sshpauth
#update dragon_sshpauth 60 0 ipv4 both \
#	"https://www.dragonresearchgroup.org/insight/sshpwauth.txt" \
#	dragon_column3 \
#	"attacks" \
#	"[Dragon Research Group](http://www.dragonresearchgroup.org/) IP address that has been seen attempting to remotely login to a host using SSH password authentication, in the last 7 days. This report lists hosts that are highly suspicious and are likely conducting malicious SSH password authentication attacks." \
#	"Dragon Research Group (DRG)" "http://www.dragonresearchgroup.org/" \
#	dont_redistribute

delete_ipset dragon_vncprobe
#update dragon_vncprobe 60 0 ipv4 both \
#	"https://www.dragonresearchgroup.org/insight/vncprobe.txt" \
#	dragon_column3 \
#	"attacks" \
#	"[Dragon Research Group](http://www.dragonresearchgroup.org/) IP address that has been seen attempting to remotely connect to a host running the VNC application service, in the last 7 days. This report lists hosts that are highly suspicious and are likely conducting malicious VNC probes or VNC brute force attacks." \
#	"Dragon Research Group (DRG)" "http://www.dragonresearchgroup.org/" \
#	dont_redistribute


# -----------------------------------------------------------------------------
# Nothink.org

update nt_ssh_7d 60 0 ipv4 ip \
	"http://www.nothink.org/blacklist/blacklist_ssh_week.txt" \
	remove_comments \
	"attacks" \
	"[NoThink](http://www.nothink.org/) Last 7 days SSH attacks" \
	"NoThink.org" "http://www.nothink.org/"

update nt_malware_irc 60 0 ipv4 ip \
	"http://www.nothink.org/blacklist/blacklist_malware_irc.txt" \
	remove_comments \
	"attacks" \
	"[No Think](http://www.nothink.org/) Malware IRC" \
	"NoThink.org" "http://www.nothink.org/"

update nt_malware_http 60 0 ipv4 ip \
	"http://www.nothink.org/blacklist/blacklist_malware_http.txt" \
	remove_comments \
	"attacks" \
	"[No Think](http://www.nothink.org/) Malware HTTP" \
	"NoThink.org" "http://www.nothink.org/"

update nt_malware_dns 60 0 ipv4 ip \
	"http://www.nothink.org/blacklist/blacklist_malware_dns.txt" \
	remove_comments \
	"attacks" \
	"[No Think](http://www.nothink.org/) Malware DNS (the original list includes hostnames and domains, which are ignored)" \
	"NoThink.org" "http://www.nothink.org/"

# -----------------------------------------------------------------------------
# Bambenek Consulting
# http://osint.bambenekconsulting.com/feeds/

bambenek_filter() { remove_comments | $CUT_CMD -d ',' -f 1; }

update bambenek_c2 30 0 ipv4 ip \
	"http://osint.bambenekconsulting.com/feeds/c2-ipmasterlist.txt" \
	bambenek_filter \
	"malware" \
	"[Bambenek Consulting](http://osint.bambenekconsulting.com/feeds/) master feed of known, active and non-sinkholed C&Cs IP addresses" \
	"Bambenek Consulting" "http://osint.bambenekconsulting.com/feeds/"

for list in banjori bebloh cl cryptowall dircrypt dyre geodo hesperbot matsnu necurs p2pgoz pushdo pykspa qakbot ramnit ranbyus simda suppobox symmi tinba volatile
do
	update bambenek_${list} 30 0 ipv4 ip \
		"http://osint.bambenekconsulting.com/feeds/${list}-iplist.txt" \
		bambenek_filter \
		"malware" \
		"[Bambenek Consulting](http://osint.bambenekconsulting.com/feeds/) feed of current IPs of ${list} C&Cs with 90 minute lookback" \
		"Bambenek Consulting" "http://osint.bambenekconsulting.com/feeds/" \
		can_be_empty
done


# -----------------------------------------------------------------------------
# BotScout
# http://botscout.com/

botscout_filter() {
	while read_xml_dom
	do
		[[ "${XML_ENTITY}" =~ ^a\ .*/ipcheck.htm\?ip=.* ]] && echo "${XML_CONTENT}"
	done
}

update botscout 30 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://botscout.com/last_caught_cache.htm" \
	botscout_filter \
	"abuse" \
	"[BotScout](http://botscout.com/) helps prevent automated web scripts, known as bots, from registering on forums, polluting databases, spreading spam, and abusing forms on web sites. They do this by tracking the names, IPs, and email addresses that bots use and logging them as unique signatures for future reference. They also provide a simple yet powerful API that you can use to test forms when they're submitted on your site. This list is composed of the most recently-caught bots." \
	"BotScout.com" "http://botscout.com/"

# -----------------------------------------------------------------------------
# GreenSnow
# https://greensnow.co/

update greensnow 30 0 ipv4 ip \
	"http://blocklist.greensnow.co/greensnow.txt" \
	remove_comments \
	"attacks" \
	"[GreenSnow](https://greensnow.co/) is a team harvesting a large number of IPs from different computers located around the world. GreenSnow is comparable with SpamHaus.org for attacks of any kind except for spam. Their list is updated automatically and you can withdraw at any time your IP address if it has been listed. Attacks / bruteforce that are monitored are: Scan Port, FTP, POP3, mod_security, IMAP, SMTP, SSH, cPanel, etc." \
	"GreenSnow.co" "https://greensnow.co/"


# -----------------------------------------------------------------------------
# http://cybercrime-tracker.net/fuckerz.php

update cybercrime $[12 * 60] 0 ipv4 ip \
	"http://cybercrime-tracker.net/fuckerz.php" \
	extract_ipv4_from_any_file \
	"malware" \
	"[CyberCrime](http://cybercrime-tracker.net/) A project tracking Command and Control." \
	"CyberCrime" "http://cybercrime-tracker.net/"


# -----------------------------------------------------------------------------
# http://vxvault.net/ViriList.php?s=0&m=100

update vxvault $[12 * 60] 0 ipv4 ip \
	"http://vxvault.net/ViriList.php?s=0&m=100" \
	extract_ipv4_from_any_file \
	"malware" \
	"[VxVault](http://vxvault.net) The latest 100 additions of VxVault." \
	"VxVault" "http://vxvault.net"

# -----------------------------------------------------------------------------
# Bitcoin connected hosts

delete_ipset bitcoin_blockchain_info
#update bitcoin_blockchain_info 10 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
#	"https://blockchain.info/en/connected-nodes" \
#	extract_ipv4_from_any_file \
#	"organizations" \
#	"[Blockchain.info](https://blockchain.info/en/connected-nodes) Bitcoin nodes connected to Blockchain.info." \
#	"Blockchain.info" "https://blockchain.info/en/connected-nodes"

update bitcoin_nodes 10 "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"https://getaddr.bitnodes.io/api/v1/snapshots/latest/" \
	extract_ipv4_from_any_file \
	"organizations" \
	"[BitNodes](https://getaddr.bitnodes.io/) Bitcoin connected nodes, globally." \
	"BitNodes" "https://getaddr.bitnodes.io/"


# -----------------------------------------------------------------------------
# BinaryDefense.com

update bds_atif $[24*60] 0 ipv4 ip \
	"https://www.binarydefense.com/banlist.txt" \
	remove_comments \
	"reputation" \
	"Artillery Threat Intelligence Feed and Banlist Feed" \
	"Binary Defense Systems" "https://www.binarydefense.com/"


# -----------------------------------------------------------------------------
# TrustedSec.com
# https://github.com/firehol/blocklist-ipsets/issues/47

delete_ipset trustedsec_atif
#update trustedsec_atif $[24*60] 0 ipv4 ip \
#	"https://www.trustedsec.com/banlist.txt" \
#	remove_comments \
#	"reputation" \
#	"Artillery Threat Intelligence Feed and Banlist Feed" \
#	"TrustedSec" "https://www.trustedsec.com/"


# -----------------------------------------------------------------------------
# bbcan177

update bbcan177_ms1 $[24*60] 0 ipv4 both \
	"https://gist.githubusercontent.com/BBcan177/bf29d47ea04391cb3eb0/raw" \
	remove_comments \
	"malware" \
	"pfBlockerNG Malicious Threats" \
	"BBcan177" "https://gist.github.com/BBcan177"

update bbcan177_ms3 $[24*60] 0 ipv4 both \
	"https://gist.githubusercontent.com/BBcan177/d7105c242f17f4498f81/raw" \
	remove_comments \
	"malware" \
	"pfBlockerNG Malicious Threats" \
	"BBcan177" "https://gist.github.com/BBcan177"

# -----------------------------------------------------------------------------
# eSentire

eSentire


# -----------------------------------------------------------------------------
# Pushing Inertia
# https://github.com/pushinginertia/ip-blacklist

parse_pushing_inertia() { $GREP_CMD "^deny from " | $CUT_CMD -d ' ' -f 3-; }

update pushing_inertia_blocklist $[24*60] 0 ipv4 both \
	"https://raw.githubusercontent.com/pushinginertia/ip-blacklist/master/ip_blacklist.conf" \
	parse_pushing_inertia \
	"reputation" \
	"[Pushing Inertia](https://github.com/pushinginertia/ip-blacklist) IPs of hosting providers that are known to host various bots, spiders, scrapers, etc. to block access from these providers to web servers." \
	"Pushing Inertia" "https://github.com/pushinginertia/ip-blacklist" \
	license "MIT" \
	intended_use "firewall_block_service" \
	protection "inbound" \
	grade "unknown" \
	false_positives "none" \
	poisoning "not_possible"


# -----------------------------------------------------------------------------
# http://nullsecure.org/

update nullsecure $[8*60] 0 ipv4 ip \
	"http://nullsecure.org/threatfeed/master.txt" \
	extract_ipv4_from_any_file \
	"reputation" \
	"[nullsecure.org](http://nullsecure.org/) This is a free threat feed provided for use in any acceptable manner. This feed was aggregated using the [Tango Honeypot Intelligence Splunk App](https://github.com/aplura/Tango) by Brian Warehime, a Senior Security Analyst at Defense Point Security." \
	"nullsecure.org" "http://nullsecure.org/"


# -----------------------------------------------------------------------------
# http://www.chaosreigns.com/

#parse_chaosreigns_once() {
#	local wanted="${1}"
#
#	if [ ! -f "${RUN_DIR}/${wanted}.source" ]
#		then
#		# parse the source and split it to all files in RUN_DIR
#		$GAWK_CMD	>&2 "
#			/^[[:space:]]*[[:digit:]\./]+[[:space:]]+100[[:space:]]+[[:digit:]]+\$/          { print \$1 >\"${RUN_DIR}/chaosreigns_iprep100.source\"; next; }
#			/^[[:space:]]*[[:digit:]\./]+[[:space:]]+0[[:space:]]+[[:digit:]]+\$/            { print \$1 >\"${RUN_DIR}/chaosreigns_iprep0.source\"; next; }
#			/^[[:space:]]*[[:digit:]\./]+[[:space:]]+[[:digit:]]+[[:space:]]+[[:digit:]]+\$/ { print \$1 >\"${RUN_DIR}/chaosreigns_iprep50.source\"; next; }
#			// { print \$1 >\"${RUN_DIR}/chaosreigns_iprep_invalid.source\"; next; }
#			"
#	else
#		# ignore the source being fed to us
#		$CAT_CMD >/dev/null
#	fi
#	
#	# give the parsed output
#	$CAT_CMD "${RUN_DIR}/${wanted}.source"
#
#	# make sure all the variations have the same source
#	ipsets_with_common_source_file "chaosreigns_iprep100" "chaosreigns_iprep50" "chaosreigns_iprep0"
#}

#parse_chaosreigns_iprep100() { parse_chaosreigns_once chaosreigns_iprep100; }
#parse_chaosreigns_iprep50()  { parse_chaosreigns_once chaosreigns_iprep50;  }
#parse_chaosreigns_iprep0()   { parse_chaosreigns_once chaosreigns_iprep0;   }

delete_ipset chaosreigns_iprep100
#update chaosreigns_iprep100 $[24*60] 0 ipv4 ip \
#	"http://www.chaosreigns.com/iprep/iprep.txt" \
#	parse_chaosreigns_iprep100 \
#	"spam" \
#	"[ChaosReigns.com](http://www.chaosreigns.com/iprep) The iprep100 list includes all IPs that sent 100% ham emails. This is an automated, free, public email IP reputation system. The primary goal is a whitelist. Other data is provided as a consequence." \
#	"ChaosReigns.com" "http://www.chaosreigns.com/iprep"

delete_ipset chaosreigns_iprep50
#update chaosreigns_iprep50 $[24*60] 0 ipv4 ip \
#	"http://www.chaosreigns.com/iprep/iprep.txt" \
#	parse_chaosreigns_iprep50 \
#	"spam" \
#	"[ChaosReigns.com](http://www.chaosreigns.com/iprep) The iprep50 list includes all IPs that sent both ham and spam emails. This is an automated, free, public email IP reputation system. The primary goal is a whitelist. Other data is provided as a consequence." \
#	"ChaosReigns.com" "http://www.chaosreigns.com/iprep"

delete_ipset chaosreigns_iprep0
#update chaosreigns_iprep0 $[24*60] 0 ipv4 ip \
#	"http://www.chaosreigns.com/iprep/iprep.txt" \
#	parse_chaosreigns_iprep0 \
#	"spam" \
#	"[ChaosReigns.com](http://www.chaosreigns.com/iprep) The iprep0 list includes all IPs that sent only spam emails. This is an automated, free, public email IP reputation system. The primary goal is a whitelist. Other data is provided as a consequence." \
#	"ChaosReigns.com" "http://www.chaosreigns.com/iprep"


# -----------------------------------------------------------------------------
# https://graphiclineweb.wordpress.com/tech-notes/ip-blacklist/

parse_graphiclineweb() { $GREP_CMD -oP ">${IP4_MATCH}(/${MK4_MATCH})?<" | $GREP_CMD -oP "${IP4_MATCH}(/${MK4_MATCH})?"; }

update graphiclineweb $[24*60] 0 ipv4 both \
	"https://graphiclineweb.wordpress.com/tech-notes/ip-blacklist/" \
	parse_graphiclineweb \
	"abuse" \
	"[GraphiclineWeb](https://graphiclineweb.wordpress.com/tech-notes/ip-blacklist/) The IP’s, Hosts and Domains listed in this table are banned universally from accessing websites controlled by the maintainer. Some form of bad activity has been seen from the addresses listed. Bad activity includes: unwanted spiders, rule breakers, comment spammers, trackback spammers, spambots, hacker bots, registration bots and other scripting attackers, harvesters, nuisance spiders, spy bots and organizations spying on websites for commercial reasons." \
	"GraphiclineWeb" "https://graphiclineweb.wordpress.com/tech-notes/ip-blacklist/"


# -----------------------------------------------------------------------------
# http://www.ip-finder.me/ip-full-list/

parse_ipblacklistcloud() { $GREP_CMD -oP ">${IP4_MATCH}<" | $GREP_CMD -oP "${IP4_MATCH}"; }

update ipblacklistcloud_top $[24*60] 0 ipv4 ip \
	"http://www.ip-finder.me/ip-full-list/" \
	parse_ipblacklistcloud \
	"abuse" \
	"[IP Blacklist Cloud](http://www.ip-finder.me/) These are the top IP addresses that have been blacklisted by many websites. IP Blacklist Cloud plugin protects your WordPress based website from spam comments, gives details about login attacks which you don't even know are happening without this plugin!" \
	"IP Blacklist Cloud" "http://www.ip-finder.me/"

update ipblacklistcloud_recent $[4 * 60] "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"http://www.ip-finder.me/download/" \
	parse_ipblacklistcloud \
	"abuse" \
	"[IP Blacklist Cloud](http://www.ip-finder.me/) These are the most recent IP addresses that have been blacklisted by websites. IP Blacklist Cloud plugin protects your WordPress based website from spam comments, gives details about login attacks which you don't even know are happening without this plugin!" \
	"IP Blacklist Cloud" "http://www.ip-finder.me/"


# -----------------------------------------------------------------------------
# http://www.cyberthreatalliance.org/cryptowall-dashboard.html

parse_cta_cryptowall() { $CUT_CMD -d ',' -f 3; }

update cta_cryptowall $[24*60] 0 ipv4 ip \
	"https://public.tableau.com/views/CTAOnlineViz/DashboardData.csv?:embed=y&:showVizHome=no&:showTabs=y&:display_count=y&:display_static_image=y&:bootstrapWhenNotified=true" \
	parse_cta_cryptowall \
	"malware" \
	"[Cyber Threat Alliance](http://www.cyberthreatalliance.org/cryptowall-dashboard.html)  CryptoWall is one of the most lucrative and broad-reaching ransomware campaigns affecting Internet users today. Sharing intelligence and analysis resources, the CTA profiled the latest version of CryptoWall, which impacted hundreds of thousands of users, resulting in over US \$325 million in damages worldwide." \
	"Cyber Threat Alliance" "http://www.cyberthreatalliance.org/cryptowall-dashboard.html"


# -----------------------------------------------------------------------------
# https://github.com/client9/ipcat

parse_client9_ipcat_datacenters() {
	 $CUT_CMD -d ',' -f 1,2 |\
	 	$TR_CMD "," "-" |\
	 	$IPRANGE_CMD
}

update datacenters $[24*60] 0 ipv4 both \
	"https://raw.githubusercontent.com/client9/ipcat/master/datacenters.csv" \
	parse_client9_ipcat_datacenters \
	"organizations" \
	"[Nick Galbreath](https://github.com/client9/ipcat) This is a list of IPv4 address that correspond to datacenters, co-location centers, shared and virtual webhosting providers. In other words, ip addresses that end web consumers should not be using." \
	"Nick Galbreath" "https://github.com/client9/ipcat" \
	license "GPLv3" \
	never_empty


# -----------------------------------------------------------------------------
# https://cleantalk.org/

parse_cleantalk() { $GREP_CMD -oP ">[[:space:]]*${IP4_MATCH}[[:space:]]*<" | $GREP_CMD -oP "${IP4_MATCH}"; }

update cleantalk_new $[15] "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"https://cleantalk.org/blacklists/submited_today" \
	parse_cleantalk \
	"abuse" \
	"[CleanTalk](https://cleantalk.org/) Recent HTTP Spammers" \
	"CleanTalk" "https://cleantalk.org/" \
	can_be_empty

update cleantalk_updated $[15] "$[24*60] $[7*24*60] $[30*24*60]" ipv4 ip \
	"https://cleantalk.org/blacklists/updated_today" \
	parse_cleantalk \
	"abuse" \
	"[CleanTalk](https://cleantalk.org/) Recurring HTTP Spammers" \
	"CleanTalk" "https://cleantalk.org/" \
	can_be_empty

update cleantalk_top20 $[24*60] 0 ipv4 ip \
	"https://cleantalk.org/blacklists/top20" \
	parse_cleantalk \
	"abuse" \
	"[CleanTalk](https://cleantalk.org/) Top 20 HTTP Spammers" \
	"CleanTalk" "https://cleantalk.org/" \
	can_be_empty

merge cleantalk ipv4 ip \
	"abuse" \
	"[CleanTalk](https://cleantalk.org/) Today's HTTP Spammers" \
	"CleanTalk" "https://cleantalk.org/" \
	cleantalk_new \
	cleantalk_updated

merge cleantalk_1d ipv4 ip \
	"abuse" \
	"[CleanTalk](https://cleantalk.org/) Today's HTTP Spammers" \
	"CleanTalk" "https://cleantalk.org/" \
	cleantalk_new_1d \
	cleantalk_updated_1d

merge cleantalk_7d ipv4 ip \
	"abuse" \
	"[CleanTalk](https://cleantalk.org/) Today's HTTP Spammers" \
	"CleanTalk" "https://cleantalk.org/" \
	cleantalk_new_7d \
	cleantalk_updated_7d

merge cleantalk_30d ipv4 ip \
	"abuse" \
	"[CleanTalk](https://cleantalk.org/) Today's HTTP Spammers" \
	"CleanTalk" "https://cleantalk.org/" \
	cleantalk_new_30d \
	cleantalk_updated_30d

# -----------------------------------------------------------------------------
# http://www.jigsawsecurityenterprise.com/#!open-blacklist/kafsx

delete_ipset jigsaw_attacks
#update jigsaw_attacks $[24*60] 0 ipv4 ip \
#	"http://www.slcsecurity.com/feedspublic/IP/malicious-ip-src.txt" \
#	remove_comments \
#	"attacks" \
#	"[Jigsaw Security Enterprise](http://www.jigsawsecurityenterprise.com/#!open-blacklist/kafsx) IP Address Sources of Attack. Information on this blacklist is low fidelity meaning we do not update these indicators that often and there is no validation of the data. These are raw feeds that have not been processed. In order to get the most up to date data and to remove false positives you should consider subscribing to our Jigsaw Enterprise Solution." \
#	"Jigsaw Security Enterprise" "http://www.jigsawsecurityenterprise.com/#!open-blacklist/kafsx"

delete_ipset jigsaw_malware
#update jigsaw_malware $[24*60] 0 ipv4 ip \
#	"http://www.slcsecurity.com/feedspublic/IP/malicious-ip-dst.txt" \
#	remove_comments \
#	"malware" \
#	"[Jigsaw Security Enterprise](http://www.jigsawsecurityenterprise.com/#!open-blacklist/kafsx) Malicious IP Destinations usually C2 or botnet activity or malicious payloads. Information on this blacklist is low fidelity meaning we do not update these indicators that often and there is no validation of the data. These are raw feeds that have not been processed. In order to get the most up to date data and to remove false positives you should consider subscribing to our Jigsaw Enterprise Solution." \
#	"Jigsaw Security Enterprise" "http://www.jigsawsecurityenterprise.com/#!open-blacklist/kafsx"

# -----------------------------------------------------------------------------
# CoinBlockerLists
# https://github.com/ZeroDot1/CoinBlockerLists

update coinbl_hosts $[24*60] 0 ipv4 ip \
	"https://zerodot1.gitlab.io/CoinBlockerLists/hosts" \
	hphosts2ips \
	"organizations" \
	"[CoinBlockerLists](https://gitlab.com/ZeroDot1/CoinBlockerLists) Simple lists that can help prevent cryptomining in the browser or other applications. This list contains all domains - A list for administrators to prevent mining in networks. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"CoinBlockerLists" "https://gitlab.com/ZeroDot1/CoinBlockerLists" \
	dont_enable_with_all

update coinbl_hosts_optional $[24*60] 0 ipv4 ip \
	"https://zerodot1.gitlab.io/CoinBlockerLists/hosts_optional" \
	hphosts2ips \
	"organizations" \
	"[CoinBlockerLists](https://gitlab.com/ZeroDot1/CoinBlockerLists) Simple lists that can help prevent cryptomining in the browser or other applications. This list contains additional domains, for administrators to prevent mining in networks. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"CoinBlockerLists" "https://gitlab.com/ZeroDot1/CoinBlockerLists" \
	dont_enable_with_all

update coinbl_hosts_browser $[24*60] 0 ipv4 ip \
	"https://zerodot1.gitlab.io/CoinBlockerLists/hosts_browser" \
	hphosts2ips \
	"organizations" \
	"[CoinBlockerLists](https://gitlab.com/ZeroDot1/CoinBlockerLists) Simple lists that can help prevent cryptomining in the browser or other applications. A hosts list to prevent browser mining only. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"CoinBlockerLists" "https://gitlab.com/ZeroDot1/CoinBlockerLists" \
	dont_enable_with_all

update coinbl_ips $[24*60] 0 ipv4 ip \
	"https://zerodot1.gitlab.io/CoinBlockerLists/MiningServerIPList.txt" \
	remove_comments \
	"organizations" \
	"[CoinBlockerLists](https://gitlab.com/ZeroDot1/CoinBlockerLists) Simple lists that can help prevent cryptomining in the browser or other applications. This list contains all IPs - An additional list for administrators to prevent mining in networks. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"CoinBlockerLists" "https://gitlab.com/ZeroDot1/CoinBlockerLists" \


# -----------------------------------------------------------------------------
# http://hosts-file.net/
update hphosts_ats $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/ad_servers.txt" \
	hphosts2ips \
	"organizations" \
	"[hpHosts](http://hosts-file.net/?s=Download) ad/tracking servers listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_emd $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/emd.txt" \
	hphosts2ips \
	"malware" \
	"[hpHosts](http://hosts-file.net/?s=Download) malware sites listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_exp $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/exp.txt" \
	hphosts2ips \
	"malware" \
	"[hpHosts](http://hosts-file.net/?s=Download) exploit sites listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_fsa $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/fsa.txt" \
	hphosts2ips \
	"reputation" \
	"[hpHosts](http://hosts-file.net/?s=Download) fraud sites listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_grm $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/grm.txt" \
	hphosts2ips \
	"spam" \
	"[hpHosts](http://hosts-file.net/?s=Download) sites involved in spam (that do not otherwise meet any other classification criteria) listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_hfs $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/hfs.txt" \
	hphosts2ips \
	"abuse" \
	"[hpHosts](http://hosts-file.net/?s=Download) sites spamming the hpHosts forums (and not meeting any other classification criteria) listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_hjk $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/hjk.txt" \
	hphosts2ips \
	"malware" \
	"[hpHosts](http://hosts-file.net/?s=Download) hijack sites listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_mmt $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/mmt.txt" \
	hphosts2ips \
	"reputation" \
	"[hpHosts](http://hosts-file.net/?s=Download) sites involved in misleading marketing (e.g. fake Flash update adverts) listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_pha $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/pha.txt" \
	hphosts2ips \
	"reputation" \
	"[hpHosts](http://hosts-file.net/?s=Download) illegal pharmacy sites listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_psh $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/psh.txt" \
	hphosts2ips \
	"reputation" \
	"[hpHosts](http://hosts-file.net/?s=Download) phishing sites listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

update hphosts_wrz $[24*60] 0 ipv4 ip \
	"http://hosts-file.net/wrz.txt" \
	hphosts2ips \
	"reputation" \
	"[hpHosts](http://hosts-file.net/?s=Download) warez/piracy sites listed in the hpHosts database. The maintainer's file contains hostnames, which have been DNS resolved to IP addresses." \
	"hpHosts" "http://hosts-file.net/" \
	dont_enable_with_all

# -----------------------------------------------------------------------------
# iBlocklist
# https://www.iblocklist.com/lists.php

# we only keep the proxies IPs (tor IPs are not parsed)
update iblocklist_proxies $[12*60] 0 ipv4 ip \
	"http://list.iblocklist.com/?list=xoebmbyexwuiogmbyprb&fileformat=p2p&archiveformat=gz" \
	p2p_gz_proxy \
	"anonymizers" \
	"Open Proxies IPs list (without TOR)" \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_spyware $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=llvtlsjyoyiczbkjsxpf&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"Known malicious SPYWARE and ADWARE IP Address ranges. It is compiled from various sources, including other available spyware blacklists, HOSTS files, from research found at many of the top anti-spyware forums, logs of spyware victims, etc." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_badpeers $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=cwworuawihqvocglcoss&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"IPs that have been reported for bad deeds in p2p." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_hijacked $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=usrcshglbiilevmyfhse&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"attacks" \
	"Hijacked IP-Blocks. Contains hijacked IP-Blocks and known IP-Blocks that are used to deliver Spam. This list is a combination of lists with hijacked IP-Blocks. Hijacked IP space are IP blocks that are being used without permission by organizations that have no relation to original organization (or its legal successor) that received the IP block. In essence it's stealing of somebody else's IP resources." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_webexploit $[12*60] 0 ipv4 ip \
	"http://list.iblocklist.com/?list=ghlzqtqxnzctvvajwwag&fileformat=p2p&archiveformat=gz" \
	p2p_gz_ips \
	"reputation" \
	"Web server hack and exploit attempts. IP addresses related to current web server hack and exploit attempts that have been logged or can be found in and cross referenced with other related IP databases. Malicious and other non search engine bots will also be listed here, along with anything found that can have a negative impact on a website or webserver such as proxies being used for negative SEO hijacks, unauthorised site mirroring, harvesting, scraping, snooping and data mining / spy bot / security & copyright enforcement companies that target and continuosly scan webservers." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_level1 $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=ydxerpxkpcfqjaybcssw&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"Level 1 (for use in p2p): Companies or organizations who are clearly involved with trying to stop filesharing (e.g. Baytsp, MediaDefender, Mediasentry). Companies which anti-p2p activity has been seen from. Companies that produce or have a strong financial interest in copyrighted material (e.g. music, movie, software industries a.o.). Government ranges or companies that have a strong financial interest in doing work for governments. Legal industry ranges. IPs or ranges of ISPs from which anti-p2p activity has been observed. Basically this list will block all kinds of internet connections that most people would rather not have during their internet travels." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_level2 $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=gyisgnzbhppbvsphucsw&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"Level 2 (for use in p2p). General corporate ranges. Ranges used by labs or researchers. Proxies." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_level3 $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=uwnukjqktoggdknzrhgh&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"Level 3 (for use in p2p). Many portal-type websites. ISP ranges that may be dodgy for some reason. Ranges that belong to an individual, but which have not been determined to be used by a particular company. Ranges for things that are unusual in some way. The L3 list is aka the paranoid list." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_edu $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=imlmncgrkbnacgcwfjvh&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"IPs used by Educational Institutions." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_rangetest $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=plkehquoahljmyxjixpu&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"Suspicious IPs that are under investigation." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_bogons $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=gihxqmhyunbxhbmgqrla&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"unroutable" \
	"Unallocated address space." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_ads $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=dgxtneitpuvgqqcpfulq&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Advertising trackers and a short list of bad/intrusive porn sites." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_org_microsoft $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=xshktygkujudfnjfioro&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Microsoft IP ranges." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_spider $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=mcvxsnihddgutbjfbghy&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"IP list intended to be used by webmasters to block hostile spiders from their web sites." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_dshield $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=xpbqleszmajjesnzddhv&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"attacks" \
	"known Hackers and such people." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_iana_reserved $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=bcoepfyewziejvcqyhqo&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"unroutable" \
	"IANA Reserved IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_iana_private $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=cslpybexmxyuacbyuvib&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"unroutable" \
	"IANA Private IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_iana_multicast $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=pwqnlynprfgtjbgqoizj&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"unroutable" \
	"IANA Multicast IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_fornonlancomputers $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=jhaoawihmfxgnvmaqffp&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"IP blocklist for non-LAN computers." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_exclusions $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=mtxmiireqmjzazcsoiem&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"Exclusions." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_forumspam $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=ficutxiwawokxlcyoeye&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"abuse" \
	"Forum spam." \
	"iBlocklist.com" "https://www.iblocklist.com/" \
	dont_redistribute

update iblocklist_pedophiles $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=dufcxgnbjsdwmwctgfuj&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"IP ranges of people who we have found to be sharing child pornography in the p2p community." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_cruzit_web_attacks $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=czvaehmjpsnwwttrdoyl&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"attacks" \
	"CruzIT IP list with individual IP addresses of compromised machines scanning for vulnerabilities and DDOS attacks." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_yoyo_adservers $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=zhogegszwduurnvsyhdf&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"pgl.yoyo.org ad servers" \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_spamhaus_drop $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=zbdlwrqkabxbcppvrnos&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"attacks" \
	"Spamhaus.org DROP (Don't Route Or Peer) list." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_abuse_zeus $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=ynkdjqsjyfmilsgbogqf&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"malware" \
	"zeustracker.abuse.ch IP blocklist that contains IP addresses which are currently beeing tracked on the abuse.ch ZeuS Tracker." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_abuse_spyeye $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=zvjxsfuvdhoxktpeiokq&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"malware" \
	"spyeyetracker.abuse.ch IP blocklist." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_abuse_palevo $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=erqajhwrxiuvjxqrrwfj&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"malware" \
	"palevotracker.abuse.ch IP blocklist." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_ciarmy_malicious $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=npkuuhuxcsllnhoamkvm&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"reputation" \
	"ciarmy.com IP blocklist. Based on information from a network of Sentinel devices deployed around the world, they compile a list of known bad IP addresses. Sentinel devices are uniquely positioned to pick up traffic from bad guys without requiring any type of signature-based or rate-based identification. If an IP is identified in this way by a significant number of Sentinels, the IP is malicious and should be blocked." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_malc0de $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=pbqcylkejciyhmwttify&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"malware" \
	"malc0de.com IP blocklist. Addresses that have been identified distributing malware during the past 30 days." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_cidr_report_bogons $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=lujdnbasfaaixitgmxpp&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"unroutable" \
	"cidr-report.org IP list of Unallocated address space." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_onion_router $[12*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=togdoptykrlolpddwbvz&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"anonymizers" \
	"The Onion Router IP addresses." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_apple $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=aphcqvpxuqgrkgufjruj&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Apple IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_logmein $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=tgbankumtwtrzllndbmb&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"LogMeIn IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_steam $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=cnxkgiklecdaihzukrud&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Steam IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_xfire $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=ppqqnyihmcrryraaqsjo&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"XFire IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_blizzard $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=ercbntshuthyykfkmhxc&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Blizzard IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_ubisoft $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=etmcrglomupyxtaebzht&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Ubisoft IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_nintendo $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=pevkykuhgaegqyayzbnr&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Nintendo IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_activision $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=gfnxlhxsijzrcuxwzebb&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Activision IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_sony_online $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=tukpvrvlubsputmkmiwg&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Sony Online Entertainment IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_crowd_control $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=eveiyhgmusglurfmjyag&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Crowd Control Productions IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_linden_lab $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=qnjdimxnaupjmpqolxcv&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Linden Lab IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_electronic_arts $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=ejqebpcdmffinaetsvxj&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Electronic Arts IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_square_enix $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=odyaqontcydnodrlyina&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Square Enix IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_ncsoft $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=mwjuwmebrnzyyxpbezxu&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"NCsoft IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_riot_games $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=sdlvfabdjvrdttfjotcy&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Riot Games IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_punkbuster $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=zvwwndvzulqcltsicwdg&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Punkbuster IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_joost $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=alxugfmeszbhpxqfdits&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Joost IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_pandora $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=aevzidimyvwybzkletsg&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Pandora IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_org_pirate_bay $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=nzldzlpkgrcncdomnttb&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"The Pirate Bay IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_aol $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=toboaiysofkflwgrttmb&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"AOL IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_comcast $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=rsgyxvuklicibautguia&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Comcast IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_cablevision $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=dwwbsmzirrykdlvpqozb&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Cablevision IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_verizon $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=cdmdbprvldivlqsaqjol&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Verizon IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_att $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=grbtkzijgrowvobvessf&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"AT&T IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_twc $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=aqtsnttnqmcucwrjmohd&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Time Warner Cable IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_charter $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=htnzojgossawhpkbulqw&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Charter IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_qwest $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=jezlifrpefawuoawnfez&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Qwest IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_embarq $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=twdblifaysaqtypevvdp&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Embarq IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_suddenlink $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=psaoblrwylfrdsspfuiq&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Suddenlink IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

update iblocklist_isp_sprint $[24*60] 0 ipv4 both \
	"http://list.iblocklist.com/?list=hngtqrhhuadlceqxbrob&fileformat=p2p&archiveformat=gz" \
	p2p_gz \
	"organizations" \
	"Sprint IPs." \
	"iBlocklist.com" "https://www.iblocklist.com/"

# -----------------------------------------------------------------------------
# https://blocklist.sigmaprojects.org/
# DOES NOT EXIST ANYMORE
delete_ipset sp_atma
#update sp_atma $[24*60] 0 ipv4 both \
#	"https://blocklist.sigmaprojects.org/api.cfc?method=getList&lists=atma" \
#	${ZCAT_CMD} \
#	"attacks" \
#	"Attackers who try to spy or remotely control others' computers by means such as Microsoft remote terminal, SSH, Telnet or shared desktops. Threats for email servers or users: spiders/bots, account hijacking, etc. Sites spreading virus, trojans, spyware, etc. or just being used by them to let their authors know that a new computer has been infected. Threats for servers: exploits, fake identities/agents, DDoS attackers, etc. Port scans, which are the first step towards more dangerous actions. Malicious P2P sharers or bad peers who spread malware, inject bad traffic or share fake archives. (The site states they re-distribute this IP List from iblocklist.com)." \
#	"SigmaProjects.org" "https://blocklist.sigmaprojects.org/"
#
delete_ipset sp_anti_infringement
#update sp_anti_infringement $[24*60] 0 ipv4 both \
#	"https://blocklist.sigmaprojects.org/api.cfc?method=getList&lists=anti-infringement" \
#	${ZCAT_CMD} \
#	"organizations" \
#	"IPs of Anti-Infringement organizations. (The site states they re-distribute this IP List from iblocklist.com)" \
#	"SigmaProjects.org" "https://blocklist.sigmaprojects.org/"
#
delete_ipset sp_spammers
#update sp_spammers $[24*60] 0 ipv4 both \
#	"https://blocklist.sigmaprojects.org/api.cfc?method=getList&lists=spammers" \
#	${ZCAT_CMD} \
#	"spam" \
#	"Spammers. (The site states they re-distribute this IP List from iblocklist.com)" \
#	"SigmaProjects.org" "https://blocklist.sigmaprojects.org/"


# -----------------------------------------------------------------------------
# https://www.gpf-comics.com/dnsbl/export.php

update gpf_comics $[24*60] 0 ipv4 ip \
	"https://www.gpf-comics.com/dnsbl/export.php" \
	remove_comments \
	"abuse" \
	"The GPF DNS Block List is a list of IP addresses on the Internet that have attacked the [GPF Comics](http://www.gpf-comics.com/) family of Web sites. IPs on this block list have been banned from accessing all of our servers because they were caught in the act of spamming, attempting to exploit our scripts, scanning for vulnerabilities, or consuming resources to the detriment of our human visitors." \
	"GPF Comics" "https://www.gpf-comics.com/dnsbl/" \
	downloader_options "--data 'ipv6=0&export_type=text&submit=Export'"


# -----------------------------------------------------------------------------
# http://urandom.us.to/report.php

parse_urandom_us_to() {
	${TR_CMD} '\r' '\n' |\
		${SED_CMD} -e 's|^.* IP=\(.*\) INFO=.* TAG=\(.*\) SOURCE=\(.*\)$|\1|g'
}

for x in dns ftp http mailer malware ntp smb spam ssh rdp telnet unspecified vnc
do
	case "${x}" in
		malware) category="malware" ;;
		mailer|spam) category="spam" ;;
		*) category="attacks" ;;
	esac

	update urandomusto_${x} $[60] 0 ipv4 ip \
		"http://urandom.us.to/report.php?ip=&info=&tag=${x}&out=txt&submit=go" \
		parse_urandom_us_to \
		"${category}" \
		"IP Feed about ${x}, crawled from several sources, including several twitter accounts." \
		"urandom.us.to" "http://urandom.us.to/"
done


# -----------------------------------------------------------------------------
# https://www.us-cert.gov/ncas/alerts/TA17-164A

parse_uscert_csv() {
	${GREP_CMD} "IP Watchlist" | ${CUT_CMD} -d ',' -f 1
}

update uscert_hidden_cobra $[24*60] 0 ipv4 ip \
	"https://www.us-cert.gov/sites/default/files/publications/TA-17-164A_csv.csv" \
	parse_uscert_csv \
	"attacks" \
	"Since 2009, HIDDEN COBRA actors have leveraged their capabilities to target and compromise a range of victims; some intrusions have resulted in the exfiltration of data while others have been disruptive in nature. Commercial reporting has referred to this activity as Lazarus Group and Guardians of Peace. DHS and FBI assess that HIDDEN COBRA actors will continue to use cyber operations to advance their government’s military and strategic objectives. Tools and capabilities used by HIDDEN COBRA actors include DDoS botnets, keyloggers, remote access tools (RATs), and wiper malware. Variants of malware and tools used by HIDDEN COBRA actors include Destover, Wild Positron/Duuzer and Hangman." \
	"US Cert" "https://www.us-cert.gov/ncas/alerts/TA17-164A"

# -----------------------------------------------------------------------------
# BadIPs.com

badipscom() {
	local ret= x= i=

	ipset_shall_be_run "badips"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	download_manager "badips" $[24*60] "https://www.badips.com/get/categories"
	ret=$?
	[ ! -s "${BASE_DIR}/badips.source" ] && return 0

	local categories="any $( \
		$CAT_CMD ${BASE_DIR}/badips.source |\
			$TR_CMD "[]{}," "\n\n\n\n\n" |\
			$EGREP_CMD '^"(Name|Parent)":"[a-zA-Z0-9_-]+"$' |\
			$CUT_CMD -d ':' -f 2 |\
			$CUT_CMD -d '"' -f 2 |\
			$SORT_CMD -u
		)"


	if [ ${ENABLE_ALL} -eq 1 ]
		then
		declare -A badips_excluded='([bi_dovecot-pop3_0_1d]="1" [bi_sql-injection_0_1d]="1" [bi_dovecot-pop3imap_1_7d]="1" [bi_courierpop3_2_30d]="1" [bi_bruteforce_2_30d]="1" [bi_Php-url-fopen_0_1d]="1" [bi_nginxpost_0_1d]="1" [bi_vnc_0_1d]="1" [bi_smtp_1_7d]="1" [bi_apache-w00tw00t_0_1d]="1" [bi_apache-dokuwiki_1_7d]="1" [bi_nginxpost_2_30d]="1" [bi_courierauth_1_7d]="1" [bi_w00t_0_1d]="1" [bi_ssh-auth_2_30d]="1" [bi_sql-injection_2_30d]="1" [bi_xmlrpc_1_7d]="1" [bi_pureftp_1_7d]="1" [bi_local-exim_2_30d]="1" [bi_php-cgi_0_1d]="1" [bi_cyrusauth_0_1d]="1" [bi_asterisk-sec_0_1d]="1" [bi_wp_2_30d]="1" [bi_apache-spamtrap_2_30d]="1" [bi_username-notfound_2_30d]="1" [bi_imap_1_7d]="1" [bi_assp_1_7d]="1" [bi_apacheddos_2_30d]="1" [bi_apache-wordpress_2_30d]="1" [bi_apache-overflows_2_30d]="1" [bi_nginx_1_7d]="1" [bi_dovecot-pop3_2_30d]="1" [bi_apache-php-url-fopen_1_7d]="1" [bi_apache-defensible_1_7d]="1" [bi_vsftpd_1_7d]="1" [bi_apache-wordpress_0_1d]="1" [bi_apache-overflows_0_1d]="1" [bi_ssh-auth_0_1d]="1" [bi_w00t_1_7d]="1" [bi_proxy_2_30d]="1" [bi_username-notfound_1_7d]="1" [bi_apacheddos_1_7d]="1" [bi_apache-wordpress_1_7d]="1" [bi_apache-overflows_1_7d]="1" [bi_rdp_2_30d]="1" [bi_nginx_0_1d]="1" [bi_apache-php-url-fopen_0_1d]="1" [bi_apache-defensible_0_1d]="1" [bi_Php-url-fopen_2_30d]="1" [bi_phpids_0_1d]="1" [bi_courierpop3_1_7d]="1" [bi_apache-phpmyadmin_2_30d]="1" [bi_sql_1_7d]="1" [bi_screensharingd_1_7d]="1" [bi_pop3_1_7d]="1" [bi_plesk-postfix_2_30d]="1" [bi_ssh-blocklist_2_30d]="1" [bi_phpids_2_30d]="1" [bi_nginxproxy_0_1d]="1" [bi_apache-nohome_1_7d]="1" [bi_spamdyke_1_7d]="1" [bi_sql-attack_1_7d]="1" [bi_qmail-smtp_1_7d]="1" [bi_nginx_2_30d]="1" [bi_apache-php-url-fopen_2_30d]="1" [bi_apache-defensible_2_30d]="1" [bi_vnc_2_30d]="1" [bi_apache-w00tw00t_2_30d]="1" [bi_spamdyke_2_30d]="1" [bi_proxy_0_1d]="1" [bi_local-exim_1_7d]="1" [bi_exim_2_30d]="1" [bi_apache-404_1_7d]="1" [bi_rdp_1_7d]="1" [bi_spamdyke_0_1d]="1" [bi_smtp_2_30d]="1" [bi_apache-dokuwiki_2_30d]="1" [bi_named_2_30d]="1" [bi_apache-scriddies_2_30d]="1" [bi_named_1_7d]="1" [bi_apache-scriddies_1_7d]="1" [bi_nginxpost_1_7d]="1" [bi_dns_2_30d]="1" [bi_nginxproxy_2_30d]="1" [bi_apache-modsec_2_30d]="1" [bi_Php-url-fopen_1_7d]="1" [bi_php-cgi_1_7d]="1" [bi_cyrusauth_1_7d]="1" [bi_asterisk-sec_1_7d]="1" [bi_xmlrpc_0_1d]="1" [bi_pureftp_0_1d]="1" [bi_sql-attack_2_30d]="1" [bi_qmail-smtp_2_30d]="1" [bi_squid_0_1d]="1" [bi_ddos_0_1d]="1" [bi_spam_2_30d]="1" [bi_owncloud_2_30d]="1" [bi_apache-phpmyadmin_1_7d]="1" [bi_vnc_1_7d]="1" [bi_apache-w00tw00t_1_7d]="1" [bi_apache-dokuwiki_0_1d]="1" [bi_wp_0_1d]="1" [bi_imap_2_30d]="1" [bi_assp_2_30d]="1" [bi_apache-spamtrap_0_1d]="1" [bi_wp_1_7d]="1" [bi_sshddos_2_30d]="1" [bi_apache-spamtrap_1_7d]="1" [bi_sshddos_0_1d]="1" [bi_rfi-attack_2_30d]="1" [bi_drupal_2_30d]="1" [bi_w00t_2_30d]="1" [bi_sql_2_30d]="1" [bi_screensharingd_2_30d]="1" [bi_pop3_2_30d]="1" [bi_sshddos_1_7d]="1" [bi_squid_2_30d]="1" [bi_ddos_2_30d]="1" [bi_apache-noscript_1_7d]="1" [bi_ssh-blocklist_1_7d]="1" [bi_phpids_1_7d]="1" [bi_courierpop3_0_1d]="1" [bi_xmlrpc_2_30d]="1" [bi_pureftp_2_30d]="1" [bi_dns_1_7d]="1" [bi_proxy_1_7d]="1" [bi_local-exim_0_1d]="1" [bi_apache-nohome_2_30d]="1" [bi_plesk-postfix_1_7d]="1" [bi_ssh-auth_1_7d]="1" [bi_nginxproxy_1_7d]="1" [bi_badbots_2_30d]="1" [bi_apache-nohome_0_1d]="1" [bi_apache-modsec_1_7d]="1" [bi_screensharingd_0_1d]="1" [bi_pop3_0_1d]="1" [bi_owncloud_1_7d]="1" [bi_rfi-attack_1_7d]="1" [bi_drupal_1_7d]="1" [bi_apache-404_2_30d]="1" [bi_rfi-attack_0_1d]="1" [bi_sql-injection_1_7d]="1" [bi_asterisk_1_7d]="1" [bi_dovecot-pop3_1_7d]="1" [bi_squid_1_7d]="1" [bi_ddos_1_7d]="1" [bi_ssh-ddos_1_7d]="1" [bi_php-cgi_2_30d]="1" [bi_cyrusauth_2_30d]="1" [bi_asterisk-sec_2_30d]="1" )'
		for x in ${categories}
		do
			for i in 0_1d 1_7d 2_30d
			do
				if [ -z "${badips_excluded[bi_${x}_${i}]}" ]
					then
					ipset_shall_be_run "bi_${x}_${i}"
				fi
			done
		done
	fi

	local category= file= score= age= ipset= url= info= count=0
	for category in ${categories}
	do
		#echo >&2 "CATEGORY: '${category}'"
		count=0
		# info "bi_${category}"

		for file in $(cd "${BASE_DIR}"; $LS_CMD 2>/dev/null bi_${category}_*.source)
		do
			#echo >&2 "FILE: '${file}'"
			count=$[count + 1]
			if [[ "${file}" =~ ^bi_.*_[0-9\.]+_[0-9]+[dwmy].source$ ]]
				then
				# score and age present
				i="$(echo "${file}" | $SED_CMD "s|^bi_.*_\([0-9\.]\+\)_\([0-9]\+[dwmy]\)\.source|\1;\2|g")"
				score=${i/;*/}
				age="${i/*;/}"
				ipset="bi_${category}_${score}_${age}"
				url="https://www.badips.com/get/list/${category}/${score}?age=${age}"
				info="[BadIPs.com](https://www.badips.com/) Bad IPs in category ${category} with score above ${score} and age less than ${age}"
				if [ "${file}" != "${ipset}.source" ]
					then
					ipset_warning "${file}" "parsed as '${ipset}' with category '${category}', score '${score}', age '${age}' seems invalid"
					continue
				fi

			elif [[ "${file}" =~ ^bi_.*_[0-9]+[dwmy].source$ ]]
				then
				# age present
				age="$(echo "${file}" | $SED_CMD "s|^bi_.*_\([0-9]\+[dwmy]\)\.source|\1|g")"
				score=0
				ipset="bi_${category}_${age}"
				url="https://www.badips.com/get/list/${category}/${score}?age=${age}"
				info="[BadIPs.com](https://www.badips.com/) Bad IPs in category ${category} with age less than ${age}"
				if [ "${file}" != "${ipset}.source" ]
					then
					ipset_warning "${file}" "parsed as '${ipset}' with category '${category}', score '${score}', age '${age}' seems invalid"
					continue
				fi

			elif [[ "${file}" =~ ^bi_.*_[0-9\.]+.source$ ]]
				then
				# score present
				score="$(echo "${file}" | $SED_CMD "s|^bi_.*_\([0-9\.]\+\)\.source|\1|g")"
				age=
				ipset="bi_${category}_${score}"
				url="https://www.badips.com/get/list/${category}/${score}"
				info="[BadIPs.com](https://www.badips.com/) Bad IPs in category ${category} with score above ${score}"
				if [ "${file}" != "${ipset}.source" ]
					then
					ipset_warning "${file}" "parsed as '${ipset}' with category '${category}', score '${score}', age '${age}' seems invalid"
					continue
				fi
			else
				# none present
				ipset_warning "${file}" "cannot find SCORE or AGE in filename. Use numbers."
				continue
			fi

			local freq=$[7 * 24 * 60]
			if [ ! -z "${age}" ]
				then
				case "${age}" in
					*d) age=$[${age/d/} * 1] ;;
					*w) age=$[${age/w/} * 7] ;;
					*m) age=$[${age/m/} * 30] ;;
					*y) age=$[${age/y/} * 365] ;;
					*)  age=0; ipset_warning "${ipset}" "unknown age '${age}'. Assuming 0." ;;
				esac

				[ $[age] -eq 0   ] && freq=$[7 * 24 * 60] # invalid age
				[ $[age] -gt 0   ] && freq=$[         30] # 1-2 days of age
				[ $[age] -gt 2   ] && freq=$[     6 * 60] # 3-7 days
				[ $[age] -gt 7   ] && freq=$[1 * 24 * 60] # 8-90 days
				[ $[age] -gt 90  ] && freq=$[2 * 24 * 60] # 91-180 days
				[ $[age] -gt 180 ] && freq=$[4 * 24 * 60] # 181-365 days
				[ $[age] -gt 365 ] && freq=$[7 * 24 * 60] # 366-ever days

				ipset_verbose "${ipset}" "update frequency set to ${freq} mins"
			fi

			update "${ipset}" ${freq} 0 ipv4 ip \
				"${url}" \
				remove_comments \
				"attacks" \
				"${info}" \
				"BadIPs.com" "https://www.badips.com/" \
				can_be_empty
		done

		if [ ${count} -eq 0 ]
			then
			ipset_disabled "bi_${category}_SCORE_AGE" "SCORE=X and AGE=Y[dwmy]"
		fi
	done
}

badipscom

# -----------------------------------------------------------------------------
# normshield

normshield() {
	local ret= url= x= severity=

	ipset_shall_be_run "normshield"
	case "$?" in
		0)	;;

		1)	
			return 1
			;;

		*)	return 1
			;;
	esac

	url="https://services.normshield.com/api/v1/threatfeed/downloadintel?date=$(${DATE_CMD} --date=@$(( $(${DATE_CMD} +%s) - 86400 )) +%m%d%Y)&format=csv&category=honeypotfeeds"
	download_manager "normshield" $[24*60] "${url}"
	ret=$?
	[ ! -s "${BASE_DIR}/normshield.source" ] && return 0

	local categories="$( \
		$CAT_CMD ${BASE_DIR}/normshield.source |\
			$TR_CMD -d '\r' |\
			$CUT_CMD -d ',' -f 9 |\
			$GREP_CMD -v "^category$" |\
			$SORT_CMD -u
		)"

	if [ ${ENABLE_ALL} -eq 1 ]
		then
		for x in ${categories}
		do
			for severity in all high
			do
				ipset_shall_be_run "normshield_${severity}_${x}"
			done
		done
	fi

	local category= ipset= info=
	for x in ${categories}
	do
		for severity in all high
		do
			ipset="normshield_${severity}_${x}"
			info="[NormShield.com](https://services.normshield.com/threatfeed) IPs in category ${x} with severity ${severity}"
			if [ ! -f "${BASE_DIR}/${ipset}.source" ]
				then
				ipset_disabled "${ipset}"
				continue
			fi

			if [ "${severity}" = "high" ]
				then
				${CAT_CMD} "${BASE_DIR}/normshield.source" |\
					${TR_CMD} -d '\r' |\
					${CUT_CMD} -d ',' -f 2,5,9 |\
					${GREP_CMD} ",${severity},${x}$" |\
					${CUT_CMD} -d ',' -f 1 >"${BASE_DIR}/${ipset}.source"
			else
				${CAT_CMD} "${BASE_DIR}/normshield.source" |\
					${TR_CMD} -d '\r' |\
					${CUT_CMD} -d ',' -f 2,9 |\
					${GREP_CMD} ",${x}$" |\
					${CUT_CMD} -d ',' -f 1 >"${BASE_DIR}/${ipset}.source"
			fi

			case "${x}" in
				suspicious) category="abuse" ;;
				wannacry|wormscan) category="malware" ;;
				spam) category="spam" ;;
				*) category="attacks" ;;
			esac

			update "${ipset}" "$[12*60]" 0 ipv4 ip \
				"" \
				${CAT_CMD} \
				"${category}" \
				"${info}" \
				"NormShield.com" "https://services.normshield.com/threatfeed" \
				can_be_empty
		done
	done
}

normshield


# -----------------------------------------------------------------------------
# blueliv

blueliv_parser() {
	if [ -z "${JQ_CMD}" ]
	then
		error "command 'jq' is not installed"
		return 1
	fi

	${JQ_CMD} '[.crimeServers[] | {ip:.ip}]' | ${GREP_CMD} '"ip":' |\
		${CUT_CMD} -d ':' -f 2 |\
		${CUT_CMD} -d '"' -f 2 |\
		${GREP_CMD} -v null
}

# check if it is enabled
if [ -z "${BLUELIV_API_KEY}" ]
	then
	for x in blueliv_crimeserver_online blueliv_crimeserver_recent blueliv_crimeserver_last
	do
		if [ -f "${BASE_DIR}/${x}.source" ]
			then
			ipset_error ${x} "Please set BLUELIV_API_KEY='...' in ${CONFIG_FILE}"
		else
			ipset_disabled ${x}
		fi
	done
else
	update blueliv_crimeserver_online $[24 * 60] 0 ipv4 ip \
		"https://freeapi.blueliv.com/v1/crimeserver/online" \
		blueliv_parser \
		"attacks" "[blueliv.com](https://www.blueliv.com/) Online Cybercrime IPs, in all categories: BACKDOOR, C_AND_C, EXPLOIT_KIT, MALWARE and PHISHING (to download the source data you need an API key from blueliv.com)" \
		"blueliv.com" "https://www.blueliv.com/" \
		dont_redistribute \
		dont_enable_with_all \
		downloader_options "-H 'Authorization: bearer ${BLUELIV_API_KEY}'"

	update blueliv_crimeserver_recent $[24 * 60] 0 ipv4 ip \
		"https://freeapi.blueliv.com/v1/crimeserver/recent" \
		blueliv_parser \
		"attacks" "[blueliv.com](https://www.blueliv.com/) Recent Cybercrime IPs, in all categories: BACKDOOR, C_AND_C, EXPLOIT_KIT, MALWARE and PHISHING (to download the source data you need an API key from blueliv.com)" \
		"blueliv.com" "https://www.blueliv.com/" \
		dont_redistribute \
		dont_enable_with_all \
		downloader_options "-H 'Authorization: bearer ${BLUELIV_API_KEY}'"

	update blueliv_crimeserver_last $[6 * 60] "$[24*60] $[48*60] $[7*24*60] $[30*24*60]" ipv4 ip \
		"https://freeapi.blueliv.com/v1/crimeserver/last" \
		blueliv_parser \
		"attacks" "[blueliv.com](https://www.blueliv.com/) Last 6 hours Cybercrime IPs, in all categories: BACKDOOR, C_AND_C, EXPLOIT_KIT, MALWARE and PHISHING (to download the source data you need an API key from blueliv.com)" \
		"blueliv.com" "https://www.blueliv.com/" \
		dont_redistribute \
		dont_enable_with_all \
		downloader_options "-H 'Authorization: bearer ${BLUELIV_API_KEY}'"
fi

# -----------------------------------------------------------------------------
# IBM X-Force
# unfortunately a paid service

$CAT_CMD >/dev/null <<"XFORCE_COMMENTED"
declare -A xforce=(
	[spam]="Spam"
	[anonymous]="Anonymisation Services"
	[scanners]="Scanning IPs"
	[dynamic]="Dynamic IPs"
	[malware]="Malware"
	[bots]="Bots"
	[c2]="Botnet Command and Control Server"
)

declare -A xforce_categories=(
	[spam]="spam"
	[anonymous]="anonymizers"
	[scanners]="reputation"
	[dynamic]="reputation"
	[malware]="malware"
	[bots]="malware"
	[c2]="malware"
)

declare -a xforce_days=(1 2 7 30)

xforce_parser() {
	echo >&2 "ERROR: xforce is not implemented yet."
	return 1
}

if [ ! -z "${XFORCE_API_KEY}" -a ! -z "${XFORCE_API_PASSWORD}" ]
	then
	for x in "${!xforce[@]}"
	do
		for d in "${xforce_days[@]}"
		do
			if [ -f "${BASE_DIR}/${x}_${d}d.source" ]
				then
				ipset_error ${x}_${d}d "Please set XFORCE_API_KEY='...' and XFORCE_API_PASSWORD='...' in ${CONFIG_FILE}"
			else
				ipset_disabled ${x}_${d}d
			fi
		done
	done
else
	now=$($DATE_CMD +%s)
	for x in "${!xforce[@]}"
	do
		for d in "${xforce_days[@]}"
		do
			update ${x}_${d}d $[60] "" ipv4 ip \
				"https://api.xforce.ibmcloud.com/ipr?category=$(echo "${xforce[${x}]}" | $SED_CMD "s| |%20|g")&startDate=$($DATE_CMD +"%Y-%m-%dT%H%%3A%M%%3A%SZ&limit=10000" --date=@$(( now - (d * 86400) )))" \
				xforce_parser \
				"${xforce_categories[${x}]}" "[IBM X-Force Exchange](https://exchange.xforce.ibmcloud.com/) - ${xforce[${x}]} detected in the last ${d} day(s)." \
				"IBM X-Force Exchange" "https://exchange.xforce.ibmcloud.com/" \
				dont_redistribute \
				dont_enable_with_all \
				downloader_options "-H 'Accept: application/json' -u '${XFORCE_API_KEY}:${XFORCE_API_PASSWORD}'"
		done
	done
fi
XFORCE_COMMENTED

# -----------------------------------------------------------------------------
# X-Force public info

xforce_taxii_parser() {
	${GREP_CMD} -oP "${IP4_MATCH}"
}

if [ ! -z "${XFORCE_API_KEY}" -a ! -z "${XFORCE_API_PASSWORD}" ]
	then

	update xforce_bccs $[24 * 60] 0 ipv4 ip \
		"https://api.xforce.ibmcloud.com/taxii" \
		xforce_taxii_parser \
		"malware" \
		"[IBM X-Force Exchange](https://exchange.xforce.ibmcloud.com/) Botnet Command and Control Servers" \
		"IBM X-Force Exchange" "https://exchange.xforce.ibmcloud.com/" \
		downloader_options "-X POST -H 'Content-Type: application/xml' -H 'Accept: application/xml' -u '${XFORCE_API_KEY}:${XFORCE_API_PASSWORD}' -d '
<taxii_11:Poll_Request xmlns:taxii_11=\"http://taxii.mitre.org/messages/taxii_xml_binding-1.1\" collection_name=\"xfe.collections.public\">
  <taxii_11:Poll_Parameters allow_asynch=\"false\">
    <taxii_11:Query format_id=\"urn:taxii.mitre.org:query:default:1.0\">
      <tdq:Default_Query targeting_expression_id=\"urn:stix.mitre.org:xml:1.1.1\">
        <tdq:Criteria operator=\"AND\">
          <tdq:Criterion negate=\"false\">
            <tdq:Target> **/@id</tdq:Target>
            <tdq:Test capability_id=\"urn:taxii.mitre.org:query:capability:core-1\" relationshp=\"equals\">
              <tdq:Parameter name=\"match_type\">case_insensitive_string</tdq:Parameter>
              <tdq:Parameter name=\"value\">7ac6c4578facafa0de50b72e7bf8f8c4</tdq:Parameter>
            </tdq:Test>
          </tdq:Criterion>
        </tdq:Criteria>
      </tdq:Default_Query>
    </taxii_11:Query>
  </taxii_11:Poll_Parameters>
</taxii_11:Poll_Request>
'"
fi


# -----------------------------------------------------------------------------
# SORBS test

# this is a test - it does not work without another script that rsyncs files from sorbs.net
# we don't have yet the license to add this script here
# (the script is ours, but sorbs.net is very sceptical about this)

update sorbs_dul 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" "[Sorbs.net](https://www.sorbs.net/) Dynamic IP Addresses." \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

#update sorbs_socks 1 0 ipv4 both "" \
#	$CAT_CMD \
#	"anonymizers" \
#	"[Sorbs.net](https://www.sorbs.net/) List of open SOCKS proxy servers." \
#	"Sorbs.net" "https://www.sorbs.net/" \
#	dont_redistribute \
#	dont_enable_with_all

#update sorbs_http 1 0 ipv4 both "" \
#	$CAT_CMD \
#	"anonymizers" \
#	"[Sorbs.net](https://www.sorbs.net/) List of open HTTP proxies." \
#	"Sorbs.net" "https://www.sorbs.net/" \
#	dont_redistribute \
#	dont_enable_with_all

#update sorbs_misc 1 0 ipv4 both "" \
#	$CAT_CMD \
#	"anonymizers" \
#	"[Sorbs.net](https://www.sorbs.net/) List of open proxy servers (not listed in HTTP or SOCKS)." \
#	"Sorbs.net" "https://www.sorbs.net/" \
#	dont_redistribute \
#	dont_enable_with_all

# all the above are here:
update sorbs_anonymizers 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) List of open HTTP and SOCKS proxies." \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

update sorbs_zombie 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) List of networks hijacked from their original owners, some of which have already used for spamming." \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

update sorbs_smtp 1 0 ipv4 both "" \
	$CAT_CMD "spam" "[Sorbs.net](https://www.sorbs.net/) List of SMTP Open Relays." \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

# this is HUGE !!!
#update sorbs_spam 1 0 ipv4 both "" \
#	remove_comments \
#	"spam" \
#	"[Sorbs.net](https://www.sorbs.net/) List of hosts that have been noted as sending spam/UCE/UBE at any time, and not subsequently resolving the matter and/or requesting a delisting. (Includes both sorbs_old_spam and sorbs_escalations)." \
#	"Sorbs.net" "https://www.sorbs.net/" \
#	dont_redistribute \
#	dont_enable_with_all

#update sorbs_old_spam 1 0 ipv4 both "" \
#	remove_comments \
#	"spam" \
#	"[Sorbs.net](https://www.sorbs.net/) List of hosts that have been noted as sending spam/UCE/UBE within the last year. (includes sorbs_recent_spam)." \
#	"Sorbs.net" "https://www.sorbs.net/" \
#	dont_redistribute \
#	dont_enable_with_all

update sorbs_new_spam 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) List of hosts that have been noted as sending spam/UCE/UBE within the last 48 hours" \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

update sorbs_recent_spam 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) List of hosts that have been noted as sending spam/UCE/UBE within the last 28 days (includes sorbs_new_spam)" \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

update sorbs_web 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) List of IPs which have spammer abusable vulnerabilities (e.g. FormMail scripts)" \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

update sorbs_escalations 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) Netblocks of spam supporting service providers, including those who provide websites, DNS or drop boxes for a spammer. Spam supporters are added on a 'third strike and you are out' basis, where the third spam will cause the supporter to be added to the list." \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

update sorbs_noserver 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) IP addresses and netblocks of where system administrators and ISPs owning the network have indicated that servers should not be present." \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all

update sorbs_block 1 0 ipv4 both "" \
	$CAT_CMD \
	"spam" \
	"[Sorbs.net](https://www.sorbs.net/) List of hosts demanding that they never be tested by SORBS." \
	"Sorbs.net" "https://www.sorbs.net/" \
	dont_redistribute \
	dont_enable_with_all


# -----------------------------------------------------------------------------
# DroneBL.org lists

update dronebl_anonymizers 1 0 ipv4 both "" \
	$CAT_CMD \
	"anonymizers" \
	"[DroneBL.org](https://dronebl.org) List of open proxies. It includes IPs which DroneBL categorizes as SOCKS proxies (8), HTTP proxies (9), web page proxies (11), WinGate proxies (14), proxy chains (10)." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_irc_drones 1 0 ipv4 both "" \
	$CAT_CMD \
	"abuse" \
	"[DroneBL.org](https://dronebl.org) List of IRC spam drones (litmus/sdbot/fyle). It includes IPs for which DroneBL responds with 3." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_worms_bots 1 0 ipv4 both "" \
	$CAT_CMD \
	"malware" \
	"[DroneBL.org](https://dronebl.org) IPs of unknown worms or spambots. It includes IPs for which DroneBL responds with 6" \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_ddos_drones 1 0 ipv4 both "" \
	$CAT_CMD \
	"attacks" \
	"[DroneBL.org](https://dronebl.org) IPs of DDoS drones. It includes IPs for which DroneBL responds with 7." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_compromised 1 0 ipv4 both "" \
	$CAT_CMD \
	"attacks" \
	"[DroneBL.org](https://dronebl.org) IPs of compromised routers / gateways. It includes IPs for which DroneBL responds with 15 (BOPM detected)." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_autorooting_worms 1 0 ipv4 both "" \
	$CAT_CMD \
	"attacks" \
	"[DroneBL.org](https://dronebl.org) IPs of autorooting worms. It includes IPs for which DroneBL responds with 16. These are usually SSH bruteforce attacks." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_auto_botnets 1 0 ipv4 both "" \
	$CAT_CMD \
	"reputation" \
	"[DroneBL.org](https://dronebl.org) IPs of automatically detected botnets. It includes IPs for which DroneBL responds with 17." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_dns_mx_on_irc 1 0 ipv4 both "" \
	$CAT_CMD \
	"reputation" \
	"[DroneBL.org](https://dronebl.org) List of IPs of DNS / MX hostname detected on IRC. It includes IPs for which DroneBL responds with 18." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all

update dronebl_unknown 1 0 ipv4 both "" \
	$CAT_CMD \
	"reputation" \
	"[DroneBL.org](https://dronebl.org) List of IPs of uncategorized threats. It includes IPs for which DroneBL responds with 255." \
	"DroneBL.org" "https://dronebl.org" \
	dont_redistribute \
	dont_enable_with_all


# -----------------------------------------------------------------------------
# FireHOL lists

merge firehol_level1 ipv4 both \
	"attacks" \
	"A firewall blacklist composed from IP lists, providing maximum protection with minimum false positives. Suitable for basic protection on all internet facing servers, routers and firewalls." \
	"FireHOL" "http://iplists.firehol.org/" \
	bambenek_c2 \
	dshield \
	feodo \
	fullbogons \
	spamhaus_drop \
	spamhaus_edrop \
	sslbl \
	zeus_badips \
	ransomware_rw \

merge firehol_level2 ipv4 both \
	"attacks" \
	"An ipset made from blocklists that track attacks, during about the last 48 hours." \
	"FireHOL" "http://iplists.firehol.org/" \
	blocklist_de \
	dshield_1d \
	greensnow

merge firehol_level3 ipv4 both \
	"attacks" \
	"An ipset made from blocklists that track attacks, spyware, viruses. It includes IPs than have been reported or detected in the last 30 days." \
	"FireHOL" "http://iplists.firehol.org/" \
	bruteforceblocker \
	ciarmy \
	dshield_30d \
	dshield_top_1000 \
	malc0de \
	maxmind_proxy_fraud \
	myip \
	shunlist \
	snort_ipfilter \
	sslbl_aggressive \
	talosintel_ipfilter \
	zeus \
	vxvault \

merge firehol_level4 ipv4 both \
	"attacks" \
	"An ipset made from blocklists that track attacks, but may include a large number of false positives." \
	"FireHOL" "http://iplists.firehol.org/" \
	cleanmx_viruses \
	blocklist_net_ua \
	botscout_30d \
	cruzit_web_attacks \
	cybercrime \
	haley_ssh \
	iblocklist_hijacked \
	iblocklist_spyware \
	iblocklist_webexploit \
	ipblacklistcloud_top \
	iw_wormlist \
	malwaredomainlist \

merge firehol_abusers_1d ipv4 both \
	"abuse" \
	"An ipset made from blocklists that track abusers in the last 24 hours." \
	"FireHOL" "http://iplists.firehol.org/" \
	botscout_1d \
	cleantalk_new_1d \
	cleantalk_updated_1d \
	php_commenters_1d \
	php_dictionary_1d \
	php_harvesters_1d \
	php_spammers_1d \
	stopforumspam_1d \

merge firehol_abusers_30d ipv4 both \
	"abuse" \
	"An ipset made from blocklists that track abusers in the last 30 days." \
	"FireHOL" "http://iplists.firehol.org/" \
	cleantalk_new_30d \
	cleantalk_updated_30d \
	php_commenters_30d \
	php_dictionary_30d \
	php_harvesters_30d \
	php_spammers_30d \
	stopforumspam \
	sblam \

merge firehol_webserver ipv4 both \
	"attacks" \
	"A web server IP blacklist made from blocklists that track IPs that should never be used by your web users. (This list includes IPs that are servers hosting malware, bots, etc or users having a long criminal history. This list is to be used on top of firehol_level1, firehol_level2, firehol_level3 and possibly firehol_proxies or firehol_anonymous)." \
	"FireHOL" "http://iplists.firehol.org/" \
	maxmind_proxy_fraud \
	myip \
	pushing_inertia_blocklist \
	stopforumspam_toxic \

merge firehol_proxies ipv4 both \
	"anonymizers" \
	"An ipset made from all sources that track open proxies. It includes IPs reported or detected in the last 30 days." \
	"FireHOL" "http://iplists.firehol.org/" \
	iblocklist_proxies \
	maxmind_proxy_fraud \
	ip2proxy_px1lite \
	proxylists_30d \
	proxyrss_30d proxz_30d \
	ri_connect_proxies_30d \
	ri_web_proxies_30d \
	socks_proxy_30d \
	sslproxies_30d \
	xroxy_30d \

merge firehol_anonymous ipv4 both \
	"anonymizers" \
	"An ipset that includes all the anonymizing IPs of the world." \
	"FireHOL" "http://iplists.firehol.org/" \
	anonymous \
	bm_tor \
	dm_tor \
	firehol_proxies \
	tor_exits \

merge firehol_webclient ipv4 both \
	"malware" \
	"An IP blacklist made from blocklists that track IPs that a web client should never talk to. This list is to be used on top of firehol_level1." \
	"FireHOL" "http://iplists.firehol.org/" \
	ransomware_online \
	sslbl_aggressive \
	cybercrime \
	dyndns_ponmocup \
	maxmind_proxy_fraud \


# -----------------------------------------------------------------------------
# TODO
#
# add sets
# - https://github.com/certtools/intelmq/blob/master/intelmq/bots/BOTS
#
# - http://security-research.dyndns.org/pub/botnet/ponmocup/ponmocup-finder/ponmocup-infected-domains-latest.txt - sent email to toms.security.stuff@gmail.com
# - http://jeroen.steeman.org/FS-PlainText - sent email to jeroen@steeman.org

# - http://www.uceprotect.net/en/index.php?m=6&s=10
# - http://www.cidr-report.org/bogons/freespace-prefix6.txt
# - https://github.com/mlsecproject/combine/issues/25
#
# - spam: http://www.reputationauthority.org/toptens.php
# - spam: https://www.juniper.net/security/auto/spam/
# - spam: http://toastedspam.com/deny
# - spam: http://rss.uribl.com/reports/7d/dns_a.html
# - spam: http://spamcop.net/w3m?action=map;net=cmaxcnt;mask=65535;sort=spamcnt;format=text
# - https://gist.github.com/BBcan177/3cbd01b5b39bb3ce216a
# - https://github.com/rshipp/awesome-malware-analysis

# obsolete - these do not seem to be updated any more
# - http://www.cyber-ta.org/releases/malware/SOURCES/Attacker.Cumulative.Summary
# - http://www.cyber-ta.org/releases/malware/SOURCES/CandC.Cumulative.Summary
# - https://vmx.yourcmc.ru/BAD_HOSTS.IP4
# - http://www.geopsy.org/blacklist.html
# - http://www.malwaregroup.com/ipaddresses/malicious

# user specific features
# - allow the user to request an email if a set increases by a percentage or number of unique IPs
# - allow the user to request an email if a set matches more than X entries of one or more other set

# intended use    : 20:firewall_block_all 10:firewall_block_service 02:[reputation_generic] 01:[reputation_specific] 00:[antispam] 
# false positives : 3:none 2:rare 1:some 0:[common]
# poisoning       : 0:[not_checked] 1:reactive 2:predictive 3:not_possible
# grade           : 0:[personal] 1:community 2:commercial 3:carrier / service_provider
# protection      : 0:[both] 1:inbound 2:outbound
# license         : 


# -----------------------------------------------------------------------------
# load all third party ipsets

cd "${RUN_DIR}" || continue
for supplied_ipsets_dir in "${ADMIN_SUPPLIED_IPSETS}" "${DISTRIBUTION_SUPPLIED_IPSETS}" "${USER_SUPPLIED_IPSETS}"
do
	[ -z "${supplied_ipsets_dir}" ] && continue

	if [ ! -d "${supplied_ipsets_dir}" ]
		then
		verbose "Supplied ipsets directory '${supplied_ipsets_dir}' does not exist. Ignoring it."
		continue
	fi

	verbose "Loading ipset definitions from: '${supplied_ipsets_dir}'"
	for supplied_ipset_file in $($LS_CMD "${supplied_ipsets_dir}"/*.conf 2>/dev/null)
	do
		verbose "Loading ipset definition file: '${supplied_ipset_file}'"
		
		cd "${RUN_DIR}" || continue
		source "${supplied_ipset_file}"

		if [ $? -ne 0 ]
			then
			error "run of '${supplied_ipset_file}' reports failure"
		else
			verbose "run of '${supplied_ipset_file}' completed"
		fi
	done
done

# -----------------------------------------------------------------------------
# update the web site, if we have to (does nothing if not enabled)
update_web

# copy the ipset files to web dir (does nothing if not enabled)
copy_ipsets_to_web

# commit changes to git (does nothing if not enabled)
commit_to_git

# let the cleanup function exit with success
PROGRAM_COMPLETED=1