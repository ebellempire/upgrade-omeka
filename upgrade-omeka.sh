#!/usr/bin/env bash
#
# upgrade-omeka.sh
#
# Upgrades Omeka Classic installations to the latest release, or to a release zip on disk. Each site is checked, its database tables and core files are backed up, the new core is swapped in, and Omeka's database migrations are run from the command line.
#
#   bash upgrade-omeka.sh path/to/omeka
#   bash upgrade-omeka.sh path/to/omeka another/path/to/omeka
#   bash upgrade-omeka.sh -c path/to/omeka # check only (--check): report each site's status, change nothing
#   bash upgrade-omeka.sh -n path/to/omeka # dry run (--dry-run): show the upgrade plan, change nothing
#   bash upgrade-omeka.sh --local=path/to/omeka-3.2.2.zip path/to/omeka # or -l path/to/omeka-3.2.2.zip
#
# Release: by default the latest GitHub release of omeka/Omeka is downloaded once per run and checked against the SHA-256 digest GitHub publishes for the asset. --local uses a zip already on disk, for hosts that block outgoing requests. It is checked against --sha256 if given, else against GitHub's digest if GitHub can be reached, else used with a warning.
#
# Swap: the core entries (everything in the release except db.ini, .htaccess, files/, plugins/ and themes/) are moved into the site's backup folder and the new ones are moved into place. A move is an instant, atomic rename only within one filesystem, so the backup folder must be on the same filesystem as the sites (see -d). application/config/config.ini and application/logs/ are carried into the new core. db.ini, .htaccess, files/, .user.ini and anything else in the site root that is not part of the release are never touched. Inside admin/, application/ and install/, files the release doesn't have stay with the old core in the backup; the summary names any server config files among them (a per-folder php.ini, the admin/.htaccess cPanel's Directory Privacy writes) so they can be copied back.
#
# Database: tables with the site's prefix are dumped with mysqldump before anything changes. The credentials come from db.ini and are passed in a temporary 0600 option file, so the password never appears in the process list. Migrations run right after the swap, because until they do Omeka blocks the public site and serves /admin/upgrade without a login. If the new code can't start, the old core is put back. If a migration fails, the dump is restored too.
#
# Installatron: a site whose path appears in an Installatron data file is skipped unless -m is given. Installatron may not notice a manual upgrade, and its auto-update could later lay an older packaged release over this one. Data files are only read, never changed. They are searched for in ~/.appdata and in the .appdata folder of the user who owns the site (so a root run on a VPS still finds each account's data); set INSTALLATRON_DATA to search somewhere else instead.
#
# Bundled add-ons: bundled plugins (Exhibit Builder, Simple Pages, COinS) are replaced when the release has a newer version. Omeka keeps a replaced plugin inactive until Upgrade is clicked on the admin Plugins page, so the summary says to log in. Bundled themes are often edited in place, so they are only reported unless -t is given.

SUMMARY=''
NOW=$(date +"%Y%m%d-%H%M%S")
SCRIPT_LOCATION=$(pwd)
ME="${0##*/}"
WRAPPER=/usr/local/bin/php
RELEASES_API=https://api.github.com/repos/omeka/Omeka/releases
BACKUP_ROOT=~/omeka_upgrade_backups
INSTALLATRON_DATA=${INSTALLATRON_DATA:-}
CHECK_ONLY=0
DRY_RUN=0
ALLOW_MANAGED=0
UPDATE_THEMES=0
ALLOW_MAJOR=0
OVERRIDE=''
LOCAL_ZIP=''
LOCAL_SHA256=''
FAILED=0
LOCKS=()

# Never moved or replaced: site-specific files and folders that ship in the release zip.
PRESERVE=(db.ini .htaccess files plugins themes)

RED='\E[0;31m'
GREEN='\E[0;32m'
YELLOW='\E[0;33m'
CYAN='\E[0;36m'
NOCOLOR='\E[0m'
BOLD=$(tput bold 2>/dev/null)
NORMAL=$(tput sgr0 2>/dev/null)

usage() {
	echo -e "Include at least one path to an existing Omeka installation. Here's an example: \n${YELLOW}bash ${ME} path/to/omeka1 path/to/omeka2${NOCOLOR}"
	echo -e "Options (before the paths; long options take a value after = or a space):
  -c, --check              check only: report each site's status, change nothing
  -n, --dry-run            dry run: show what would be upgraded, change nothing
  -m, --managed            also upgrade sites managed by Installatron
  -t, --themes             also update bundled themes (berlin, default, seasons) when the release has newer versions
  -j, --major              allow upgrades across a major version (e.g. 2.x to 3.x)
  -d, --backup-dir DIR     backup folder, on the same filesystem as the sites (default ${BACKUP_ROOT})
  -b, --php PHP_BIN        skip PHP detection and use this binary (absolute path or ea-phpNN)
  -l, --local ZIP          use this release zip instead of downloading
  -s, --sha256 HASH        expected SHA-256 of the --local zip
  -h, --help               show this help"
}

# add_summary COLOR MARK SITE DETAIL... (also appends the site's WARNINGS)
add_summary() {
	local COLOR=$1 MARK=$2 SITE=$3 LINE
	shift 3
	SUMMARY+="\n${COLOR}${BOLD}${MARK} ${SITE}:${NORMAL}${NOCOLOR}\n"
	for LINE in "$@"; do
		SUMMARY+="  ➡ ${LINE}\n"
	done
	for LINE in "${WARNINGS[@]}"; do
		SUMMARY+="  ➡ ${YELLOW}Warning: ${LINE}${NOCOLOR}\n"
	done
}

site_error() {
	echo -e "${RED}█ ERROR: $2${NOCOLOR}"
	add_summary "$RED" "✗" "$1" "${@:2}"
	FAILED=1
}

site_skip() {
	echo -e "${YELLOW}█ Skipping: $2${NOCOLOR}"
	add_summary "$YELLOW" "✗" "$1" "${@:2}"
}

fatal() {
	echo -e "${RED}█ ERROR: $1${NOCOLOR}"
	exit "${2:-1}"
}

# join_list ITEM...: print "a", "a and b" or "a, b and c"
join_list() {
	case $# in
		0) ;;
		1) printf '%s' "$1" ;;
		*) printf '%s, ' "${@:1:$#-1}" | sed 's/, $//'; printf ' and %s' "${!#}" ;;
	esac
}

# version_lt A B: true if version A sorts before version B
version_lt() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

# omeka_version FILE: print the OMEKA_VERSION defined in a bootstrap.php
omeka_version() {
	sed -nE "s/^[[:space:]]*define\([[:space:]]*['\"]OMEKA_VERSION['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" "$1" 2>/dev/null | head -n 1
}

# ini_version FILE: print the version= value of a plugin.ini or theme.ini
ini_version() {
	sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$1" 2>/dev/null | head -n 1
}

# Omeka's own check (_checkCliPath) only wants exit 0 and a first line like "PHP 8.2.1", so it accepts php-cgi. Also require the CLI SAPI. Prints version.
cli_version() {
	local OUT RE='^PHP ([0-9][0-9.]*) \(cli\)'
	OUT=$("$1" -v 2>/dev/null) || return 1
	[[ ${OUT%%$'\n'*} =~ $RE ]] || return 1
	echo "${BASH_REMATCH[1]}"
}

