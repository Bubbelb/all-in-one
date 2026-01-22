#!/bin/sh

# Checking and applying the subvolume structure, if needed.
# All the subvolumes are checked and converted, if needed.
# When not on BTRFS, a subdirectory will be created.
# All mounts under /mnt are checked and converted.
# Checks are done to make sure no already processed subvolumes are done.
# The conversion to subvolume structure fist copies the data to the new subvolume, checks it and, when all ok, removes the sources.
#
# Structure of subvolue:
#  Base volume:        /mnt/<volume>/                - Base where volume is mounted.
#  Created Subvolume:  /mnt/<volume>/@               - Current working subvolume, or subdirectory. This one is mounted on production containers.
#  Backup Subvolume:   /mnt/<volume>/@snapshots/...  - All snapshots are created in this subvolume.
#  State File:         /mnt/<volume>/.subvols        - After conversion completed succesfully, this file is created.
#  Error File:         /mnt/<volume>/.subvols_error  - After conversion went wrong, this file is created.
#
#  Notes:
#   - This container should run and finish before any other. See the documentation on dependencies and conditins in compose.yaml
#   - Subvolumes are created read-only (Suggestion). This allows for a btrfs send/recieve style copy.
#   - @snapshots subvolume is optional. When not on btrfs (maybe bcachefs in the future), this subvolume does not exist.
#   - When there is an error, the conversion stops and .subvols_error is written.
#   - This container will not stop, when a .subvols_error file is found. This prevents other containers to start and potentially break things.
#   - It is assumed no other subvolumes exist in the docker volumes. They're not handled properly.
#   - When you encounter an error on conversion, you have a few options:
#     - Manually move all files and folders to the new location, remove the .subvols_error. .subvols is created automatically at restart.
#     - Remove all subvolumes, .subvols_error and restart the processed
#   - This tool ONLY expects the files and subvolumes/subdirectories as laid out above. Any other files/directories triggers a .subvolumes_error...

# As this is an all-or-nothing approach. meaning that when you incorporate this in your compose.yaml, you go all-in and you updated your dependencies
# and subvolume registrations accordingly.

apk add --no-cache btrfs-progs coreutils # Coreutils is not strictly needed, but gets a btrfs-aware mv utility installed.

IFS=$'\n'
ALL_MOUNTS=0
CHG_MOUNTS=0

##############################
# Logging provisions
##############################

# Process string to numerical log level, or the other way around.
# When a single digit between 3 and 8 is given, the text representation is returned.
# Otherwise a log level name is expected and the corresponding numerical level is returned.
# UNONOWN is returned with a non-zere return code, when the inout is not recognised.
logstring_tr() {
    if echo "${1}" | grep -q '^[3-8]$' ; then
        case ${1} in
            0 ) echo 'EMERGENCY' ;;
            1 ) echo 'ALERT' ;;
            2 ) echo 'CRITICAL' ;;
            3 ) echo 'ERROR' ;;
            4 ) echo 'WARNING' ;;
            5 ) echo 'NOTICE' ;;
            6 ) echo 'INFO' ;;
            7 ) echo 'DEBUG' ;;
            8 ) echo 'TRACE' ;;
        esac
    else
        case "${1}" in
            'EMERG'         ) echo 0 ;;
            'EMERGENCY'     ) echo 0 ;;
            'ALERT'         ) echo 1 ;;
            'CRIT'          ) echo 2 ;;
            'CRITICAL'      ) echo 2 ;;
            'ERR'           ) echo 3 ;;
            'ERROR'         ) echo 3 ;;
            'WARN'          ) echo 4 ;;
            'WARNING'       ) echo 4 ;;
            'NOT'           ) echo 5 ;;
            'NOTICE'        ) echo 5 ;;
            'INFO'          ) echo 6 ;;
            'DBG'           ) echo 7 ;;
            'DEBUG'         ) echo 7 ;;
            'TRACE'         ) echo 8 ;;
                    * ) echo 'UNKNOWN'
                        return 1 ;;
        esac
    fi
    return 0
    } # logstring_tr()

