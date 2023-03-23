#!/bin/bash

# fork: https://github.com/bashdot/bashdot

VERSION=4.1.7

#
# variables
#
STOW_DIR=$(pwd)
STOW_TARGET=$HOME
STOW_PROFILE=()
STOW_DELETE_PROFILE=()
STOW_RESTOW=false
STOW_DELETE=false
STOW_INSTALL=true
STOW_NO_FOLDING=false

STOW_IGNORE='^\.$|^\.\.$|^changelog|^contributing|^dockerfile|^icon|^license|^makefile|^readme|^.git'

LOGGER_FMT=${LOGGER_FMT:="%Y-%m-%d"}
LOGGER_LVL=${LOGGER_LVL:="info"}

if [ -n "$BASHDOT_LOG_LEVEL" ]; then
    LOGGER_LVL=$BASHDOT_LOG_LEVEL
fi

_help() {
    echo ""
    echo " SYNOPSIS:"
    echo ""
    echo "     stow [OPTION ...] [-D|-S|-R] PACKAGE ..."
    echo ""
    echo " OPTIONS:"
    echo ""
    echo "     -d DIR, --dir=DIR     Set stow dir to DIR (default is current dir)"
    echo "     -t DIR, --target=DIR  Set target to DIR (default is parent of stow dir)"
    echo ""
    echo "     -S, --stow            Stow the package names that follow this option"
    echo "     -D, --delete          Unstow the package names that follow this option"
    echo "     -R, --restow          Restow (like stow -D followed by stow -S)"
    echo ""
    echo "     --ignore=REGEX        Ignore files ending in this Perl regex"
    echo "     --defer=REGEX         Don't stow files beginning with this Perl regex"
    echo "                           if the file is already stowed to another package"
    echo "     --override=REGEX      Force stowing files beginning with this Perl regex"
    echo "                           if the file is already stowed to another package"
    echo "     --adopt               (Use with care!)  Import existing files into stow package"
    echo "                           from target.  Please read docs before using."
    echo "     -p, --compat          Use legacy algorithm for unstowing"
    echo ""
    echo "     -n, --no, --simulate  Do not actually make any filesystem changes"
    echo "     -v, --verbose[=N]     Increase verbosity (levels are from 0 to 5;"
    echo "                             -v or --verbose adds 1; --verbose=N sets level)"
    echo "     -V, --version         Show stow version number"
    echo "     -h, --help            Show this help"
    echo ""
}

###### verify

exit_if_profile_directories_contain_invalid_characters() {
    profile_dir=$1
    if [ ! -d $profile_dir ]; then
        log error "Directory '$profile_dir' not exist."
        exit 1
    fi

    if ls "$profile_dir" | grep -E '[[:space:]:,/\]'; then
        log error "Files in '$profile_dir' contain invalid characters."
        exit 1
    fi
    # log info "[profile_directories_contain_invalid_characters] '$1' verified!!"
}

exit_if_invalid_directory_name() {
    dir=$1
    if ! echo "$dir" | grep "^[/.a-zA-Z0-9_-]*$" >/dev/null; then
        log error "Current working directory '$dir' has an invalid character. The directory you are in when you install a profile must have alpha numeric characters, with only dashes, dots or underscores."
        exit 1
    fi
    # log info "[invalid_directory_name] '$1' verified!!"
}

exit_if_invalid_profile_name() {
    profile=$1
    if ! echo "$profile" | grep "^[a-zA-Z0-9_-]*$" >/dev/null; then
        log error "Invalid profile name '$profile'. Profiles must be alpha numeric with only dashes or underscores."
        exit 1
    fi
    # log info "[invalid_profile_name] '$1' verified!!"
}

check_valid_profile_name() {
    profile=$1
    if ! echo "$profile" | grep "^[a-zA-Z0-9_-]*$" | grep -v "^$\|^--restow$\|^--delete$\|^--stow$" >/dev/null; then
        IFS=''
        echo -en "false"
    else
        IFS=''
        echo -en "true"
    fi
}
## logger

log() {
    action=$1 && shift

    case "$action" in
    debug) [[ "$LOGGER_LVL" =~ debug ]] && echo "$(date "+${LOGGER_FMT}") - DEBUG - $@" 1>&2 ;;
    info) [[ "$LOGGER_LVL" =~ debug|info ]] && echo "$(date "+${LOGGER_FMT}") - INFO - $@" 1>&2 ;;
    warn) [[ "$LOGGER_LVL" =~ debug|info|warn ]] && echo "$(date "+${LOGGER_FMT}") - WARN - $@" 1>&2 ;;
    error) [[ ! "$LOGGER_LVL" =~ none ]] && echo "$(date "+${LOGGER_FMT}") - ERROR - $@" 1>&2 ;;
    esac

    true
}