# detect_php ROOT: sets PHP_BIN (and PHP_PKG on cPanel), or ERR and returns 1. Same detection as set-omeka-php-path.sh: on cPanel, /usr/local/bin/php run from inside the site picks that vhost's PHP version.
detect_php() {
	local ROOT=$1 REAL STDERR RE='^/opt/cpanel/(ea-php[0-9]+)/root/usr/bin/php$'
	PHP_BIN='' PHP_PKG=''
	REAL=$(cd -- "$ROOT" && "$DETECT_PHP" -n -r 'echo PHP_BINARY;' 2>"$WORK_DIR/stderr")
	STDERR=$(head -n 1 "$WORK_DIR/stderr")
	if [[ $REAL != /* ]]; then
		ERR="Could not run ${DETECT_PHP} in this directory${STDERR:+: ${STDERR}}"
		return 1
	fi
	if [[ $STDERR == *'using default'* ]]; then
		ERR="${STDERR} (install that version's php-cli package, or use -b)"
		return 1
	fi
	[ -z "$STDERR" ] || WARNINGS+=("${DETECT_PHP}: ${STDERR}")
	PHP_BIN=$REAL
	if [[ $REAL =~ $RE ]]; then
		PHP_PKG=${BASH_REMATCH[1]}
		if [ -x "/usr/local/bin/${PHP_PKG}" ]; then PHP_BIN=/usr/local/bin/${PHP_PKG}; fi
	fi
	return 0
}

# ere_escape STRING: escape a literal string for grep -E
ere_escape() {
	printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'
}

# installatron_record ROOT LOGICAL_ROOT: sets IT_FILE (and IT_VERSION, IT_AUTOUP when they can be read) if an Installatron data file names this exact path. The data file format isn't documented, so the version and auto-update values are read loosely and reported as found.
installatron_record() {
	local P PATTERN OWNER_HOME DIRS=()
	IT_FILE='' IT_VERSION='' IT_AUTOUP=''
	if [ -n "$INSTALLATRON_DATA" ]; then
		DIRS=("$INSTALLATRON_DATA")
	else
		[ -d ~/.appdata ] && DIRS+=(~/.appdata)
		OWNER_HOME=$(getent passwd "$(stat -c %u "$1")" | cut -d : -f 6)
		if [ -n "$OWNER_HOME" ] && [ -d "${OWNER_HOME}/.appdata" ] && [ "${OWNER_HOME}/.appdata" -ef ~/.appdata ]; then OWNER_HOME=''; fi
		[ -n "$OWNER_HOME" ] && [ -d "${OWNER_HOME}/.appdata" ] && DIRS+=("${OWNER_HOME}/.appdata")
	fi
	[ "${#DIRS[@]}" -gt 0 ] || return 1
	for P in "$1" "$2"; do
		PATTERN="(^|[^[:alnum:]_./-])$(ere_escape "$P")/?([^[:alnum:]_./-]|$)"
		IT_FILE=$(grep -rlIE -- "$PATTERN" "${DIRS[@]}" 2>/dev/null | head -n 1)
		[ -n "$IT_FILE" ] && break
	done
	[ -n "$IT_FILE" ] || return 1
	IT_VERSION=$(grep -m 1 -oE '(^|[^[:alnum:]_])version"?[[:space:]]*[=:][[:space:]]*"?[0-9][0-9.]*' "$IT_FILE" | grep -oE '[0-9][0-9.]*$')
	IT_AUTOUP=$(grep -m 1 -oiE 'auto_?up[a-z_]*"?[[:space:]]*[=:][[:space:]]*"?[[:alnum:]]+' "$IT_FILE" | sed -E 's/.*[=:][[:space:]]*"?//')
	return 0
}

# read_db ROOT: sets DB_HOST DB_USER DB_PASS DB_NAME DB_PREFIX DB_PORT from db.ini, parsed by PHP the way Omeka parses it
read_db() {
	local FIELDS=()
	# shellcheck disable=SC2016  # PHP code, not shell
	"$PHP_BIN" -n -r '
		$c = @parse_ini_file($argv[1], true);
		if (!$c || !isset($c["database"])) exit(2);
		foreach (["host", "username", "password", "dbname", "prefix", "port"] as $k) {
			$v = isset($c["database"][$k]) ? (string) $c["database"][$k] : "";
			if (strpos($v, "\0") !== false || strpos($v, "\n") !== false) exit(3);
			echo $v, "\0";
		}
	' "$1/db.ini" >"$WORK_DIR/db" 2>/dev/null || return 1
	mapfile -d '' -t FIELDS <"$WORK_DIR/db"
	DB_HOST=${FIELDS[0]} DB_USER=${FIELDS[1]} DB_PASS=${FIELDS[2]} DB_NAME=${FIELDS[3]} DB_PREFIX=${FIELDS[4]} DB_PORT=${FIELDS[5]}
	[ -n "$DB_NAME" ] && [ -n "$DB_USER" ]
}

# write_cnf FILE: client option file for mysql/mysqldump; values are double-quoted with \ and " escaped
write_cnf() {
	local K V
	(
		umask 077
		echo "[client]"
		for K in host user password port; do
			case $K in
				host) V=$DB_HOST ;; user) V=$DB_USER ;; password) V=$DB_PASS ;; port) V=$DB_PORT ;;
			esac
			[ -n "$V" ] || continue
			V=${V//\\/\\\\}
			V=${V//\"/\\\"}
			echo "${K}=\"${V}\""
		done
		echo "default-character-set=utf8mb4"
	) >"$1"
}

# db_query SQL: run a query against the site's database, tab-separated output without headers
db_query() {
	"$MYSQL" --defaults-extra-file="$CNF" -N -B -e "$1" "$DB_NAME" 2>"$WORK_DIR/dberr"
}

# The LIKE pattern for the site's table prefix (_ and % escaped)
prefix_like() {
	local P=${DB_PREFIX//\\/\\\\}
	P=${P//_/\\_}
	P=${P//%/\\%}
	echo "${P}%"
}

# preflight SITE: read-only checks shared by every mode. Sets ROOT, INSTALLED, STATE (upgrade, current, newer, major), MANAGED, CHECKS (report lines) and PROBLEMS (anything that blocks an upgrade).
preflight() {
	local SITE=$1 LOGICAL ENTRY MIN_PHP DB_KB FREE_KB NEED_KB TABLE_COUNT
	CHECKS=() PROBLEMS=() MANAGED=0 STATE=''
	ROOT=$(cd -- "$SITE" && pwd -P) || { PROBLEMS+=("Could not enter ${SITE}"); return; }
	LOGICAL=$(cd -- "$SITE" && pwd -L)
	SLUG=${ROOT#"$HOME"/}
	SLUG=${SLUG//\//_}
	INSTALLED=$(omeka_version "${ROOT}/bootstrap.php")
	[ -n "$INSTALLED" ] || { PROBLEMS+=("Could not read OMEKA_VERSION from bootstrap.php"); return; }

	if [ "$INSTALLED" = "$TARGET" ]; then
		STATE=current
		CHECKS+=("Omeka ${INSTALLED} (up to date)")
	elif version_lt "$TARGET" "$INSTALLED"; then
		STATE=newer
		CHECKS+=("Omeka ${INSTALLED} is newer than the target release ${TARGET}")
	elif [ "${INSTALLED%%.*}" != "${TARGET%%.*}" ]; then
		STATE=major
		CHECKS+=("Omeka ${INSTALLED} → ${TARGET} crosses a major version$([ "$ALLOW_MAJOR" = 1 ] && echo ' (allowed by -j)' || echo '; rerun with -j to allow it')")
	else
		STATE=upgrade
		CHECKS+=("Omeka ${INSTALLED} → ${TARGET} available")
	fi

	if installatron_record "$ROOT" "$LOGICAL"; then
		MANAGED=1
		CHECKS+=("Managed by Installatron (data file ${IT_FILE}; recorded version: ${IT_VERSION:-unknown}; auto-update setting: ${IT_AUTOUP:-unknown})")
		if [ -n "$IT_VERSION" ] && [ "$IT_VERSION" != "$INSTALLED" ]; then
			WARNINGS+=("Installatron records version ${IT_VERSION} but the files are ${INSTALLED}; update the install's details in Installatron")
		fi
	else
		CHECKS+=("Not managed by Installatron")
	fi

	# PHP: the site's own CLI binary, which must meet the target release's minimum
	if [ -n "$OVERRIDE" ]; then
		PHP_BIN=$OVERRIDE PHP_PKG=''
	elif ! detect_php "$ROOT"; then
		PROBLEMS+=("$ERR")
		return
	fi
	if ! PHP_CLI=$(cli_version "$PHP_BIN"); then
		PROBLEMS+=("${PHP_BIN} is not a working PHP CLI binary (php -v must say (cli))")
		return
	fi
	MIN_PHP=$TARGET_PHP
	if [ -n "$MIN_PHP" ] && version_lt "$PHP_CLI" "$MIN_PHP"; then
		PROBLEMS+=("PHP ${PHP_CLI} (${PHP_BIN}) is older than Omeka ${TARGET}'s minimum, PHP ${MIN_PHP}")
	else
		CHECKS+=("PHP ${PHP_CLI} CLI: ${PHP_BIN}${MIN_PHP:+ (Omeka ${TARGET} needs ${MIN_PHP}+)}")
	fi
	if ! "$PHP_BIN" -r 'exit(extension_loaded("mysqli") ? 0 : 1);' 2>/dev/null; then
		PROBLEMS+=("The mysqli extension is not loaded in ${PHP_BIN}, so migrations can't run from the command line")
	fi

	# Database: credentials from db.ini, reachable with the same client the dump will use
	if ! read_db "$ROOT"; then
		PROBLEMS+=("Could not read the [database] section of db.ini")
	elif [[ ! $DB_PREFIX =~ ^[A-Za-z0-9_]*$ ]]; then
		PROBLEMS+=("Unexpected characters in the db.ini prefix '${DB_PREFIX}'")
	elif [ -z "$MYSQL" ] || [ -z "$MYSQLDUMP" ]; then
		PROBLEMS+=("mysql and mysqldump (or mariadb and mariadb-dump) are required for the database backup")
	else
		CNF=$WORK_DIR/client.cnf
		write_cnf "$CNF"
		if TABLE_COUNT=$(db_query "SELECT COUNT(*), COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE '$(prefix_like)'"); then
			DB_KB=$(( ${TABLE_COUNT#*$'\t'} / 1024 ))
			TABLE_COUNT=${TABLE_COUNT%%$'\t'*}
			if [ "$TABLE_COUNT" = 0 ]; then
				PROBLEMS+=("No tables with prefix '${DB_PREFIX}' in database ${DB_NAME}")
			else
				CHECKS+=("Database ${DB_NAME}: ${TABLE_COUNT} tables with prefix '${DB_PREFIX}', $([ "$DB_KB" -lt 1024 ] && echo 'under 1' || echo "about $(( DB_KB / 1024 ))") MB")
			fi
		else
			PROBLEMS+=("Could not connect to database ${DB_NAME}: $(head -n 1 "$WORK_DIR/dberr")")
		fi
	fi

	# Files: core entries must be real (not symlinked) and movable, on the same filesystem as the backup folder
	[ -w "$ROOT" ] || PROBLEMS+=("${ROOT} is not writable")
	for ENTRY in "${CORE[@]}"; do
		if [ -L "${ROOT}/${ENTRY}" ]; then
			PROBLEMS+=("${ENTRY} is a symlink; shared-core setups aren't supported")
		elif [ -d "${ROOT}/${ENTRY}" ] && [ ! -w "${ROOT}/${ENTRY}" ]; then
			PROBLEMS+=("${ENTRY}/ is not writable, so it can't be moved")
		fi
	done
	if [ "$(stat -c %d "$ROOT")" != "$(stat -c %d "$BACKUP_ROOT")" ]; then
		PROBLEMS+=("${BACKUP_ROOT} is on a different filesystem than the site; use -d to pick a backup folder on the same filesystem")
	else
		FREE_KB=$(df -Pk "$BACKUP_ROOT" | awk 'NR == 2 { print $4 }')
		NEED_KB=$(( RELEASE_KB + ${DB_KB:-0} + RELEASE_KB / 10 ))
		if [ "$FREE_KB" -lt "$NEED_KB" ]; then
			PROBLEMS+=("Only $(( FREE_KB / 1024 )) MB free for the backup; about $(( NEED_KB / 1024 )) MB needed")
		else
			CHECKS+=("Writable, same filesystem as ${BACKUP_ROOT}, $(( FREE_KB / 1024 )) MB free")
		fi
	fi
}

# plan SITE: what an upgrade would change. Sets EXTRAS (files in the old core that won't carry over), CONFIG_LEFT (the server config files among them), PLUGIN_UPDATES and THEME_UPDATES (dir names), HTACCESS_DIFFERS, PLAN (report lines).
plan() {
	local KIND DIR NAME OLD_V NEW_V INI OTHER
	PLAN=() PLUGIN_UPDATES=() THEME_UPDATES=() CONFIG_LEFT=() HTACCESS_DIFFERS=0
	PLAN+=("Replace core: ${CORE[*]}")

	# Files in the site's core folders that aren't in the release (custom admin themes, stray uploads, edits saved as new files)
	EXTRAS=$WORK_DIR/extras
	comm -23 \
		<(cd -- "$ROOT" && find "${CORE_DIRS[@]}" \( -type f -o -type l \) 2>/dev/null | grep -vE '^application/(config/config\.ini|logs/)' | LC_ALL=C sort) \
		<(cd -- "$RELEASE_DIR" && find "${CORE_DIRS[@]}" \( -type f -o -type l \) | LC_ALL=C sort) >"$EXTRAS"
	if [ -s "$EXTRAS" ]; then
		# Server config files are named one by one; the rest (normally files Omeka itself dropped, plus logs) are only counted, and all of them are listed in not-carried-over.txt
		mapfile -t CONFIG_LEFT < <(grep -E '(^|/)(\.htaccess|\.htpasswd|\.user\.ini|php[0-9]*\.ini|web\.config)$' "$EXTRAS")
		if [ "${#CONFIG_LEFT[@]}" -gt 0 ]; then
			WARNINGS+=("Server config file(s) in the old core that Omeka doesn't ship will stay in the backup: $(join_list "${CONFIG_LEFT[@]}"). Copy back any that are still needed")
		fi
		OTHER=$(( $(wc -l <"$EXTRAS") - ${#CONFIG_LEFT[@]} ))
		if [ "$OTHER" -gt 0 ]; then
			PLAN+=("${OTHER} other file(s) in $(join_list "${CORE_DIRS[@]/%//}") aren't in ${TARGET} and will stay in the backup (normally files Omeka dropped)")
		fi
		NAME=$(grep -oE '^admin/themes/[^/]+/' "$EXTRAS" | grep -v '^admin/themes/default/$' | sort -u | cut -d / -f 3 | paste -sd ' ' -)
		[ -z "$NAME" ] || WARNINGS+=("Custom admin theme(s) in admin/themes: ${NAME}. They stay in the backup; copy them back after the upgrade if still needed")
	fi

	if [ -f "${ROOT}/.htaccess" ] && ! cmp -s "${ROOT}/.htaccess" "${RELEASE_DIR}/.htaccess"; then
		HTACCESS_DIFFERS=1
		PLAN+=("Keep .htaccess (it differs from the ${TARGET} copy)")
	fi

	for KIND in plugins themes; do
		for DIR in "${RELEASE_DIR}/${KIND}"/*/; do
			NAME=$(basename "$DIR")
			[ -d "${ROOT}/${KIND}/${NAME}" ] || continue
			[ "$KIND" = plugins ] && INI=plugin.ini || INI=theme.ini
			OLD_V=$(ini_version "${ROOT}/${KIND}/${NAME}/${INI}")
			NEW_V=$(ini_version "${DIR}${INI}")
			[ -n "$NEW_V" ] || continue
			if [ -n "$OLD_V" ] && ! version_lt "$OLD_V" "$NEW_V"; then continue; fi
			if [ -L "${ROOT}/${KIND}/${NAME}" ] || [ -e "${ROOT}/${KIND}/${NAME}/.git" ]; then
				PLAN+=("Leave ${KIND}/${NAME} (symlink or git checkout); ${NEW_V} is in the release")
			elif [ "$KIND" = themes ] && [ "$UPDATE_THEMES" = 0 ]; then
				PLAN+=("Leave themes/${NAME} ${OLD_V:-?}; ${NEW_V} is in the release (use -t to update it)")
			elif [ ! -w "${ROOT}/${KIND}" ] || [ ! -w "${ROOT}/${KIND}/${NAME}" ]; then
				WARNINGS+=("${KIND}/${NAME} is not writable, so it will stay at ${OLD_V:-?} (${NEW_V} is in the release)")
			else
				[ "$KIND" = plugins ] && PLUGIN_UPDATES+=("$NAME") || THEME_UPDATES+=("$NAME")
				PLAN+=("Update ${KIND}/${NAME} ${OLD_V:-?} → ${NEW_V}")
			fi
		done
	done
}

# rollback_code: put the old core back, newest move first
rollback_code() {
	local I ENTRY OK=0
	for (( I = ${#SWAPPED[@]} - 1; I >= 0; I-- )); do
		ENTRY=${SWAPPED[I]}
		if [ -e "${ROOT}/${ENTRY}" ] || [ -L "${ROOT}/${ENTRY}" ]; then
			mv -T -- "${ROOT}/${ENTRY}" "${SITE_BK}/failed/${ENTRY}" || OK=1
		fi
		if [ -e "${SITE_BK}/old/${ENTRY}" ] || [ -L "${SITE_BK}/old/${ENTRY}" ]; then
			mv -T -- "${SITE_BK}/old/${ENTRY}" "${ROOT}/${ENTRY}" || OK=1
		fi
	done
	SWAPPED=()
	return $OK
}

# restore_db: drop tables the failed migration created, then load the dump
restore_db() {
	local TABLE
	db_query "SHOW TABLES LIKE '$(prefix_like)'" | while IFS= read -r TABLE; do
		grep -qxF -- "$TABLE" "${SITE_BK}/tables.txt" || db_query "DROP TABLE \`${TABLE}\`"
	done
	gzip -cd "${SITE_BK}/db.sql.gz" | "$MYSQL" --defaults-extra-file="$CNF" "$DB_NAME" 2>"$WORK_DIR/dberr"
	[ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ]
}

# write_readme: rollback notes kept with the backup
write_readme() {
	local ENTRY
	{
		echo "Omeka upgrade backup: ${ROOT}"
		echo "${INSTALLED} → ${TARGET}, ${NOW}, by ${ME}"
		echo
		echo "old/          the replaced core and add-ons, exactly as they were"
		echo "db.sql.gz     tables with prefix '${DB_PREFIX}' from database ${DB_NAME}, dumped before the upgrade"
		[ -s "${SITE_BK}/not-carried-over.txt" ] && echo "not-carried-over.txt  files in the old core that aren't in ${TARGET}"
		[ -f "${SITE_BK}/htaccess-${TARGET}" ] && echo "htaccess-${TARGET}   the release's .htaccess, for comparison with the site's (which was kept)"
		echo
		if [ "${#CONFIG_LEFT[@]}" -gt 0 ]; then
			echo "Server config files that were in the old core but aren't part of Omeka. To copy back any that are still needed:"
			echo
			for ENTRY in "${CONFIG_LEFT[@]}"; do
				echo "  cp -p '${SITE_BK}/old/${ENTRY}' '${ROOT}/${ENTRY}'"
			done
			echo
		fi
		echo "To roll back, move each new entry out of the site and the old one back, then load the dump:"
		echo
		echo "  mkdir -p '${SITE_BK}/failed/plugins' '${SITE_BK}/failed/themes'"
		for ENTRY in "${MOVED[@]}"; do
			echo "  mv '${ROOT}/${ENTRY}' '${SITE_BK}/failed/${ENTRY}' && mv '${SITE_BK}/old/${ENTRY}' '${ROOT}/${ENTRY}'"
		done
		echo "  gzip -cd '${SITE_BK}/db.sql.gz' | mysql -h '${DB_HOST:-localhost}' -u '${DB_USER}' -p '${DB_NAME}'"
	} >"${SITE_BK}/README.txt"
}

# upgrade_site SITE: back up, swap, migrate; adds the site's summary entry. Only called after preflight and plan found no problems.
upgrade_site() {
	local SITE=$1 ENTRY KIND NAME OUT STATUS APPLIED SERVER_URL LINE DONE=() NOTES=() OWNER
	SITE_BK=${BACKUP_ROOT}/${SLUG}-${INSTALLED}-to-${TARGET}-${NOW}
	SWAPPED=() MOVED=()

	if ! mkdir "${BACKUP_ROOT}/.lock-${SLUG}" 2>/dev/null; then
		site_error "$SITE" "Another upgrade of this site is running (or left ${BACKUP_ROOT}/.lock-${SLUG} behind)"
		return
	fi
	LOCKS+=("${BACKUP_ROOT}/.lock-${SLUG}")
	if ! mkdir -p -- "${SITE_BK}/old/plugins" "${SITE_BK}/old/themes" "${SITE_BK}/failed" || ! chmod 700 "$SITE_BK"; then
		site_error "$SITE" "Could not create ${SITE_BK}"
		return
	fi

	# 1. Database backup
	echo -e "${CYAN}█ Backing up database tables with prefix '${DB_PREFIX}' ...${NOCOLOR}"
	db_query "SHOW TABLES LIKE '$(prefix_like)'" >"${SITE_BK}/tables.txt"
	mapfile -t TABLES <"${SITE_BK}/tables.txt"
	# The dump holds every user's password hash, so it is written readable by the owner only
	(
		umask 077
		"$MYSQLDUMP" --defaults-extra-file="$CNF" --single-transaction --quick --no-tablespaces "$DB_NAME" "${TABLES[@]}" 2>"$WORK_DIR/dberr" | gzip >"${SITE_BK}/db.sql.gz"
		[ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ]
	)
	STATUS=$?
	if [ "$STATUS" != 0 ] || ! gzip -cd "${SITE_BK}/db.sql.gz" | tail -n 1 | grep -q '^-- Dump completed'; then
		site_error "$SITE" "Database backup failed: $(head -n 1 "$WORK_DIR/dberr"); nothing was changed"
		return
	fi

	# 2. Stage the new core next to the backup, with this site's config and logs
	echo -e "${CYAN}█ Staging Omeka ${TARGET} ...${NOCOLOR}"
	if ! cp -a -- "$RELEASE_DIR" "${SITE_BK}/new"; then
		site_error "$SITE" "Could not copy the release into ${SITE_BK}; nothing was changed"
		return
	fi
	if ! cp -p -- "${ROOT}/application/config/config.ini" "${SITE_BK}/new/application/config/config.ini" ||
		{ [ -d "${ROOT}/application/logs" ] && ! cp -a -- "${ROOT}/application/logs/." "${SITE_BK}/new/application/logs/"; }; then
		site_error "$SITE" "Could not carry config.ini and logs into the new core; nothing was changed"
		return
	fi
	# Run as root (e.g. on a VPS), new files would belong to root and the site couldn't write its logs
	if [ "$EUID" = 0 ]; then
		OWNER=$(stat -c %u:%g "${ROOT}/bootstrap.php")
		chown -R "$OWNER" "${SITE_BK}/new"
	fi
	[ -s "$EXTRAS" ] && cp -- "$EXTRAS" "${SITE_BK}/not-carried-over.txt"
	[ "$HTACCESS_DIFFERS" = 1 ] && cp -p -- "${RELEASE_DIR}/.htaccess" "${SITE_BK}/htaccess-${TARGET}"

	STATUS=''

	# 3. Swap: ignore interrupts and hangups until the migrations finish, so the site is never left half-swapped
	echo -e "${CYAN}█ Swapping core files ...${NOCOLOR}"
	trap '' INT TERM HUP
	for ENTRY in "${CORE[@]}"; do
		if [ -e "${ROOT}/${ENTRY}" ] || [ -L "${ROOT}/${ENTRY}" ]; then
			mv -T -- "${ROOT}/${ENTRY}" "${SITE_BK}/old/${ENTRY}" || { STATUS="Could not move ${ENTRY} out of the site"; break; }
		fi
		SWAPPED+=("$ENTRY")
		mv -T -- "${SITE_BK}/new/${ENTRY}" "${ROOT}/${ENTRY}" || { STATUS="Could not move the new ${ENTRY} into place"; break; }
	done
	if [ -n "$STATUS" ]; then
		if rollback_code; then
			site_error "$SITE" "${STATUS}; the old core was put back. Database untouched."
		else
			site_error "$SITE" "${STATUS}, and putting the old core back also failed. Restore by hand from ${SITE_BK}/old"
		fi
		trap - INT TERM HUP
		return
	fi
	MOVED=("${CORE[@]}")

	# 4. Migrations, from the command line with the new code
	echo -e "${CYAN}█ Running database migrations ...${NOCOLOR}"
	OUT=$(cd -- "$ROOT" && "$PHP_BIN" -d display_errors=stderr -d memory_limit=1024M "$WORK_DIR/omeka-cli.php" "$ROOT" migrate 2>"$WORK_DIR/phperr")
	STATUS=$?
	if [ "$STATUS" != 0 ] || [[ $OUT != *DONE* ]]; then
		ERR=$(grep -v '^[[:space:]]*$' "$WORK_DIR/phperr" | tail -n 1)
		cp -- "$WORK_DIR/phperr" "${SITE_BK}/php-errors.txt"
		if [[ $OUT == *MIGRATING* ]]; then
			echo -e "${RED}█ Migration failed; restoring the database and the old core ...${NOCOLOR}"
			restore_db || NOTES+=("Restoring the database ALSO FAILED: $(head -n 1 "$WORK_DIR/dberr"). Load ${SITE_BK}/db.sql.gz by hand.")
		else
			echo -e "${RED}█ Omeka ${TARGET} could not start; restoring the old core ...${NOCOLOR}"
		fi
		if rollback_code; then
			# Rolled back cleanly: keep only the dump and the error output
			rm -rf -- "${SITE_BK}/new" "${SITE_BK}/failed" "${SITE_BK}/old"
		else
			NOTES+=("Putting the old core back ALSO FAILED; restore by hand from ${SITE_BK}/old")
		fi
		trap - INT TERM HUP
		site_error "$SITE" "Upgrade failed and was rolled back: ${ERR:-no error output}" "Details: ${SITE_BK}/php-errors.txt" "${NOTES[@]}"
		return
	fi
	trap - INT TERM HUP
	APPLIED=$(sed -n 's/^APPLIED=//p' <<<"$OUT")
	SERVER_URL=$(sed -n 's/^SERVER_URL=//p' <<<"$OUT")
	DONE+=("Upgraded Omeka ${INSTALLED} → ${TARGET}; ${APPLIED:-0} database migration(s) applied")

	# 5. Bundled add-ons; a failure here leaves that add-on as it was
	for KIND in plugins themes; do
		if [ "$KIND" = plugins ]; then set -- "${PLUGIN_UPDATES[@]}"; else set -- "${THEME_UPDATES[@]}"; fi
		for NAME in "$@"; do
			if mv -T -- "${ROOT}/${KIND}/${NAME}" "${SITE_BK}/old/${KIND}/${NAME}"; then
				if mv -T -- "${SITE_BK}/new/${KIND}/${NAME}" "${ROOT}/${KIND}/${NAME}"; then
					MOVED+=("${KIND}/${NAME}")
					DONE+=("Updated ${KIND}/${NAME} to $(ini_version "${ROOT}/${KIND}/${NAME}/$([ "$KIND" = plugins ] && echo plugin.ini || echo theme.ini)")")
				else
					mv -T -- "${SITE_BK}/old/${KIND}/${NAME}" "${ROOT}/${KIND}/${NAME}"
					WARNINGS+=("Could not update ${KIND}/${NAME}; left as it was")
				fi
			else
				WARNINGS+=("Could not update ${KIND}/${NAME}; left as it was")
			fi
		done
	done

	# 6. Does the whole application (plugins included) still start? Report only: the upgrade itself succeeded.
	if ! (cd -- "$ROOT" && "$PHP_BIN" -d display_errors=stderr "$WORK_DIR/omeka-cli.php" "$ROOT" bootcheck >/dev/null 2>"$WORK_DIR/phperr"); then
		WARNINGS+=("Omeka with its plugins did not start cleanly from the command line: $(grep -v '^[[:space:]]*$' "$WORK_DIR/phperr" | tail -n 1). Check the site in a browser.")
	fi

	write_readme
	rm -rf -- "${SITE_BK}/new" "${SITE_BK}/failed"
	rmdir -- "${SITE_BK}/old/plugins" "${SITE_BK}/old/themes" 2>/dev/null
	rmdir -- "${BACKUP_ROOT}/.lock-${SLUG}"

	DONE+=("Backup: ${SITE_BK} (rollback steps in README.txt)")
	# Only plugins installed in this site's database need the Upgrade click; the rest are just files
	OUT=$(db_query "SELECT name FROM \`${DB_PREFIX}plugins\`")
	set --
	for NAME in "${PLUGIN_UPDATES[@]}"; do
		if grep -qxF -- "$NAME" <<<"$OUT"; then set -- "$@" "$NAME"; fi
	done
	if [ $# -gt 0 ]; then
		NOTES+=("${BOLD}Log in to the site's admin to complete the upgrade:${NORMAL} on the Plugins page, click Upgrade for $(printf '%s, ' "$@" | sed 's/, $//') (Omeka won't load a replaced plugin until it's upgraded)")
	fi
	if [ -z "$SERVER_URL" ] && grep -q "'server_url'" "${ROOT}/application/forms/GeneralSettings.php" 2>/dev/null; then
		NOTES+=("Set the Server URL under Settings → General (new in ${TARGET}; Omeka fills it in from the browser only when the upgrade runs on the web)")
	fi
	[ "${#CONFIG_LEFT[@]}" -gt 0 ] && WARNINGS+=("Copy-back commands for those config files are in ${SITE_BK}/README.txt")
	[ "$HTACCESS_DIFFERS" = 1 ] && WARNINGS+=("Kept the site's .htaccess, which differs from the ${TARGET} copy; compare with ${SITE_BK}/htaccess-${TARGET}")
	if [ "$MANAGED" = 1 ]; then
		# The pre-upgrade version mismatch warning is superseded by this note
		set -- "${WARNINGS[@]}"
		WARNINGS=()
		for LINE in "$@"; do [[ $LINE == "Installatron records version"* ]] || WARNINGS+=("$LINE"); done
		NOTES+=("${BOLD}Installatron:${NORMAL} in My Applications, edit this install's details and set the version to ${TARGET}, or turn off its auto-update, so Installatron doesn't lay an older package over this upgrade")
	fi
	add_summary "$GREEN" "✔" "$SITE" "${DONE[@]}" "${NOTES[@]}"
}

# process_site SITE: preflight, then report (-c), plan (-n) or upgrade
process_site() {
	local SITE=$1 LINE
	preflight "$SITE"
	if [ "$CHECK_ONLY" = 1 ]; then
		for LINE in "${CHECKS[@]}"; do echo -e "${CYAN}█ ${LINE}${NOCOLOR}"; done
		if [ "${#PROBLEMS[@]}" -gt 0 ]; then
			site_error "$SITE" "${PROBLEMS[@]}" "${CHECKS[@]}"
		elif [ "$MANAGED" = 1 ] || [ "${#WARNINGS[@]}" -gt 0 ] || [ "$STATE" = major ] || [ "$STATE" = newer ]; then
			add_summary "$YELLOW" "!" "$SITE" "${CHECKS[@]}"
		else
			add_summary "$GREEN" "✔" "$SITE" "${CHECKS[@]}"
		fi
		return
	fi

	case $STATE in
		'') site_error "$SITE" "${PROBLEMS[@]}"; return ;;
		current) add_summary "$GREEN" "✔" "$SITE" "Already up to date (Omeka ${INSTALLED})"; return ;;
		newer) site_skip "$SITE" "Omeka ${INSTALLED} is newer than ${TARGET}; nothing to do"; return ;;
		major) [ "$ALLOW_MAJOR" = 1 ] || { site_skip "$SITE" "Omeka ${INSTALLED} → ${TARGET} crosses a major version; check plugin and theme compatibility, then rerun with -j"; return; } ;;
	esac
	if [ "$MANAGED" = 1 ] && [ "$ALLOW_MANAGED" = 0 ]; then
		site_skip "$SITE" "Managed by Installatron (recorded version: ${IT_VERSION:-unknown}; auto-update setting: ${IT_AUTOUP:-unknown}). Upgrade it in Installatron, or rerun with -m"
		return
	fi
	if [ "${#PROBLEMS[@]}" -gt 0 ]; then
		site_error "$SITE" "${PROBLEMS[@]}"
		return
	fi

	plan
	for LINE in "${PLAN[@]}"; do echo -e "${CYAN}█ ${LINE}${NOCOLOR}"; done
	for LINE in "${WARNINGS[@]}"; do echo -e "${YELLOW}█ Warning: ${LINE}${NOCOLOR}"; done
	if [ "$DRY_RUN" = 1 ]; then
		add_summary "$GREEN" "✔" "$SITE" "Dry run: would upgrade Omeka ${INSTALLED} → ${TARGET}" "${PLAN[@]}"
		return
	fi
	upgrade_site "$SITE"
}

# fetch_github URL OUTFILE: GET with sensible timeouts
fetch_github() {
	curl -fsSL --connect-timeout 10 --retry 2 -H 'Accept: application/vnd.github+json' -o "$2" "$1"
}

# release_asset JSON_FILE: print "tag<TAB>zip url<TAB>sha256 digest (may be empty)" for a GitHub release
release_asset() {
	# shellcheck disable=SC2016  # PHP code, not shell
	"$JSON_PHP" -r '
		$r = json_decode(file_get_contents($argv[1]), true);
		if (!is_array($r) || empty($r["tag_name"])) exit(1);
		foreach ((array) $r["assets"] as $a) {
			if (preg_match("/^omeka-[0-9.]+\\.zip$/", $a["name"])) {
				$d = isset($a["digest"]) && strpos((string) $a["digest"], "sha256:") === 0 ? substr($a["digest"], 7) : "";
				echo $r["tag_name"], "\t", $a["browser_download_url"], "\t", $d;
				exit(0);
			}
		}
		exit(2);
	' "$1"
}

# get_release: sets RELEASE_DIR, TARGET, TARGET_PHP, RELEASE_KB, CORE, CORE_DIRS from a downloaded or local zip, verified and extracted once for all sites
get_release() {
	local ZIP INFO TAG URL EXPECTED ACTUAL TOP BAD ENTRY KEEP
	if [ -n "$LOCAL_ZIP" ]; then
		if [ ! -f "$LOCAL_ZIP" ] || [ ! -r "$LOCAL_ZIP" ]; then fatal "Can't read ${LOCAL_ZIP}"; fi
		ZIP=$LOCAL_ZIP
		echo -e "${GREEN}█ Using local release ${ZIP}${NOCOLOR}"
	else
		command -v curl >/dev/null || fatal "curl is required to download the release; use --local=ZIP instead"
		echo -e "${CYAN}█ Looking up the latest Omeka Classic release ...${NOCOLOR}"
		fetch_github "${RELEASES_API}/latest" "$WORK_DIR/release.json" || fatal "Could not reach the GitHub API; download the zip elsewhere and use --local=ZIP"
		INFO=$(release_asset "$WORK_DIR/release.json") || fatal "Could not find the release zip in GitHub's response"
		IFS=$'\t' read -r TAG URL EXPECTED <<<"$INFO"
		ZIP=$WORK_DIR/${URL##*/}
		echo -e "${CYAN}█ Downloading ${TAG} (${URL##*/}) ...${NOCOLOR}"
		curl -fsSL --connect-timeout 10 --retry 2 -o "$ZIP" "$URL" || fatal "Download failed: ${URL}"
		[ -n "$EXPECTED" ] || echo -e "${YELLOW}█ Warning: GitHub publishes no SHA-256 digest for this asset; relying on HTTPS alone${NOCOLOR}"
	fi

	ACTUAL=$(sha256sum "$ZIP" | cut -d ' ' -f 1)
	if [ -n "$LOCAL_ZIP" ]; then
		if [ -n "$LOCAL_SHA256" ]; then
			EXPECTED=${LOCAL_SHA256#sha256:}
		fi
	fi

	command -v unzip >/dev/null || fatal "unzip is required"
	unzip -Z1 "$ZIP" >"$WORK_DIR/zip.list" 2>/dev/null || fatal "${ZIP} is not a readable zip file"
	BAD=$(grep -m 1 -E '(^/|(^|/)\.\.(/|$))' "$WORK_DIR/zip.list")
	[ -z "$BAD" ] || fatal "Refusing a zip with an unsafe path: ${BAD}"
	TOP=$(grep -E '^[^/]+/bootstrap\.php$' "$WORK_DIR/zip.list")
	[ "$(grep -c . <<<"$TOP")" = 1 ] || fatal "${ZIP} doesn't look like an Omeka Classic release (no single top-level bootstrap.php)"
	TOP=${TOP%/bootstrap.php}

	TARGET=$(unzip -p "$ZIP" "${TOP}/bootstrap.php" | sed -nE "s/^[[:space:]]*define\([[:space:]]*['\"]OMEKA_VERSION['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" | head -n 1)
	[ -n "$TARGET" ] || fatal "Could not read OMEKA_VERSION from the release"

	# A local zip with no --sha256: try GitHub's digest for that version, quietly giving up if the host blocks it
	if [ -n "$LOCAL_ZIP" ] && [ -z "$EXPECTED" ] && command -v curl >/dev/null; then
		if curl -fsSL --connect-timeout 5 --max-time 15 -H 'Accept: application/vnd.github+json' -o "$WORK_DIR/release.json" "${RELEASES_API}/tags/v${TARGET}" 2>/dev/null; then
			INFO=$(release_asset "$WORK_DIR/release.json") && EXPECTED=${INFO##*$'\t'}
		fi
		[ -n "$EXPECTED" ] || echo -e "${YELLOW}█ Warning: no --sha256 given and GitHub's digest for v${TARGET} couldn't be fetched; the local zip is unverified${NOCOLOR}"
	fi
	if [ -n "$EXPECTED" ]; then
		[ "$ACTUAL" = "${EXPECTED,,}" ] || fatal "SHA-256 mismatch for ${ZIP}: expected ${EXPECTED}, got ${ACTUAL}"
		echo -e "${GREEN}█ SHA-256 verified (${ACTUAL})${NOCOLOR}"
	fi

	unzip -q "$ZIP" -d "$WORK_DIR/release" || fatal "Could not extract ${ZIP}"
	RELEASE_DIR=$WORK_DIR/release/$TOP
	TARGET_PHP=$(sed -nE "s/.*const[[:space:]]+OMEKA_PHP_VERSION[[:space:]]*=[[:space:]]*'([^']+)'.*/\1/p" "${RELEASE_DIR}/application/models/Installer/Requirements.php" 2>/dev/null)
	RELEASE_KB=$(du -sk "$RELEASE_DIR" | cut -f 1)

	CORE=() CORE_DIRS=()
	for ENTRY in "$RELEASE_DIR"/* "$RELEASE_DIR"/.[!.]*; do
		[ -e "$ENTRY" ] || continue
		ENTRY=${ENTRY##*/}
		for KEEP in "${PRESERVE[@]}"; do [ "$ENTRY" = "$KEEP" ] && continue 2; done
		CORE+=("$ENTRY")
		[ -d "${RELEASE_DIR}/${ENTRY}" ] && CORE_DIRS+=("$ENTRY")
	done
	echo -e "${GREEN}█ Target release: Omeka ${TARGET}${TARGET_PHP:+ (PHP ${TARGET_PHP}+)}${NOCOLOR}"
}

# The PHP side, run with each site's own PHP CLI from inside the site. Modes: migrate (Config, Logger, Db and Options only, like a database upgrade needs) and bootcheck (the full set background jobs use, plugins included).
write_cli_helper() {
	cat >"$1" <<'PHP'
<?php
error_reporting(E_ALL & ~E_DEPRECATED);
list(, $root, $mode) = $argv;
try {
    require $root . '/bootstrap.php';
    require APP_DIR . '/libraries/Omeka/Application.php';
    $application = new Omeka_Application(APPLICATION_ENV);
    if ($mode === 'bootcheck') {
        $application->bootstrap(['Config', 'Logger', 'Db', 'Options', 'Pluginbroker', 'View', 'Locale', 'Mail', 'Plugins', 'Jobs', 'Storage', 'Filederivatives']);
        echo "OK\n";
        exit(0);
    }
    $application->bootstrap(['Config', 'Logger', 'Db', 'Options']);
    if (version_compare(PHP_VERSION, Installer_Requirements::OMEKA_PHP_VERSION, '<')) {
        throw new RuntimeException('Omeka ' . OMEKA_VERSION . ' requires PHP ' . Installer_Requirements::OMEKA_PHP_VERSION . '+, this is ' . PHP_VERSION);
    }
    $db = get_db();
    $mysql = $db->getAdapter()->getServerVersion();
    if (version_compare($mysql, Installer_Requirements::OMEKA_MYSQL_VERSION, '<')) {
        throw new RuntimeException('Omeka ' . OMEKA_VERSION . ' requires MySQL ' . Installer_Requirements::OMEKA_MYSQL_VERSION . '+, this is ' . $mysql);
    }
    $table = $db->prefix . Omeka_Db_Migration_Manager::MIGRATION_TABLE_NAME;
    $manager = Omeka_Db_Migration_Manager::getDefault();
    $before = (int) $db->fetchOne("SELECT COUNT(*) FROM `$table`");
    if ($manager->canUpgrade()) {
        echo "MIGRATING\n";
        $manager->migrate();
    }
    $manager->finalizeDbUpgrade();
    echo 'APPLIED=', (int) $db->fetchOne("SELECT COUNT(*) FROM `$table`") - $before, "\n";
    echo 'SERVER_URL=', (string) get_option('server_url'), "\n";
    echo "DONE\n";
} catch (Throwable $e) {
    fwrite(STDERR, get_class($e) . ': ' . $e->getMessage() . "\n");
    exit(1);
}
PHP
}

# shellcheck disable=SC2317  # called by the EXIT trap
cleanup() {
	local LOCK
	for LOCK in "${LOCKS[@]}"; do rmdir -- "$LOCK" 2>/dev/null; done
	[ -n "$WORK_DIR" ] && rm -rf -- "$WORK_DIR"
}

# Long options are rewritten as their short forms (--local=ZIP or --local ZIP becomes -l ZIP) so getopts parses everything. Like getopts, this stops at the first path, so options always go before the paths. Short options that take a value (d b l s) also carry the next argument along when they end their cluster, as in -d DIR or -nd DIR.
ARGS=()
END_OF_OPTIONS=0
while [ $# -gt 0 ]; do
	case $1 in
		--)
			END_OF_OPTIONS=1
			ARGS+=("$@")
			break
			;;
		--*)
			case ${1%%=*} in
				--check) SHORT=c ;; --dry-run) SHORT=n ;; --managed) SHORT=m ;; --themes) SHORT=t ;; --major) SHORT=j ;; --help) SHORT=h ;;
				--backup-dir) SHORT=d: ;; --php) SHORT=b: ;; --local) SHORT=l: ;; --sha256) SHORT=s: ;;
				*) echo -e "${RED}█ Unknown option ${1%%=*}${NOCOLOR}"; usage; exit 1 ;;
			esac
			if [[ $SHORT == *: ]]; then
				if [[ $1 == *=* ]]; then
					VALUE=${1#*=}
				elif [ $# -ge 2 ]; then
					VALUE=$2
					shift
				else
					VALUE=''
				fi
				[ -n "$VALUE" ] || { echo -e "${RED}█ Option ${1%%=*} needs a value${NOCOLOR}"; usage; exit 1; }
				ARGS+=("-${SHORT%:}" "$VALUE")
			else
				[[ $1 != *=* ]] || { echo -e "${RED}█ Option ${1%%=*} doesn't take a value${NOCOLOR}"; usage; exit 1; }
				ARGS+=("-${SHORT}")
			fi
			;;
		-?*)
			ARGS+=("$1")
			CLUSTER=${1#-}
			for (( I = 0; I < ${#CLUSTER}; I++ )); do
				if [[ dbls == *"${CLUSTER:I:1}"* ]]; then
					if [ $(( I + 1 )) = "${#CLUSTER}" ] && [ $# -ge 2 ]; then
						ARGS+=("$2")
						shift
					fi
					break
				fi
			done
			;;
		*)
			ARGS+=("$@")
			break
			;;
	esac
	shift
done
set -- "${ARGS[@]}"

while getopts ':cnmtjd:b:l:s:h' OPT; do
	case $OPT in
		c) CHECK_ONLY=1 ;;
		n) DRY_RUN=1 ;;
		m) ALLOW_MANAGED=1 ;;
		t) UPDATE_THEMES=1 ;;
		j) ALLOW_MAJOR=1 ;;
		d) BACKUP_ROOT=$OPTARG ;;
		b) OVERRIDE=$OPTARG ;;
		l) LOCAL_ZIP=$OPTARG ;;
		s) LOCAL_SHA256=$OPTARG ;;
		h) usage; exit 0 ;;
		:) echo -e "${RED}█ Option -${OPTARG} needs a value${NOCOLOR}"; usage; exit 1 ;;
		*) echo -e "${RED}█ Unknown option -${OPTARG}${NOCOLOR}"; usage; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