# Write a log entry to the console. Syntax:
# clog [LEVEL] <Log string>
# Level is optional and can be a string or a numerical representation.
# If the first parameter is not recognised as an error level (e.g. a number between 3 and 8,
# or the textual representation of the log level), the default log level, as provided in $LOG_LEVEL_DEFAULT
# is used.
# When the provided, or default log level is higher, or equal to the set level in $LOG_LEVEL, the log string
# is printed to stderr.
clog() {
    if echo "${1}" | grep -q '^[3-8]$' ; then
        _L_STR=$(logstring_tr ${1})
    _L_NUM=${1}
        shift
    else
        _L_NUM=$(logstring_tr "${1}")
        if [[ "${_L_NUM}" == "UNKNOWN" ]] ; then
            _L_NUM=$(logstring_tr "${LOG_LEVEL_DEFAULT}")
        else
            shift
        fi
        _L_STR=$(logstring_tr ${_L_NUM})
    fi
    if [[ ${_L_NUM} -le ${_LOG_LEVEL} ]] ; then
        printf '[%s] %-7s: %s\n' "${SCRIPTNAME}" "${_L_STR}" "$*" >&2
    fi
} # clog()

LOG_LEVEL_DEFAULT=${LOG_LEVEL_DEFAULT:-INFO}
export LOG_LEVEL_DEFAULT

if [[ -z "${_LOG_LEVEL}" ]] ; then
# Determine the log level to use.
    _LOG_LEVEL=$(logstring_tr "${LOG_LEVEL:-${LOG_LEVEL_DEFAULT}}")
    if [[ "${_LOG_LEVEL}" == "UNKNOWN" ]] ; then
        _LOG_LEVEL=$(logstring_tr "${LOG_LEVEL_DEFAULT}")
        clog ERR "Provided Log level '${LOG_LEVEL}' is not known. Defaulting to '${LOG_LEVEL_DEFAULT}'."
    fi
    export LOG_LEVEL
    [[ ${_LOG_LEVEL} -ge 8 ]] && set -x
fi

##############################
# End Logging provisions
# Usage: clog <errorlevel> <log string>
# log levels are the usual ones. 0 EMERG/EMERGENCY to 7 DEBUG
##############################

# First off, check all volumes
clog DEBUG "Enummerating (via /etc/mtab) all docker volumes under /mnt."

MOUNTLIST="$(awk '{print $2}' /etc/mtab | grep -E '^/mnt/')"

# Stop on error, displaying warnig at interval. Stop here does not mean
# stop the script, or the container, but prevent further execution of
# the compose.yaml by blocking further processing. (See above)
function error_stop() {
    trap 'echo -n "."' INT
    while true; do
        for ALERTSTR in $* ; do
            clog ${ERROR_STOP_LEVEL:-ALERT} "${ALERTSTR}"
        done
        clog ${ERROR_STOP_LEVEL:-ALERT} "Will now stop. Shut this down by issueing 'docker compose down'"
        sleep ${ERROR_STOP_INTERVALSEC:-10}
    done
} # error_stop

# Pre-flight checks

# Fist off: check if all mountpoint (e.g. docker volumes) are mounted directly under /mnt
for MPOINT in ${MOUNTLIST} ; do
    if echo "${MPOINT}" | grep -qE '^/mnt/[^/]+/.*$' ; then
        error_stop "There are mounts deeper than first level under /mnt. Mountpoint: ${MPOINT}"
    fi
done

# Now check contents of every mount point and create list to be processed.
for MPOINT in ${MOUNTLIST} ; do
    if [[ -f "${MPOINT}/.subvols" ]] ; then
        clog DEBUG "Volume '${MPOINT}' already done. Skipping."
    elif awk '{print $2,$4}' /etc/mtab | grep -E '^'${MPOINT}'\s+ro,' ; then
        error_stop  "Volume '${MPOINT}' is read-only. Cannot continue."
    elif [[ -f "${MOUNTPOINT}/.subvols_error" ]] ; then
        error_stop  "Volume '${MPOINT}' is failed in earlyer run. Cannot continue until fixed."
    elif [[ -f "${MOUNTPOINT}/@" ]] ; then
        error_stop  "Directory '@' exists in '${MPOINT}'. Cannot continue until fixed."
    elif [[ -f "${MOUNTPOINT}/.subvols_error" ]] ; then
        error_stop  "Volume '${MPOINT}' is failed in earlyer run. Cannot continue until fixed."
    else
        clog INFO "Volume '${MPOINT}' is ready to be converted."
    fi
done