####

_link() {
    source_file=$1
    target_file=$2

    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
        existing=$(readlink "$target_file")
        log debug "Evaluating if '$target_file' which links to '$existing' matches desired target '$source_file'."

        if [ "$existing" == "$source_file" ]; then
            log info "File '$target_file' already links to '$source_file', continuing."
            return
        fi

        log error "File '$target_file' already exists, exiting."
        return
    fi

    log debug "'$target_file' does not link to desired target '$source_file'."
    log info "Linking '$source_file' to '$target_file'."

    _target_dir_name="$(dirname "$target_file")"
    echo "target dir: $_target_dir_name"

    if [ ! -d "${_target_dir_name}" ]; then
        echo "mkdir -p $_target_dir_name"
        mkdir -p $_target_dir_name
    fi

    ln -s "$source_file" "$target_file"
}

_get_no_folding_list() {
    echo "INSALL--NO--FOLDING-" >&2
    local profile_dir="$1"
    local _files=()

    # exit_if_profile_directories_contain_invalid_characters "$profile_dir"

    if [ ! -d "$profile_dir" ]; then
        log error "Profile '$profile_dir' directory does not exist."
        exit 1
    fi

    log info "Adding dotfiles profile '$profile_dir'."
    for _f in $(find $profile_dir -type f); do
        echo "." >&2
        echo "[$_f]" >&2

        _rel_path="${_f/$profile_dir\//}"
        if $(echo "${_rel_path}" | grep -E -i "$STOW_IGNORE" >/dev/null 2>&1); then
            echo "--($_rel_path)" >&2
            continue
        fi

        _filename="${_f##*/}"
        if $(echo "${_filename}" | grep -E -i "$STOW_IGNORE" >/dev/null 2>&1); then
            echo "---($_filename)" >&2
            continue
        fi

        _file="${_f/$profile_dir/$STOW_TARGET}"
        echo "......................................................   $_file" >&2

        _files+=("${_rel_path}")
    done

    echo "# ${_files[*]}" >&2
    IFS="" echo -n "${_files[@]}"
    # exit # .local/share/xj .local/share/tt/ttloc .local/lss/share/xj .local/lss/share/tt/ttloc .ttrc .ff/xxx
}

_get_list() {
    echo "INSALL-----" >&2
    local profile_dir=$1
    local _files=()

    # exit_if_profile_directories_contain_invalid_characters "$profile_dir"

    if [ ! -d "$profile_dir" ]; then
        log error "Profile '$profile_dir' directory does not exist."
        exit 1
    fi

    log info "Adding dotfiles profile '$profile_dir'."

    # _IGNORE='^.config$|^.cache$|^.local$|^.local/share$|^.local/state$'
    # _IGNORE="$_IGNORE|^$profile_dir$"

    _IGNORE="^.config$|^.cache$|^.local$|^.local/share$|^.local/state$|^$profile_dir$"

    echo $_IGNORE >&2

    _tmp_list=()
    # for _file in $(find $profile_dir -maxdepth 2); do
    for _file in $(find $profile_dir); do
        _rel_path="${_file/$profile_dir\//}"
        echo "__________ $_file ($_rel_path)" >&2

        if $(echo "${_rel_path}" | grep -E -i "$STOW_IGNORE" >/dev/null 2>&1); then
            echo "---($_rel_path)" >&2
            continue
        fi

        if $(echo "${_rel_path}" | grep -E -i "$_IGNORE" >/dev/null 2>&1); then
            echo "--($_rel_path)" >&2
            continue
        fi
        _tmp_list+=("${_rel_path}")
    done

    for _f in ${_tmp_list[@]}; do
        echo "==$_f" >&2
        for _d in ${_tmp_list[@]}; do
            if [[ "$_f" == *"$_d"* ]] && [[ "$_f" != "$_d" ]]; then
                echo "It's there. $_f $_d" >&2
                _f=""
            fi
        done

        if [ ! -z $_f ]; then
            echo "+pass+ $_f" >&2
            _files+=("${_f}")
        fi
    done

    echo "'''''''''''''' ${_files[*]}" >&2
    IFS="" echo -n "${_files[@]}"
}

install() {
    local _profile=$1
    local _files=$2[@]
    log info "Installing dotfiles from '$profile_dir'."
    for _f in ${!_files}; do
        echo ""
        echo "[link] $STOW_DIR/$_profile/$_f $STOW_TARGET/$_f"
        _link $STOW_DIR/$_profile/$_f $STOW_TARGET/$_f
        echo ""
    done
    echo "install done!!!"
}