if [ $# -eq 0 ]; then
	echo -e "${RED}█ Oops, you forgot to include an argument! ${NOCOLOR}"
	usage
	exit 1
fi
if [ "$END_OF_OPTIONS" = 0 ]; then
	for SITE_RAW in "$@"; do
		[[ $SITE_RAW != -* ]] || fatal "Options go before the paths ('${SITE_RAW}' came after a path)"
	done
fi
if [ -n "$LOCAL_SHA256" ] && [ -z "$LOCAL_ZIP" ]; then
	fatal "-s/--sha256 only applies to -l/--local"
fi
if [ -n "$LOCAL_SHA256" ] && [[ ! ${LOCAL_SHA256#sha256:} =~ ^[0-9A-Fa-f]{64}$ ]]; then
	fatal "-s/--sha256 must be a 64-character hex SHA-256 (optionally prefixed with sha256:)"
fi
if [ -n "$LOCAL_ZIP" ]; then
	LOCAL_ZIP=$(cd -- "$(dirname -- "$LOCAL_ZIP")" 2>/dev/null && echo "$(pwd -P)/$(basename -- "$LOCAL_ZIP")") || fatal "Can't find ${LOCAL_ZIP}"
fi

echo -e "${CYAN}Running ${ME} from ${SCRIPT_LOCATION}${NOCOLOR}"

# PHP used for detection and for reading GitHub's JSON (or the -b binary), like set-omeka-php-path.sh
if [ -n "$OVERRIDE" ]; then
	if [[ $OVERRIDE =~ ^ea-php[0-9]+$ ]]; then OVERRIDE=/usr/local/bin/${OVERRIDE}; fi
	if [[ $OVERRIDE != /* ]] || ! CLI=$(cli_version "$OVERRIDE"); then
		fatal "-b must be the absolute path of a PHP CLI binary (or ea-phpNN); got '${OVERRIDE}'"
	fi
	JSON_PHP=$OVERRIDE
	echo -e "${GREEN}█ PHP ${CLI} CLI verified (${OVERRIDE}); skipping detection${NOCOLOR}"
elif [ -x "$WRAPPER" ]; then
	DETECT_PHP=$WRAPPER JSON_PHP=$WRAPPER
	echo -e "${GREEN}█ PHP wrapper verified (${WRAPPER})${NOCOLOR}"
elif DETECT_PHP=$(command -v php); then
	JSON_PHP=$DETECT_PHP
	echo -e "${YELLOW}█ cPanel's ${WRAPPER} not found; detecting with ${DETECT_PHP} (use -b if that is not the sites' PHP)${NOCOLOR}"
else
	fatal "PHP is missing or is not executable. Use -b to set the PHP binary."
fi
MYSQL=$(command -v mysql || command -v mariadb)
MYSQLDUMP=$(command -v mysqldump || command -v mariadb-dump)
[ "$CHECK_ONLY" = 1 ] && echo -e "${GREEN}█ Check only: no files or databases will be changed${NOCOLOR}"
[ "$DRY_RUN" = 1 ] && echo -e "${GREEN}█ Dry run: no files or databases will be changed${NOCOLOR}"

( umask 077; mkdir -p -- "$BACKUP_ROOT" ) || fatal "Unable to create backup folder ${BACKUP_ROOT}" 2
BACKUP_ROOT=$(cd -- "$BACKUP_ROOT" && pwd -P)
WORK_DIR=$(mktemp -d "${BACKUP_ROOT}/.work.XXXXXX") || fatal "Unable to create a working directory in ${BACKUP_ROOT}" 2
trap cleanup EXIT
write_cli_helper "$WORK_DIR/omeka-cli.php"

get_release

for SITE_RAW in "$@"; do
	SITE="${SITE_RAW%/}"
	WARNINGS=()
	if [ -e "${SITE}/bootstrap.php" ] && grep -q OMEKA_VERSION "${SITE}/bootstrap.php"; then
		echo -e "${GREEN}\n█ Omeka installation found at ${SITE}\n${NOCOLOR}"
		process_site "$SITE"
	else
		echo -e "${YELLOW}\n█ Omeka installation not found at ${SITE}. Skipping this directory.\n${NOCOLOR}"
		add_summary "$YELLOW" "✗" "$SITE" "Skipped (not an Omeka installation)"
	fi
done

printf '%*s\n' "${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}" '' | tr ' ' -
echo -e "${CYAN}\n\n${SUMMARY}\n\n${NOCOLOR}"
printf '%*s\n' "${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}" '' | tr ' ' -
exit "$FAILED"