for MPOINT in ${MOUNTLIST} ; do
    ALL_MOUNTS=$((ALL_MOUNTS+1))
    if ! [[ -f "${MPOINT}/.subvols" ]] ; then
        clog INFO "Processing volume '${MPOINT}' for conversion."
        case $(grep -E '^\S+\s+'${MPOINT}'\s+' /etc/mtab | awk '{print $3}') in
            btrfs )
                # Here BTRFS Conversion takes place
                clog DEBUG "'${MPOINT}' is on an btrfs subvolume."
                if btrfs subvolume create ${MPOINT}/@ ;  then
                    clog DEBUG "'${MPOINT}/@' subvolume created."
                else
                    echo "Error $? creating subvolume '@' here." > ${MPOINT}/.subvols_error
                    error_stop "Creation of btrfs subvolume '${MPOINT}/@' failed."
                fi
                # Fist check if we need to do anything (e.g. if we are not a new volume).
                if [[ $(ls -1A "${MPOINT}" | wc -l) -eq 0 ]] ; then
                    clog INFO "'${MPOINT}' is a new volume. No moving of data needed."
                else
                    # Just doing a (thin)copy-and remove, instead of a move here. This ensures there are no subvolumes anywhere in the docker volume.
                    clog DEBUG "'${MPOINT}', copying into subvolume '@'"
                    if find ${MPOINT} -mindepth 1 -maxdepth 1 -not -name '@' -exec cp --reflink=always --target-directory ${MPOINT}/@ \{\} \; ; then
                        clog DEBUG "'${MPOINT}' data copied to subvolume @."
                    else
                        echo "Error $? copying data into subvolume '@' here." > ${MPOINT}/.subvols_error
                        error_stop "Copying data to subvolume '${MPOINT}/@' failed."
                    fi
                    clog DEBUG "'${MPOINT}', removing old data."
                    if find ${MPOINT} -mindepth 1 -maxdepth 1 -not -name '@' -exec rm -rf \{\} \; ; then
                        clog DEBUG "'${MPOINT}' old data removed."
                    else
                        echo "Error $? removing old data from here. Copying finished okay" > ${MPOINT}/.subvols_error
                        error_stop "Removing old data from volume root '${MPOINT}' failed."
                    fi
                fi
                if btrfs subvolume create ${MPOINT}/@snapshots ;  then
                    clog DEBUG "'${MPOINT}/@snapshots' subvolume created."
                else
                    echo "Error $? creating subvolume '@snapshots' here." > ${MPOINT}/.subvols_error
                    error_stop "Creation of btrfs subvolume '${MPOINT}/@snapshots' failed."
                fi
                clog DEBUG "'${MPOINT}, Writing '.subvols' to indicate all went well."
                touch ${MPOINT}/.subvols
                ;;
            * )
                # Here non-btrfs Conversion takes place
                clog DEBUG "'${MPOINT}' is NOT on an btrfs subvolume."
                if mkdir ${MPOINT}/@ ;  then
                    clog DEBUG "'${MPOINT}/@' directory created."
                else
                    echo "Error $? creating directory '@' here." > ${MPOINT}/.subvols_error
                    error_stop "Creation of directory '${MPOINT}/@' failed."
                fi
                # Fist check if we need to do anything (e.g. if we are not a new volume).
                if [[ $(ls -1A "${MPOINT}" | wc -l) -eq 0 ]] ; then
                    clog INFO "'${MPOINT}' is a new volume. No moving of data needed."
                else
                    clog DEBUG "'${MPOINT}', moving into directory '@'"
                    if find ${MPOINT} -mindepth 1 -maxdepth 1 -not -name '@' -exec mv --target-directory ${MPOINT}/@ \{\} \; ; then
                        clog DEBUG "'${MPOINT}' data moved to directory @."
                    else
                        echo "Error $? moving data into directory '@' here." > ${MPOINT}/.subvols_error
                        error_stop "Moving data to directory '${MPOINT}/@' failed."
                    fi
                fi
                clog DEBUG "'${MPOINT}, Writing '.subvols' to indicate all went well."
                touch ${MPOINT}/.subvols
                ;;
        esac
        CHG_MOUNTS=$((CHG_MOUNTS+1))
    fi
done

clog INFO "Of all the ${ALL_MOUNTS} mountpoints, ${CHG_MOUNTS} successfully converted."