uninstall() {
    local _profile=$1
    local _files=$2[@]

    # check _files exist?
    # unlink _files
    for _f in ${!_files}; do
        echo ""
        echo "[unlink] $STOW_DIR/$_profile/$_f $STOW_TARGET/$_f"
        # _link $STOW_DIR/$_profile/$_f $STOW_TARGET/$_f
        echo ""
    done

    # check dir empty
    # rm -rf dir
}

#
# parse args
#

while [[ $# -gt 0 ]]; do
    case $1 in
    # Set stow dir to DIR (default is current dir)
    -d)
        STOW_DIR="$2"
        shift # past argument
        shift # past value
        ;;
    --dir=*)
        __sp=(${1//=/ })
        STOW_DIR=${__sp[1]}
        shift # past argument
        ;;
    # Set target to DIR (default is parent of stow dir)
    -t)
        STOW_TARGET="$2"
        shift # past argument
        shift # past value
        ;;
        # Stow the package names that follow this option
    --target=*)
        __sp=(${1//=/ })
        STOW_TARGET=${__sp[1]}
        shift # past argument
        ;;
    -S | --stow)
        # Stow the package names that follow this option
        STOW_INSTALL=true
        shift # past argument

        while $(check_valid_profile_name $1) && [[ $# -gt 0 ]]; do
            STOW_PROFILE+=("$1")
            shift # past value
        done
        ;;
    -D | --delete)
        # Unstow the package names that follow this option
        STOW_DELETE=true
        shift # past argument

        while $(check_valid_profile_name $1) && [[ $# -gt 0 ]]; do
            STOW_DELETE_PROFILE+=("$1")
            shift # past value
        done
        ;;
    -R | --restow)
        # Restow (like stow -D followed by stow -S)
        STOW_RESTOW=true
        shift # past argument
        ;;
    --no-folding)
        STOW_NO_FOLDING=true
        shift # past argument
        ;;
    -* | --*)
        _help
        exit 1
        ;;
    *)
        while $(check_valid_profile_name $1) && [[ $# -gt 0 ]]; do
            STOW_PROFILE+=("$1")
            shift # past value
        done
        # STOW_PROFILE+=("$1")
        # shift # past argument
        ;;
    esac
done

# set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
echo "--------------------------------------------------"

printf "stow dir         : %s\n" "${STOW_DIR}"
printf "stow target      : %s\n" "${STOW_TARGET}"
printf "stow profile     : %s\n" "${STOW_PROFILE[*]}"
printf "stow del profile : %s\n" "${STOW_DELETE_PROFILE[*]}"
printf "delete           : %s\n" "${STOW_DELETE}"
printf "install          : %s\n" "${STOW_INSTALL}"
printf "restow           : %s\n" "${STOW_RESTOW}"
printf "no-folding       : %s\n" "${STOW_NO_FOLDING}"

echo "--------------------------------------------------"

exit_if_invalid_directory_name "${STOW_DIR}"

# for _p in ${STOW_PROFILE[@]}; do
#     exit_if_invalid_profile_name "${_p}"
# done

for _p in ${STOW_PROFILE[@]}; do
    exit_if_profile_directories_contain_invalid_characters "${STOW_DIR}/${_p}"
done

echo "--------------------------------------------------"

stow_delete() {
    if [ ! $# -gt 0 ]; then
        echo "error"
        return
    fi

    _list_func=_get_list

    if $STOW_NO_FOLDING; then
        _list_func=_get_no_folding_list
    fi

    for _d in $@; do
        echo "list $_li"
        _list=$($_list_func "$STOW_DIR/$_li")

        echo "delete $_li"
        echo "list: ${_list[*]}"
        # uninstall $_li _list
    done
}

stow_install() {
    if [ ! $# -gt 0 ]; then
        echo "error"
        return
    fi

    _list_func=_get_list

    if $STOW_NO_FOLDING; then
        _list_func=_get_no_folding_list
    fi

    for _li in $@; do
        echo "list $_li"
        _list=$($_list_func "$STOW_DIR/$_li")

        echo "install $_li"
        echo "list: ${_list[*]}"
        install $_li _list
    done
}

echo "[proc] stow del"
if $STOW_DELETE; then
    if [ ! -z ${STOW_DELETE_PROFILE} ]; then
        stow_delete ${STOW_DELETE_PROFILE[@]}
    else
        log warn "delete missing proifle"
    fi
fi

if $STOW_RESTOW; then
    if [ ! -z ${STOW_PROFILE} ]; then
        stow_delete ${STOW_PROFILE[@]}
    else
        log warn "delete missing proifle"
    fi
fi

echo "[proc] stow install"

if $STOW_INSTALL || $STOW_RESTOW; then
    if [ ! -z ${STOW_PROFILE} ]; then
        stow_install ${STOW_PROFILE[@]}
    else
        log warn "install missing proifle"
    fi
fi

# printf "restow  : %s" "${STOW_DELETE}"
