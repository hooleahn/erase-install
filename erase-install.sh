#!/bin/zsh 
# shellcheck shell=bash
# shellcheck disable=SC2001
# this is to use sed in the case statements
# shellcheck disable=SC2034,SC2296
# these are due to the dynamic variable assignments used in the localization strings

: <<DOC
==============================================================================
erase-install.sh
==============================================================================
by Graham Pugh

WARNING. This is a self-destruct script. Do not try it out on your own device!

See README.md and the GitHub repo's Wiki for details on use.

It is recommended to use the package installer of this script. It contains 
swiftDialog and mist, which are required for most of the use-cases of this script.

This script can, however, also be run standalone.
It will download and install swiftDialog if needed and not found.
It will also download mist if it is not found.
Suppress the downloads with the --no-curl option.

Requirements:
- macOS 12.4+
- macOS 10.13.4+ (for --erase option)
- macOS 10.15+ (for --fetch-full-installer option, and for mist)
- macOS 11+ (for dialogs)
- Device file system is APFS
DOC

# =============================================================================
# Variables 
# =============================================================================

# script name
script_name="erase-install"
pkg_label="com.github.grahampugh.erase-install"

# Version of this script
version="30.2"

# Directory in which to place the macOS installer. Overridden with --path
installer_directory="/Applications"

# Default working directory (may be overridden by the --workdir parameter)
workdir="/Library/Management/erase-install"

# Default logdir
logdir="/Library/Management/erase-install/log"

# mist tool
mist_bin="/usr/local/bin/mist"

# URL for downloading dialog (with tag version)
# This ensures a compatible mist version is used if not using the package installer
mist_version_required="1.14"
mist_download_url="https://github.com/ninxsoft/mist-cli/releases/download/v${mist_version_required}/mist-cli.${mist_version_required}.pkg"

# URL for downloading swiftDialog (with tag version)
# This ensures a compatible swiftDialog version is used if not using the package installer
swiftdialog_version_required="2.2.1-4591"
swiftdialog_tag_required=$(cut -d"-" -f1 <<< "$swiftdialog_version_required")
dialog_download_url="https://github.com/bartreardon/swiftDialog/releases/download/v${swiftdialog_tag_required}/dialog-${swiftdialog_version_required}.pkg"

# swiftDialog variables
dialog_app="/Library/Application Support/Dialog/Dialog.app"
dialog_bin="/usr/local/bin/dialog"
dialog_log=$(/usr/bin/mktemp /var/tmp/dialog.XXX)
dialog_output="/var/tmp/dialog.json"

# swiftDialog icons
dialog_dl_icon="/System/Library/PrivateFrameworks/SoftwareUpdate.framework/Versions/A/Resources/SoftwareUpdate.icns"
dialog_confirmation_icon="/System/Applications/System Settings.app"
dialog_warning_icon="SF=xmark.circle,colour=red"
dialog_fmm_icon="/System/Library/PrivateFrameworks/AOSUI.framework/Versions/A/Resources/findmy.icns"

# default app and package names for mist
default_downloaded_app_name="Install %NAME%.app"
default_downloaded_pkg_name="InstallAssistant-%VERSION%-%BUILD%.pkg"
default_downloaded_pkg_id="com.apple.InstallAssistant.%VERSION%.%BUILD%.pkg"

# =============================================================================
# Functions 
# functions are listed alphabetically
# =============================================================================

# -----------------------------------------------------------------------------
# Open a dialog window to ask for the user's username and password.
# This is required on Apple Silicon Mac
# -----------------------------------------------------------------------------
ask_for_credentials() {
    # set the dialog command arguments
    get_default_dialog_args "utility"
    dialog_args=("${default_dialog_args[@]}")
    dialog_args+=(
        "--title"
        "${dialog_window_title}"
        "--icon"
        "${dialog_confirmation_icon}"
        "--overlayicon"
        "SF=person.badge.key.fill,colour=grey"
        "--iconsize"
        "128"
        "--textfield"
        "Username,prompt=$current_user"
        "--textfield"
        "Password,secure"
        "--button1text"
        "Continue"
    )
    if [[ "$erase" == "yes" ]]; then
        dialog_args+=(
            "--message"
            "${(P)dialog_erase_credentials}"
        )
    else
        dialog_args+=(
            "--message"
            "${(P)dialog_reinstall_credentials}"
        )
    fi
    if [[ $max_password_attempts != "infinite" ]]; then
        dialog_args+=("-2")
    fi

    # run the dialog command
    "$dialog_bin" "${dialog_args[@]}" 2>/dev/null > "$dialog_output"
}

# -----------------------------------------------------------------------------
# Dialogue to disable Find My Mac. 
# Called when --check-fmm option is used.
# Not used in --silent mode.
# -----------------------------------------------------------------------------
check_fmm() {
    # default Finy My wait timer to 60 seconds
    if [[ ! $fmm_wait_timer ]]; then 
        fmm_wait_timer=300
    fi

    if ! nvram -xp | grep fmm-mobileme-token-FMM > /dev/null ; then
        writelog "[check_fmm] OK - Find My not enabled"
    elif [[ $silent ]]; then
        writelog "[check_fmm] ERROR - Find My enabled, cannot continue."
        echo
        exit 1
    else
        writelog "[check_fmm] WARNING - Find My enabled"
        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        # original icon: ${dialog_confirmation_icon}
        dialog_args+=(
            "--title"
            "${(P)dialog_fmm_title}"
            "--icon"
            "${dialog_confirmation_icon}"
            "--overlayicon"
            "${dialog_fmm_icon}"
            "--iconsize"
            "128"
            "--message"
            "${(P)dialog_fmm_desc}"
            "--timer"
            "${fmm_wait_timer}"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null & sleep 0.1

        # now count down while checking for power
        while [[ "$fmm_wait_timer" -gt 0 ]]; do
            if ! nvram -xp | grep fmm-mobileme-token-FMM > /dev/null ; then
                writelog "[check_fmm] OK - Find My not enabled"
                # quit dialog
                writelog "[check_fmm] Sending quit message to dialog log ($dialog_log)"
                /bin/echo "quit:" >> "$dialog_log"
                return
            fi
            sleep 1
            ((fmm_wait_timer--))
        done

        # quit dialog
        writelog "[check_power_status] Sending quit message to dialog log ($dialog_log)"
        /bin/echo "quit:" >> "$dialog_log"

        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        dialog_args+=(
            "--title"
            "${(P)dialog_fmm_title}"
            "--icon"
            "${dialog_confirmation_icon}"
            "--iconsize"
            "128"
            "--overlayicon"
            "SF=laptopcomputer.trianglebadge.exclamationmark,colour=red"
            "--message"
            "${(P)dialog_fmmenabled_desc}"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null

        writelog "[wait_for_power] ERROR - Finy My still enabled after waiting for ${fmm_wait_timer}s, cannot continue."
        echo
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Download mist if not present and not --silent mode
# -----------------------------------------------------------------------------
check_for_mist() {
    if [[ -f "$mist_bin" ]]; then
        writelog "[check_for_mist] mist is installed ($mist_bin)"
    else
        if [[ ! $no_curl ]]; then
            writelog "[check_for_mist] Downloading mist-cli..."
            if /usr/bin/curl -L "$mist_download_url" -o "$workdir/mist-cli.pkg" ; then
                if ! installer -pkg "$workdir/mist-cli.pkg" -target / ; then
                    writelog "[check_for_mist] mist installation failed"
                fi
            else
                writelog "[check_for_mist] mist download failed"
            fi
        fi
        # check it did actually get downloaded
        if [[ -f "$mist_bin" ]]; then
            writelog "[check_for_mist] mist is installed"
        else
            writelog "[check_for_mist] Could not download dialog."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Download dialog if not present and not --silent mode
# -----------------------------------------------------------------------------
check_for_swiftdialog_app() {
    # swiftDialog 2.3 and higher are incompatible with macOS 11. Remove this version if present.
    if [[ $(echo "$system_version_major < 12" | bc) == 1 && -d "$dialog_app" && -f "$dialog_bin" ]]; then
        dialog_string=$("$dialog_bin" --version)
        dialog_minor_vers=$(cut -d. -f1,2 <<< "$dialog_string")
        if [[ $(echo "$dialog_minor_vers > 2.2" | bc) -eq 1 ]]; then
            writelog "[check_for_swiftdialog_app] swiftDialog 2.3 or above is not compatible with macOS 11. Removing 2.3..."
            app_directory="/Library/Application Support/Dialog"
            bin_shortcut="/usr/local/bin/dialog"
            /bin/rm -rf "$app_directory" 
            /bin/rm -f "$bin_shortcut" /var/tmp/dialog.*
        fi
    fi

    # now check for any version of swiftDialog and download if not present
    if [[ -d "$dialog_app" && -f "$dialog_bin" ]]; then
        writelog "[check_for_swiftdialog_app] swiftDialog is installed ($dialog_app)"
    else
        if [[ ! $no_curl ]]; then
            writelog "[check_for_swiftdialog_app] Downloading swiftDialog..."
            if /usr/bin/curl -L "$dialog_download_url" -o "$workdir/dialog.pkg" ; then
                if ! installer -pkg "$workdir/dialog.pkg" -target / ; then
                    writelog "[check_for_swiftdialog_app] swiftDialog installation failed"
                fi
            else
                writelog "[check_for_swiftdialog_app] swiftDialog download failed"
                exit 1
            fi
        fi
        # check it did actually get downloaded
        if [[ -d "$dialog_app" && -f "$dialog_bin" ]]; then
            writelog "[check_for_swiftdialog_app] swiftDialog is installed"
        else
            writelog "[check_for_swiftdialog_app] Could not download swiftDialog."
            exit 1
        fi
    fi

    # ensure log file is writable
    writelog "[check_for_swiftdialog_app] Creating dialog log ($dialog_log)..."
    /usr/bin/touch "$dialog_log"
    /usr/sbin/chown "${current_user}:wheel" "$dialog_log"
    /bin/chmod 666 "$dialog_log"
}

# -----------------------------------------------------------------------------
# Determine if the amount of free and purgable drive space is sufficient for 
# the upgrade to take place.
# The JavaScript osascript is used to give us the purgeable space as this is 
# not available via any shell commands (Thanks to Pico). 
# However, this does not work at the login window, so then we have to fall 
# back to using df -h, which will not include purgeable space.
# -----------------------------------------------------------------------------
check_free_space() {
    free_disk_space=$(osascript -l 'JavaScript' -e "ObjC.import('Foundation'); var freeSpaceBytesRef=Ref(); $.NSURL.fileURLWithPath('/').getResourceValueForKeyError(freeSpaceBytesRef, 'NSURLVolumeAvailableCapacityForImportantUsageKey', null); Math.round(ObjC.unwrap(freeSpaceBytesRef[0]) / 1000000000)")

    if [[ ! "$free_disk_space" ]] || [[ "$free_disk_space" == 0 ]]; then
        # fall back to df -h if the above fails
        free_disk_space=$(df -Pk . | column -t | sed 1d | awk '{print $4}' | xargs -I{} expr {} / 1000000)
    fi

    # if there isn't enough space, then we show a failure message to the user
    if [[ $free_disk_space -ge $min_drive_space ]]; then
        writelog "[check_free_space] OK - $free_disk_space GB free/purgeable disk space detected"
    elif [[ $silent ]]; then
        writelog "[check_free_space] ERROR - $free_disk_space GB free/purgeable disk space detected"
        echo
        exit 1
    else
        writelog "[check_free_space] ERROR - $free_disk_space GB free/purgeable disk space detected"
        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        dialog_args+=(
            "--title"
            "${dialog_window_title}"
            "--icon"
            "${dialog_confirmation_icon}"
            "--iconsize"
            "128"
            "--overlayicon"
            "SF=externaldrive.fill.badge.exclamationmark,colour=red"
            "--message"
            "${(P)dialog_check_desc}"
            "--button1text"
            "${(P)dialog_cancel_button}"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Check the installer validity.
# The Build number in the app Info.plist is often older than the advertised 
# build number, so it's not a great check for checking the validity of the installer
# if we are running --erase, where we might want to be using the same build.
# Since macOS 11, the actual build number is found in the SharedSupport.dmg in 
# com_apple_MobileAsset_MacSoftwareUpdate.xml.
# For older OSs we include a fallback to the older, less accurate 
# Info.plist file.
# -----------------------------------------------------------------------------
check_installer_is_valid() {
    writelog "[check_installer_is_valid] Checking validity of $cached_installer_app."

    # first ensure that an installer is not still mounted from a previous run as it might 
    # interfere with the check
    [[ -d "/Volumes/Shared Support" ]] && diskutil unmount force "/Volumes/Shared Support"

    # now attempt to mount the installer and grab the build number from
    # com_apple_MobileAsset_MacSoftwareUpdate.xml
    if [[ -f "$cached_installer_app/Contents/SharedSupport/SharedSupport.dmg" ]]; then
        if hdiutil attach -quiet -noverify -nobrowse "$cached_installer_app/Contents/SharedSupport/SharedSupport.dmg" ; then
            writelog "[check_installer_is_valid] Mounting $cached_installer_app/Contents/SharedSupport/SharedSupport.dmg"
            sleep 1
            build_xml="/Volumes/Shared Support/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml"
            if [[ -f "$build_xml" ]]; then
                writelog "[check_installer_is_valid] Using Build value from com_apple_MobileAsset_MacSoftwareUpdate.xml"
                installer_build=$(/usr/libexec/PlistBuddy -c "Print :Assets:0:Build" "$build_xml")
                sleep 1
                diskutil unmount force "/Volumes/Shared Support"
            else
                writelog "[check_installer_is_valid] ERROR: com_apple_MobileAsset_MacSoftwareUpdate.xml not found. Check the mount point at /Volumes/Shared Support"
            fi
        else
            writelog "[check_installer_is_valid] Mounting SharedSupport.dmg failed"
        fi
    else
    # if that fails, fallback to the method for 10.15 or less, which is less accurate
        writelog "[check_installer_is_valid] Using DTSDKBuild value from Info.plist"
        if [[ -f "$cached_installer_app/Contents/Info.plist" ]]; then
            installer_build=$( /usr/bin/defaults read "$cached_installer_app/Contents/Info.plist" DTSDKBuild )
        else
            writelog "[check_installer_is_valid] Installer Info.plist could not be found!"
        fi
    fi

    # bail out if we did not obtain a build number
    if [[ $installer_build ]]; then
        # compare the local system's build number with that of the installer app 
        compare_build_versions "$system_build" "$installer_build"
        if [[ $first_build_major_newer == "yes" || $first_build_minor_newer == "yes" ]]; then
            writelog "[check_installer_is_valid] Installer: $installer_build < System: $system_build : invalid build."
            invalid_installer_found="yes"
        elif [[ $first_build_patch_newer == "yes" ]]; then
            writelog "[check_installer_is_valid] Installer: $installer_build < System: $system_build : build might work but if it fails, please obtain a newer installer."
            warning_issued="yes"
            invalid_installer_found="no"
        else
            writelog "[check_installer_is_valid] Installer: $installer_build >= System: $system_build : valid build."
            invalid_installer_found="no"
        fi
    else
        writelog "[check_installer_is_valid] Build of existing installer could not be found, so it is assumed to be invalid."
        invalid_installer_found="yes"
    fi

    working_macos_app="$cached_installer_app"
}

# -----------------------------------------------------------------------------
# Check the validity of an installer pkg.
# packages generated by mist using this script have the name  
# InstallAssistant-VERSION-BUILD.pkg
# Extracting an actual version from the package is slow as the entire package 
# must be unpackaged to read the PackageInfo file, so we just grab it from the 
# filename instead, as mist already did the check.
# -----------------------------------------------------------------------------
check_installer_pkg_is_valid() {
    writelog "[check_installer_pkg_is_valid] Checking validity of $cached_installer_pkg."
    installer_pkg_build=$( basename "$cached_installer_pkg" | sed 's|.pkg||' | cut -d'-' -f3 )

    # compare the local system's build number with that of InstallAssistant.pkg 
    compare_build_versions "$system_build" "$installer_pkg_build"

    if [[ $first_build_newer == "yes" ]]; then
        writelog "[check_installer_pkg_is_valid] Installer: $installer_pkg_build < System: $system_build : invalid build."
        working_installer_pkg="$cached_installer_pkg"
        invalid_installer_found="yes"
    else
        writelog "[check_installer_pkg_is_valid] Installer: $installer_pkg_build >= System: $system_build : valid build."
        working_installer_pkg="$cached_installer_pkg"
        invalid_installer_found="no"
    fi
}

# -----------------------------------------------------------------------------
# Check that a newer installer is available.
# Used with --update.
# This requires mist, so we first check if this is on the system and download 
# if not.
# We are using mist to list all available installers, with
# options for different catalogs and seeds, and whether to include betas or 
# not.
# -----------------------------------------------------------------------------

check_newer_available() {
    # Download mist if not present
    check_for_mist

    # define mist export file location
    mist_export_file="$workdir/mist-list.json"

    # now clear the variables and build the download command
    mist_args=()
    mist_args+=("list")
    mist_args+=("installer")
    mist_args+=("--export")
    mist_args+=("$mist_export_file")
    
    # set the search restriction based on --os, --version or --sameos
    if [[ $prechosen_version ]]; then
        writelog "[check_newer_available] Checking that selected version $prechosen_version is available"
        mist_args+=("$prechosen_version")
    elif [[ $prechosen_os ]]; then
        writelog "[check_newer_available] Restricting to selected OS $prechosen_os"
        mist_args+=("$prechosen_os")
    elif [[ $sameos ]]; then
        writelog "[run_mist] Restricting to selected OS $system_version_major"
        mist_args+=("$system_version_major")
    fi

    if [[ "$skip_validation" != "yes" ]]; then
        mist_args+=("--compatible")
    fi
    mist_args+=("--latest")

    # set alternative catalog if selected
    if [[ $catalogurl ]]; then
        writelog "[check_newer_available] Non-standard catalog URL selected"
        mist_args+=("--catalog-url")
        mist_args+=("$catalogurl")
    elif [[ $catalog ]]; then
        darwin_version=$(get_darwin_from_os_version "$catalog")
        get_catalog
        writelog "[check_newer_available] Non-default catalog selected (darwin version $darwin_version)"
        mist_args+=("--catalog-url")
        mist_args+=("${catalogs[$darwin_version]}")
    elif [[ $beta != "yes" ]]; then
        # we have to restrict the mist-cli search to the production catalog to avoid getting RCs
        darwin_version=$(get_darwin_from_os_version "$system_version_major")
        get_catalog
        writelog "[get_mist_list] Non-default catalog selected (darwin version $darwin_version)"
        mist_args+=("--catalog-url")
        mist_args+=("${catalogs[$darwin_version]}")
    fi

    # include betas if selected
    if [[ $beta == "yes" ]]; then
        writelog "[check_newer_available] Beta versions included"
        mist_args+=("--include-betas")
    fi

    # run in no-ansi mode which is less pretty but better for our logs
    mist_args+=("--no-ansi")

    # run mist with --list and then interrogate the plist
    if "$mist_bin" "${mist_args[@]}" ; then
        newer_build_found="no"
        if [[ -f "$mist_export_file" ]]; then
            available_build=$( ljt 0.build "$mist_export_file" 2>/dev/null )
            if [[ "$available_build" ]]; then
                echo "Comparing latest build found ($available_build) with cached installer build ($installer_build)"
                compare_build_versions "$available_build" "$installer_build"
                if [[ "$first_build_newer" == "yes" ]]; then
                    newer_build_found="yes"
                fi
            fi
        else
            writelog "[check_newer_available] ERROR reading output from mist, cannot continue"
            exit 1
        fi
        if [[ "$newer_build_found" == "no" ]]; then 
            writelog "[check_newer_available] No newer builds found"
        fi
    else
        writelog "[check_newer_available] ERROR running mist, cannot continue"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Check that the password entered matches the actual password.
# The password is required on Apple Silicon Mac (Thanks to Dan Snelson).
# -----------------------------------------------------------------------------
check_password() {
    user="$1"
    password="$2"
    password_matches=$( /usr/bin/dscl /Search -authonly "$user" "$password" )

    if [[ -z "$password_matches" ]]; then
        writelog "[check_password] Success: the password entered is the correct login password for $user."
        password_check="pass"
    else
        writelog "[check_password] ERROR: The password entered is NOT the login password for $user."
        password_check="fail"
        /usr/bin/afplay "/System/Library/Sounds/Basso.aiff"
    fi
}

# -----------------------------------------------------------------------------
# Check if device is on battery or AC power.
# If not, and our power_wait_timer is above 1, allow user to connect to power 
# for the specified time period.
# Acknowledgements: https://github.com/kc9wwh/macOSUpgrade/blob/master/macOSUpgrade.sh
# -----------------------------------------------------------------------------
check_power_status() {
    # default power_wait_timer to 60 seconds
    if [[ ! $power_wait_timer ]]; then 
        power_wait_timer=60
    fi

    if /usr/bin/pmset -g ps | /usr/bin/grep "AC Power" > /dev/null ; then
        writelog "[check_power_status] OK - AC power detected"
    elif [[ $silent ]]; then
        writelog "[wait_for_power] ERROR - No AC power detected, cannot continue."
        echo
        exit 1
    else
        writelog "[check_power_status] WARNING - No AC power detected"
        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        # original icon: ${dialog_confirmation_icon}
        dialog_args+=(
            "--title"
            "${(P)dialog_power_title}"
            "--icon"
            "${dialog_confirmation_icon}"
            "--overlayicon"
            "SF=powerplug.fill,colour=red"
            "--iconsize"
            "128"
            "--message"
            "${(P)dialog_power_desc}"
            "--timer"
            "${power_wait_timer}"
        )
        # run the dialog command (stderr to dev/null to prevent Xfont errors)
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null & sleep 0.1

        # now count down while checking for power
        while [[ "$power_wait_timer" -gt 0 ]]; do
            if /usr/bin/pmset -g ps | /usr/bin/grep "AC Power" > /dev/null ; then
                writelog "[check_power_status] OK - AC power detected"
                # quit dialog
                writelog "[check_power_status] Sending quit message to dialog log ($dialog_log)"
                /bin/echo "quit:" >> "$dialog_log"
                return
            fi
            sleep 1
            ((power_wait_timer--))
        done

        # quit dialog
        writelog "[check_power_status] Sending quit message to dialog log ($dialog_log)"
        /bin/echo "quit:" >> "$dialog_log"

        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        dialog_args+=(
            "--title"
            "${(P)dialog_power_title}"
            "--icon"
            "${dialog_confirmation_icon}"
            "--iconsize"
            "128"
            "--overlayicon"
            "SF=powerplug.fill,colour=red"
            "--message"
            "${(P)dialog_nopower_desc}"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null

        writelog "[wait_for_power] ERROR - No AC power detected after waiting for ${power_wait_timer}s, cannot continue."
        echo
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Compare build numbers.
# This compares build numbers based on the convention of XXAY(YYY)b, where
# - XX is the Darwin number
# - A is the build letter, where A typically relates to XX.0, B to XX.1, etc.
# - Y(YYY) is a minor build number which can be anything from 1 to a four-
#   digit number. Typically any 4-digit number refers to a beta, or a forked
#   build which sometimes occurs when new Mac models are relased.
# - b is a lower-case letter reserved for beta builds.
#
# Darwin numbers are as follows:
# - macOS 10.14 - Darwin no. 18
# - macOS 10.15 - Darwin no. 19
# - macOS 11    - Darwin no. 20
# - macOS 12    - Darwin no. 21
# - macOS 13    - Darwin no. 22
# 
# This function determines if the OS, minor version or patch versions match.
# -----------------------------------------------------------------------------
compare_build_versions() {
    first_build="$1"
    second_build="$2"

    first_build_darwin=${first_build:0:2}
    second_build_darwin=${second_build:0:2}
    first_build_letter=${first_build:2:1}
    second_build_letter=${second_build:2:1}
    first_build_minor=${first_build:3}
    second_build_minor=${second_build:3}
    first_build_minor_no=${first_build_minor//[!0-9]/}
    second_build_minor_no=${second_build_minor//[!0-9]/}
    first_build_minor_beta=${first_build_minor//[0-9]/}
    second_build_minor_beta=${second_build_minor//[0-9]/}

    builds_match="no"
    versions_match="no"
    os_matches="no"

    writelog "[compare_build_versions] Comparing (1) $first_build with (2) $second_build"
    if [[ "$first_build" == "$second_build" ]]; then
        writelog "[compare_build_versions] $first_build = $second_build"
        builds_match="yes"
        versions_match="yes"
        os_matches="yes"
        return
    elif [[ $first_build_darwin -gt $second_build_darwin ]]; then
        writelog "[compare_build_versions] $first_build > $second_build"
        first_build_newer="yes"
        first_build_major_newer="yes"
        return
    elif [[ $first_build_letter > $second_build_letter && $first_build_darwin -eq $second_build_darwin ]]; then
        writelog "[compare_build_versions] $first_build > $second_build"
        first_build_newer="yes"
        first_build_minor_newer="yes"
        os_matches="yes"
        return
    elif [[ ! $first_build_minor_beta && $second_build_minor_beta && $first_build_letter == "$second_build_letter" && $first_build_darwin -eq $second_build_darwin ]]; then
        writelog "[compare_build_versions] $first_build > $second_build (production > beta)"
        first_build_newer="yes"
        first_build_patch_newer="yes"
        versions_match="yes"
        os_matches="yes"
        return
    elif [[ ! $first_build_minor_beta && ! $second_build_minor_beta && $first_build_minor_no -lt 1000 && $second_build_minor_no -lt 1000 && $first_build_minor_no -gt $second_build_minor_no && $first_build_letter == "$second_build_letter" && $first_build_darwin -eq $second_build_darwin ]]; then
        writelog "[compare_build_versions] $first_build > $second_build"
        first_build_newer="yes"
        first_build_patch_newer="yes"
        versions_match="yes"
        os_matches="yes"
        return
    elif [[ ! $first_build_minor_beta && ! $second_build_minor_beta && $first_build_minor_no -ge 1000 && $second_build_minor_no -ge 1000 && $first_build_minor_no -gt $second_build_minor_no && $first_build_letter == "$second_build_letter" && $first_build_darwin -eq $second_build_darwin ]]; then
        writelog "[compare_build_versions] $first_build > $second_build (both betas)"
        first_build_newer="yes"
        first_build_patch_newer="yes"
        versions_match="yes"
        os_matches="yes"
        return
    elif [[ $first_build_minor_beta && $second_build_minor_beta && $first_build_minor_no -ge 1000 && $second_build_minor_no -ge 1000 && $first_build_minor_no -gt $second_build_minor_no && $first_build_letter == "$second_build_letter" && $first_build_darwin -eq $second_build_darwin ]]; then
        writelog "[compare_build_versions] $first_build > $second_build (both betas)"
        first_build_patch_newer="yes"
        first_build_newer="yes"
        versions_match="yes"
        os_matches="yes"
        return
    fi

}

# -----------------------------------------------------------------------------
# Confirmation dialogue. 
# Called when --confirm option is used.
# Not used in --silent mode.
# -----------------------------------------------------------------------------
confirm() {
    # options
    if [[ "$erase" == "yes" ]]; then
        local dialog_title="${(P)dialog_erase_title}"
        local dialog_message="${(P)dialog_erase_confirmation_desc}"
    else
        local dialog_title="${(P)dialog_reinstall_title}"
        local dialog_message="${(P)dialog_reinstall_confirmation_desc}"
    fi

    # set the dialog command arguments
    get_default_dialog_args "utility"
    dialog_args=("${default_dialog_args[@]}")
    dialog_args+=(
        "--title"
        "$dialog_title"
        "--icon"
        "${dialog_confirmation_icon}"
        "--iconsize"
        "128"
        "--overlayicon"
        "SF=person.fill.checkmark,colour=red"
        "--message"
        "$dialog_message"
        "--button1text"
        "${(P)dialog_confirmation_button}"
        "--button2text"
        "${(P)dialog_cancel_button}"
    )
    # run the dialog command
    "$dialog_bin" "${dialog_args[@]}" 2>/dev/null
    confirmation=$?

    if [[ "$confirmation" == "2" ]]; then
        writelog "[$script_name] User DECLINED erase-install or reinstall"
        exit 0
    elif [[ "$confirmation" == "0" ]]; then
        writelog "[$script_name] User CONFIRMED erase-install or reinstall"
    else
        writelog "[$script_name] User FAILED to confirm erase-install or reinstall"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Create a LaunchDaemon that runs startosinstall.
# -----------------------------------------------------------------------------
create_launchdaemon_to_run_startosinstall () {
    local install_arg

    # Name of LaunchDaemon
    # set label and file name for LaunchDaemon
    plist_label="$pkg_label.startosinstall"
    launch_daemon="/Library/LaunchDaemons/$plist_label.plist"

    # Create the plist
    if [[ -f "$launch_daemon" ]]; then
        rm "$launch_daemon" 
    fi

    /usr/libexec/PlistBuddy -c "Add :Label string '$plist_label'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool YES" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :LaunchOnlyOnce bool YES" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :StandardInPath string '$pipe_input'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :StandardOutPath string '$pipe_output'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string '$pipe_output'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$launch_daemon"

    i=0
    for install_arg in "${combined_args[@]}"; do
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:$i string '$install_arg'" "$launch_daemon"
        (( i++ ))
    done
}

# -----------------------------------------------------------------------------
# Create a LaunchDaemon that removes the working directory after a reboot.
# This is used with the --cleanup-after-use option.
# -----------------------------------------------------------------------------
create_launchdaemon_to_remove_workdir () {
    # Name of LaunchDaemon
    plist_label="$pkg_label.remove"
    launch_daemon="/Library/LaunchDaemons/$plist_label.plist"

    # Create the plist
    /usr/libexec/PlistBuddy -c "Add :Label string '$plist_label'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool YES" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :LaunchOnlyOnce bool YES" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string '/bin/rm'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string '-Rf'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string '$workdir'" "$launch_daemon"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string '$launch_daemon'" "$launch_daemon"

    /usr/sbin/chown root:wheel "$launch_daemon"
    /bin/chmod 644 "$launch_daemon"
}

# -----------------------------------------------------------------------------
# Create a pipe
# -----------------------------------------------------------------------------
create_pipe() {
    local pipe_name=${1}
    local pipe_file
    pipe_file=$( /usr/bin/mktemp -u -t "$pipe_name" || exit 12 )
    /usr/bin/mkfifo -m go-rw "$pipe_file" || exit 13
    echo "$pipe_file"
    return 0
}

# -----------------------------------------------------------------------------
# Show progress information in DEPNotify while the installer is being 
# downloaded or prepared, or during reboot-delay, thanks to @andredb90.
# -----------------------------------------------------------------------------
dialog_progress() {
    last_progress_value=0
    current_progress_value=0
    # initialise progress messages
    writelog "Sending to dialog: progresstext:"
    /bin/echo "progresstext: " >> "$dialog_log"
    /bin/echo  "progress: 0" >> "$dialog_log"

    if [[ "$1" == "startosinstall" ]]; then
        # Wait for the preparing process to start and set the progress bar to 100 steps
        until grep -q "Preparing to run macOS Installer..." "$LOG_FILE" ; do
            sleep 0.1
        done
        writelog "Sending to dialog: progresstext: Preparing to run macOS Installer..."
        /bin/echo "progresstext: Preparing to run macOS Installer..." >> "$dialog_log"
        
        until grep -q "Preparing: \d" "$LOG_FILE" ; do
            sleep 2
        done
        /bin/echo "progress: 0" >> "$dialog_log"

        # Until at least 100% is reached, calculate the preparing progress and move the bar accordingly
        until [[ $current_progress_value -ge 100 ]]; do
            until [[ $current_progress_value -gt $last_progress_value ]]; do
                log_value=$(tail -1 "$LOG_FILE" | awk 'END{print substr($NF, 1, length($NF)-3)}')
                # check we got a number
                if [ "$log_value" -eq "$log_value" ] 2>/dev/null; then
                    current_progress_value="$log_value"
                fi
                sleep 1
            done
            /bin/echo "progresstext: Preparing macOS Installer ($current_progress_value%)" >> "$dialog_log"
            /bin/echo "progress: $current_progress_value" >> "$dialog_log"
            last_progress_value=$current_progress_value
        done

    elif [[ "$1" == "mist" ]]; then
        # if mist runs in quiet mode we cannot display download progress
        if [[ "$quiet" == "yes" ]]; then
            /bin/echo "progresstext: Downloading macOS installer..." >> "$dialog_log"
        else
            # Wait for a search message to appear
            until grep -q "SEARCH" "$LOG_FILE" ; do
                sleep 1
            done
            writelog "Sending to dialog: progresstext: Searching for a valid macOS installer..."
            /bin/echo "progresstext: Searching for a valid macOS installer..." >> "$dialog_log"

            # Wait for a Found message to appear
            until grep -q "Found \[" "$LOG_FILE" ; do
                sleep 1
            done
            dialog_found_installer=$(/usr/bin/grep "Found \[" "$LOG_FILE" | sed 's/.*Found \[.*\] //' | sed 's/ \[.*\]//')
            writelog "Sending to dialog: progresstext: Found $dialog_found_installer"
            /bin/echo "progresstext: Found $dialog_found_installer" >> "$dialog_log"

            # Wait for the download to start and set the progress bar to 100 steps
            until grep -q "DOWNLOAD" "$LOG_FILE" ; do
                sleep 2
            done
            writelog "Sending to dialog: progresstext: Downloading $dialog_found_installer"
            /bin/echo "progresstext: Downloading $dialog_found_installer" >> "$dialog_log"
            /bin/echo  "progress: 0" >> "$dialog_log"
            # Wait for the InstallAssistant package to start downloading
            until grep -q "InstallAssistant.pkg" "$LOG_FILE" ; do
                sleep 2
            done
            /bin/echo  "progress: 0" >> "$dialog_log"
            sleep 2
            until [[ $current_progress_value -gt 100 ]]; do
                until [[ $current_progress_value -gt $last_progress_value ]]; do
                    progress_from_mist=$(grep "InstallAssistant" "$LOG_FILE" | tail -1 | cut -d'(' -f2 | cut -d')' -f1)
                    current_progress_value=$(cut -d. -f1 <<< "$progress_from_mist" | sed 's|^0||')
                    sleep 2
                done
                /bin/echo "progresstext: Downloading $dialog_found_installer ($current_progress_value%)" >> "$dialog_log"
                /bin/echo "progress: $current_progress_value" >> "$dialog_log"
                last_progress_value=$current_progress_value
            done
            # if the percentage reaches or goes over 100, show that we are finishing up
            writelog "Sending to dialog: progress: complete"
            /bin/echo "progresstext: Preparing downloaded macOS installer" >> "$dialog_log"
            writelog "Sending to dialog: progresstext: Preparing downloaded macOS installer"
            /bin/echo "progress: complete" >> "$dialog_log"
        fi

    elif [[ "$1" == "fetch-full-installer" ]]; then
        writelog "Sending to dialog: progresstext: Searching for a valid macOS installer..."
        /bin/echo "progresstext: Searching for a valid macOS installer..." >> "$dialog_log"
        # Wait for the download to start and set the progress bar to 100 steps
        until grep -q "Installing:" "$LOG_FILE" ; do
            sleep 2
        done
        writelog "Sending to dialog: progresstext: Downloading $dialog_found_installer"
        /bin/echo "progresstext: Downloading $dialog_found_installer" >> "$dialog_log"
        /bin/echo "progress: 0" >> "$dialog_log"

        # Until at least 100% is reached, calculate the downloading progress and move the bar accordingly
        until [[ "$current_progress_value" -ge 100 ]]; do
            until [ "$current_progress_value" -gt "$last_progress_value" ]; do
                current_progress_value=$(tail -1 "$LOG_FILE" | awk 'END{print substr($NF, 1, length($NF)-3)}')
                sleep 2
            done
            /bin/echo "progresstext: Downloading $dialog_found_installer ($current_progress_value%)" >> "$dialog_log"
            /bin/echo "progress: $current_progress_value" >> "$dialog_log"
            last_progress_value=$current_progress_value
        done
        # if the percentage reaches or goes over 100, show that we are finishing up
        writelog "Sending to dialog: progresstext: Preparing downloaded macOS installer"
        /bin/echo "progresstext: Preparing downloaded macOS installer" >> "$dialog_log"
        writelog "Sending to dialog: progress: complete"
        /bin/echo "progress: complete" >> "$dialog_log"

    elif [[ "$1" == "reboot-delay" ]]; then
        # Countdown seconds to reboot (a bit shorter than rebootdelay)
        countdown=$((rebootdelay-2))
        /bin/echo "progress: $countdown" >> "$dialog_log"
        until [ "$countdown" -eq 0 ]; do
            sleep 1
            current_progress_value=$countdown
            /bin/echo "progresstext: Computer will be restarted in $countdown seconds" >> "$dialog_log"
            /bin/echo "progress: $countdown" >> "$dialog_log"
            ((countdown--))
        done
    fi
}

# -----------------------------------------------------------------------------
# Search for an existing downloaded installer.
# This checks first for a DMG or sparseimage in the working directory, then
# for an Install macOS X.app in the /Applications folder, and then for an 
# InstallAssistant.pkg in the working directory.
# Note that multiple installers left around on the device can cause unexpected
# results.  
# -----------------------------------------------------------------------------
find_existing_installer() {
    # First let's see if this script has been run before and left an installer
    cached_installer_app=$( find "$installer_directory" -maxdepth 1 -name "Install macOS*.app" -type d -print -quit 2>/dev/null )
    cached_installer_app_in_workdir=$( find "$workdir" -maxdepth 1 -name "Install macOS*.app" -type d -print -quit 2>/dev/null )
    cached_installer_pkg=$( find "$workdir" -maxdepth 1 -name "InstallAssistant*.pkg" -type f -print -quit 2>/dev/null )
    cached_dmg=$( find "$workdir" -maxdepth 1 -name "*.dmg" -type f -print -quit 2>/dev/null )
    cached_sparseimage=$( find "$workdir" -maxdepth 1 -name "*.sparseimage" -type f -print -quit 2>/dev/null )

    if [[ -d "$cached_installer_app" ]]; then
        writelog "[find_existing_installer] Installer found at $cached_installer_app."
        app_is_in_applications_folder="yes"
        check_installer_is_valid
    elif [[ -d "$cached_installer_app_in_workdir" ]]; then
        cached_installer_app="$cached_installer_app_in_workdir"
        writelog "[find_existing_installer] Installer found at $cached_installer_app."
        check_installer_is_valid
    elif [[ -f "$cached_installer_pkg" ]]; then
        writelog "[find_existing_installer] InstallAssistant package found at $cached_installer_pkg."
        check_installer_pkg_is_valid
    elif [[ -f "$cached_dmg" ]]; then
        writelog "[find_existing_installer] Installer image found at $cached_dmg."
        hdiutil attach -quiet -noverify -nobrowse "$cached_dmg"
        cached_installer_app=$( find '/Volumes/'*macOS*/*.app -maxdepth 1 -type d -print -quit 2>/dev/null )
        check_installer_is_valid
    elif [[ -f "$cached_sparseimage" ]]; then
        writelog "[find_existing_installer] Installer sparse image found at $cached_sparseimage."
        hdiutil attach -quiet -noverify -nobrowse "$cached_sparseimage"
        cached_installer_app=$( find '/Volumes/'*macOS*/Applications/*.app -maxdepth 1 -type d -print -quit 2>/dev/null )
        check_installer_is_valid
    else
        writelog "[find_existing_installer] No valid installer found."
        if [[ $clear_cache == "yes" ]]; then
            exit
        fi
    fi
}

# -----------------------------------------------------------------------------
# Look for packages to install during the startosinstall run.
# The default location is: $workdir/extras
# This location can be overridden with the --extras option.
# -----------------------------------------------------------------------------
find_extra_packages() {
    # set install_package_list to blank.
    if [[ -d "$extras_directory" ]]; then
        install_package_list=()
        for file in "$extras_directory"/*.pkg; do
            if [[ $file != *"/*.pkg" ]]; then
                writelog "[find_extra_installers] Additional package to install: $file"
                install_package_list+=("--installpackage")
                install_package_list+=("$file")
            fi
        done
    fi
}

# -----------------------------------------------------------------------------
# Return code 143 and finish the script when TERMinated or INTerrupted
# -----------------------------------------------------------------------------
# shellcheck disable=SC2317
terminate() {
    writelog "[terminate] Script was interrupted (last exit code was $?)"
    exit 143
}

# -----------------------------------------------------------------------------
# Things to carry out when the script exits
# -----------------------------------------------------------------------------
# shellcheck disable=SC2317
finish() {
    local exit_code=${1:-$?}
    # if we promoted the user then we should demote it again
    if [[ $promoted_user ]]; then
        /usr/sbin/dseditgroup -o edit -d "$promoted_user" admin
        writelog "[finish] User $promoted_user was demoted back to standard user"
    fi

    # remove pipe files
    [[ -e "${pipe_input}" ]] && /bin/rm -f "${pipe_input}"
    [[ -e "${pipe_output}" ]] && /bin/rm -f "${pipe_output}"

    # kill caffeinate
    kill_process "caffeinate"

    # kill any dialogs if startosinstall quits without rebooting the machine (exit code > 0)
    if [[ $test_run == "yes" || $exit_code -gt 0 ]]; then
        writelog "[finish] sending quit message to dialog ($dialog_log)"
        /bin/echo "quit:" >> "$dialog_log"
        # delete dialog logfile
        sleep 0.5
        # /bin/rm -f "$dialog_log"
    fi

    # set final exit code and quit, but do not call finish() again
    writelog "[finish] Script exit code: $exit_code"
    (exit "$exit_code")
}

# -----------------------------------------------------------------------------
# Determine the Darwin number from the macOS version.
# -----------------------------------------------------------------------------
get_darwin_from_os_version() {
    # convert a macOS major version to a darwin version
    os_major="$1"
    os_major_check=$(cut -d. -f1 <<< "$os_major")
    if [[ $os_major_check -eq 10 ]]; then
        darwin_version=$(cut -d. -f2 <<< "$os_major")
        darwin_version=$((darwin_version+4))
    else
        darwin_version=$((os_major_check+9))
    fi
    echo "$darwin_version"
}

# -----------------------------------------------------------------------------
# Get a password from keychain
# This is NOT a recommended method for production workflows for obvious security reasons.
# Use at your own risk!!
# -----------------------------------------------------------------------------
read_from_keychain() {
    # expects entries from the command line for keychain name, password, service name for the user and service name for the password
    writelog "[read_from_keychain] Attempting to unlock keychain..."
    if security unlock-keychain -p "$kc_pass" "$kc"; then
        writelog "[read_from_keychain] Unlocked keychain..."
        account_shortname=$(security find-generic-password -s "$kc_service" -g "$kc" 2>&1 | grep "acct" | cut -d \" -f4)
        [[ $account_shortname ]] && writelog "[read_from_keychain] Obtained user $account_shortname..."
        account_password=$(security find-generic-password -s "$kc_service" -g "$kc" 2>&1 | grep "password" | cut -d \" -f2)
        [[ $account_password ]] && writelog "[read_from_keychain] Obtained password..."
    else
        writelog "[read_from_keychain] Could not unlock keychain. Continuing..."
    fi
}

# -----------------------------------------------------------------------------
# Set catalog URLs.
# This provides a shortcut way of obtaining different catalog URLs for different
# systems.
# -----------------------------------------------------------------------------
get_catalog() {
    catalogs[17]="https://swscan.apple.com/content/catalogs/others/index-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
    catalogs[18]="https://swscan.apple.com/content/catalogs/others/index-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
    catalogs[19]="https://swscan.apple.com/content/catalogs/others/index-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
    catalogs[20]="https://swscan.apple.com/content/catalogs/others/index-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
    catalogs[21]="https://swscan.apple.com/content/catalogs/others/index-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
    catalogs[22]="https://swscan.apple.com/content/catalogs/others/index-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
}

# -----------------------------------------------------------------------------
# Default dialog arguments
# -----------------------------------------------------------------------------
get_default_dialog_args() {
    # set the dialog command arguments
    # $1 - window type
    default_dialog_args=(
        "--commandfile"
        "$dialog_log"
        "--ontop"
        "--json"
        "--ignorednd"
        "--position"
        "centre"
        "--quitkey"
        "c"
    )
    if [[ "$1" == "fullscreen" ]]; then
        writelog "[get_default_dialog_args] Invoking fullscreen dialog"
        default_dialog_args+=(
            "--blurscreen"
            "--width"
            "50%"
            "--height"
            "50%"
            "--button1disabled"
            "--centreicon"
            "--titlefont"
            "size=32"
            "--messagefont"
            "size=24"
            "--alignment"
            "centre"
        )
    elif [[ "$1" == "utility" ]]; then
        writelog "[get_default_dialog_args] Invoking utility dialog"
        default_dialog_args+=(
            "--moveable"
            "--width"
            "600"
            "--height"
            "300"
            "--titlefont"
            "size=20"
            "--messagefont"
            "size=14"
            "--alignment"
            "left"
        )
    fi
}

# -----------------------------------------------------------------------------
# Run mist list to get some required output for automation
# This requires mist, so we first check if it is on the system and download them if not.
# -----------------------------------------------------------------------------
get_mist_list() {
    # Download mist if not present
    check_for_mist

    # define mist export file location
    mist_export_file="$workdir/mist-list.json"

    mist_args=()
    mist_args+=("list")
    mist_args+=("installer")
    if [[ "$skip_validation" != "yes" ]]; then
        mist_args+=("--compatible")
    fi

    mist_args+=("--export")
    mist_args+=("$mist_export_file")

    # set alternative catalog if selected
    if [[ $catalogurl ]]; then
        writelog "[get_mist_list] Non-standard catalog URL selected"
        mist_args+=("--catalog-url")
        mist_args+=("$catalogurl")
    elif [[ $catalog ]]; then
        darwin_version=$(get_darwin_from_os_version "$catalog")
        get_catalog
        writelog "[get_mist_list] Non-default catalog selected (darwin version $darwin_version)"
        mist_args+=("--catalog-url")
        mist_args+=("${catalogs[$darwin_version]}")
    elif [[ $beta != "yes" ]]; then
        # we have to restrict the mist-cli search to the production catalog to avoid getting RCs
        darwin_version=$(get_darwin_from_os_version "$system_version_major")
        get_catalog
        writelog "[get_mist_list] Non-default catalog selected (darwin version $darwin_version)"
        mist_args+=("--catalog-url")
        mist_args+=("${catalogs[$darwin_version]}")
    fi

    # include betas if selected (which can use all the seed catalogs, which is the mist-cli default)
    if [[ $beta == "yes" ]]; then
        writelog "[get_mist_list] Beta versions included"
        mist_args+=("--include-betas")
    fi

    # run in no-ansi mode which is less pretty but better for our logs
    mist_args+=("--no-ansi")

    # run the command
    if ! "$mist_bin" "${mist_args[@]}" ; then
        writelog "[get_mist_list] An error occurred running mist. Cannot continue."
        echo
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Get the user account name and password.
# Apple Silicon devices require a username and password to run startosinstall.
# The current user is determined.
# The "real name" is also allowed if the user inputs that instead of their
# account name.
# The user is checked to see if it is a VolumeOwner, as this is required.
# The entered password is checked to see if it is correct.
# The user is given a number of attempts to enter their password (default=5).
# If --max-password-attempts is set to "infinite" then there is no limit and 
# no cancel button.
# Finally, with the --erase option, the user is promoted to admin if required.
# -----------------------------------------------------------------------------
get_user_details() {
    # get password and check that the password is correct
    password_attempts=1
    password_check="fail"
    while [[ "$password_check" != "pass" ]] ; do
        writelog "[get_user_details] ask for user credentials (attempt $password_attempts/$max_password_attempts)"
        # on the first attempt only, attempt to get credentials from a keychain if all values supplied from the command line - 
        # recommended for testing only!! 
        # otherwise, ask via dialog
        if [[ $password_attempts = 1 && $kc && $kc_pass ]]; then
            read_from_keychain
        elif [[ $password_attempts = 1 && $credentials && $very_insecure_mode == "yes" ]]; then
            credentials_decoded=$(base64 -d <<< "$credentials")
            if [[ $(awk -F: '{print NF-1}' <<< "$credentials_decoded") -eq 1 ]]; then
                account_shortname=$(awk -F: '{print $1}' <<< "$credentials_decoded")
                account_password=$(awk -F: '{print $NF}' <<< "$credentials_decoded")
            else
                writelog "[get_user_details] ERROR: Supplied credentials are in the incorrect form, so exiting..."
                exit 1
            fi
        elif [[ ! $silent ]]; then
            ask_for_credentials
            if [[ $? -eq 2 ]]; then
                writelog "[get_user_details] user cancelled dialog so exiting..."
                exit 0
            fi

            # get account name (short name) and password
            account_shortname=$(ljt '/Username' < "$dialog_output")
            account_password=$(ljt '/Password' < "$dialog_output")
        fi

        if [[ ! "$account_shortname" ]]; then
            if [[ "$current_user" ]]; then
                account_shortname="$current_user"
            else
                writelog "[get_user_details] Current user was not determined."
                if [[ ($max_password_attempts != "infinite" && $password_attempts -ge $max_password_attempts) || $silent ]]; then
                    user_is_invalid
                    echo
                    exit 1
                fi
                ((password_attempts++))
                continue
            fi
        fi

        # check that this user exists
        if ! /usr/sbin/dseditgroup -o checkmember -m "$account_shortname" everyone ; then
            writelog "[get_user_details] $account_shortname account cannot be found!"
            if [[ ($max_password_attempts != "infinite" && $password_attempts -ge $max_password_attempts) || $silent ]]; then
                password_is_invalid
                echo
                exit 1
            fi
            ((password_attempts++))
            continue
        fi

        # check that the user is a Volume Owner
        user_is_volume_owner=0
        users=$(/usr/sbin/diskutil apfs listUsers /)
        while read -r line ; do
            user=$(/usr/bin/cut -d, -f1 <<< "$line")
            guid=$(/usr/bin/cut -d, -f2 <<< "$line")
            # passwords are case sensitive, account names are not
            if [[ $(/usr/bin/grep -A2 "$guid" <<< "$users" | /usr/bin/tail -n1 | /usr/bin/awk '{print $NF}') == "Yes" ]]; then
                enabled_users+="$user "
                # The entered username might not match the output of fdesetup, so we compare
                # all RecordNames for the canonical name given by fdesetup against the entered
                # username, and then use the canonical version. The entered username might
                # even be the RealName, and we still would end up here.
                # Example:
                # RecordNames for user are "John.Doe@pretendco.com" and "John.Doe", fdesetup
                # says "John.Doe@pretendco.com", and account_shortname is "john.doe" or "Doe, John"
                user_record_names_xml=$(/usr/bin/dscl -plist /Search -read "Users/$user" RecordName dsAttrTypeStandard:RecordName)
                # loop through recordName array until error (we do not know the size of the array)
                record_name_index=0
                while true; do
                    if ! user_record_name=$(/usr/libexec/PlistBuddy -c "print :dsAttrTypeStandard\:RecordName:${record_name_index}" /dev/stdin 2>/dev/null <<< "$user_record_names_xml") ; then
                        break
                    fi
                    if [[ "${account_shortname:u}" == "${user_record_name:u}" ]]; then
                        account_shortname="$user"
                        writelog "[get_user_details] $account_shortname is a Volume Owner"
                        user_is_volume_owner=1
                        break
                    fi
                    ((record_name_index++))
                done
                # if needed, compare the RealName (which might contain spaces)
                if [[ $user_is_volume_owner -eq 0 ]]; then
                    user_real_name=$(/usr/libexec/PlistBuddy -c "print :dsAttrTypeStandard\:RealName:0" /dev/stdin <<< "$(/usr/bin/dscl -plist /Search -read "Users/$user" RealName)")
                    if [[ "${account_shortname:u}" == "${user_real_name:u}" ]]; then
                        account_shortname="$user"
                        writelog "[get_user_details] $account_shortname is a Volume Owner"
                        user_is_volume_owner=1
                    fi
                fi
            fi
        done <<< "$(/usr/bin/fdesetup list)"

        if [[ $enabled_users != "" && $user_is_volume_owner -eq 0 ]]; then
            writelog "[get_user_details] $account_shortname is not a Volume Owner"
            user_not_volume_owner
            if [[ ($max_password_attempts != "infinite" && $password_attempts -ge $max_password_attempts) || $silent ]]; then
                password_is_invalid
                exit 1
            fi
            ((password_attempts++))
            continue
        fi

        # check that the password is correct
        check_password "$account_shortname" "$account_password"

        if [[ "$password_check" != "pass" && (($max_password_attempts != "infinite" && $password_attempts -ge $max_password_attempts) || $silent)  ]]; then
            password_is_invalid
            exit 1
        fi
        ((password_attempts++))
    done

    # if we are performing eraseinstall the user needs to be an admin so let's promote the user
    if [[ $erase == "yes" ]]; then
        if ! /usr/sbin/dseditgroup -o checkmember -m "$account_shortname" admin ; then
            if /usr/sbin/dseditgroup -o edit -a "$account_shortname" admin ; then
                writelog "[get_user_details] $account_shortname account has been promoted to admin so that eraseinstall can proceed"
                promoted_user="$account_shortname"
            else
                writelog "[get_user_details] $account_shortname account could not be promoted to admin so eraseinstall cannot proceed"
                user_is_invalid
                exit 1
            fi
        fi
    fi
}

# -----------------------------------------------------------------------------
# Kill a specified process
# -----------------------------------------------------------------------------
kill_process() {
    process="$1"
    echo
    if process_pid=$(/usr/bin/pgrep -a "$process" 2>/dev/null) ; then
        writelog "[$script_name] attempting to terminate the '$process' process - Termination message indicates success"
        kill "$process_pid" 2> /dev/null
        if /usr/bin/pgrep -a "$process" >/dev/null ; then
            writelog "[$script_name] ERROR: '$process' could not be killed"
        fi
        echo
    fi
}

# -----------------------------------------------------------------------------
# We launch startosinstall via a LaunchDaemon to allow this script to exit
# before the computer restarts
# -----------------------------------------------------------------------------
launch_startosinstall() {
    # Prepare pipes for communication with startosinstall
    pipe_input=$( create_pipe "$script_name.in" )
    exec 3<> "$pipe_input"
    pipe_output=$( create_pipe "$script_name.out" )
    exec 4<> "$pipe_output"
    /bin/cat <&4 &
    pipePID=$!

    # set label and file name for LaunchDaemon
    plist_label="$pkg_label.startosinstall"
    launch_daemon="/Library/LaunchDaemons/$plist_label.plist"

    # reset the existing launchdaemon if present
    if /bin/launchctl list "$plist_label" >/dev/null 2>&1; then
        /bin/launchctl bootout system "$launch_daemon"
        /bin/rm "$launch_daemon"
    fi

    # prepare command parameters
    combined_args=()
    if [[ $test_run == "yes" ]]; then
        combined_args+=("/bin/zsh")
        combined_args+=("-c")
        combined_args+=("/bin/echo \"Simulating startosinstall.\"; sleep 5; echo \"Sending USR1 to PID $$.\"; kill -s USR1 $$")

        test_args=()
        test_args+=("$working_macos_app/Contents/Resources/startosinstall")
        test_args+=("--pidtosignal")
        test_args+=("$$")
        test_args+=("--agreetolicense")
        test_args+=("--nointeraction")
        if [[ "${#install_args[@]}" -ge 1 ]]; then
            test_args+=("${install_args[@]}")
        fi
        if [[ "${#install_package_list[@]}" -ge 1 ]]; then
            test_args+=("${install_package_list[@]}")
        fi

        writelog "[launch_startosinstall] Run without '--test-run' to run this command:"
        writelog "[launch_startosinstall] $(printf "%q " "${test_args[@]}")"
    else
        combined_args+=("$working_macos_app/Contents/Resources/startosinstall")
        combined_args+=("--pidtosignal")
        combined_args+=("$$")
        combined_args+=("--agreetolicense")
        combined_args+=("--nointeraction")
        if [[ "${#install_args[@]}" -ge 1 ]]; then
            combined_args+=("${install_args[@]}")
        fi
        if [[ "${#install_package_list[@]}" -ge 1 ]]; then
            combined_args+=("${install_package_list[@]}")
        fi
    
        writelog "[launch_startosinstall] This is the startosinstall command that will be used:"
        writelog "[launch_startosinstall] $(printf "%q " "${combined_args[@]}")"
        writelog "[launch_startosinstall] Launching startosinstall..."
fi

    # write the launchdaemon
    create_launchdaemon_to_run_startosinstall

    # Start LaunchDaemon
    /usr/sbin/chown root:wheel "$launch_daemon"
    /bin/chmod 644 "$launch_daemon"
    /bin/launchctl bootstrap system "$launch_daemon"
    /bin/rm -f "$launch_daemon"
    return 0
}

# -----------------------------------------------------------------------------
# ljt v1.0.9
# This is used only to help obtain the correct version of MacAdmins Python.
# -----------------------------------------------------------------------------
: <<-LICENSE_BLOCK
ljt.min - Little JSON Tool (https://github.com/brunerd/ljt) Copyright (c) 2022 Joel Bruner (https://github.com/brunerd). Licensed under the MIT License. Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
LICENSE_BLOCK

ljt() ( #v1.0.9 ljt [query] [file]
    { set +x; } &> /dev/null; read -r -d '' JSCode <<-'EOT'
try{var query=decodeURIComponent(escape(arguments[0]));var file=decodeURIComponent(escape(arguments[1]));if(query===".")query="";else if(query[0]==="."&&query[1]==="[")query="$"+query.slice(1);if(query[0]==="/"||query===""){if(/~[^0-1]/g.test(query+" "))throw new SyntaxError("JSON Pointer allows ~0 and ~1 only: "+query);query=query.split("/").slice(1).map(function(f){return"["+JSON.stringify(f.replace(/~1/g,"/").replace(/~0/g,"~"))+"]"}).join("")}else if(query[0]==="$"||query[0]==="."&&query[1]!=="."||query[0]==="["){if(/[^A-Za-z_$\d\.\[\]'"]/.test(query.split("").reverse().join("").replace(/(["'])(.*?)\1(?!\\)/g,"")))throw new Error("Invalid path: "+query);}else query=query.replace(/\\\./g,"\uDEAD").split(".").map(function(f){return "["+JSON.stringify(f.replace(/\uDEAD/g,"."))+"]"}).join('');if(query[0]==="$")query=query.slice(1);var data=JSON.parse(readFile(file));try{var result=eval("(data)"+query)}catch(e){}}catch(e){printErr(e);quit()}if(result!==undefined)result!==null&&result.constructor===String?print(result):print(JSON.stringify(result,null,2));else printErr("Path not found.")
EOT

    queryArg="${1}"; fileArg="${2}"; jsc=$(find "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/" -name 'jsc'); [ -z "${jsc}" ] && jsc=$(which jsc); [[ -f "${queryArg}" && -z "${fileArg}" ]] && fileArg="${queryArg}" && unset queryArg; if [ -f "${fileArg:=/dev/stdin}" ]; then { errOut=$( { { "${jsc}" -e "${JSCode}" -- "${queryArg}" "${fileArg}"; } 1>&3 ; } 2>&1); } 3>&1; else [ -t '0' ] && echo -e "ljt (v1.0.9) - Little JSON Tool (https://github.com/brunerd/ljt)\nUsage: ljt [query] [filepath]\n  [query] is optional and can be JSON Pointer, canonical JSONPath (with or without leading $), or plutil-style keypath\n  [filepath] is optional, input can also be via file redirection, piped input, here doc, or here strings" >/dev/stderr && exit 0; { errOut=$( { { "${jsc}" -e "${JSCode}" -- "${queryArg}" "/dev/stdin" <<< "$(cat)"; } 1>&3 ; } 2>&1); } 3>&1; fi; if [ -n "${errOut}" ]; then /bin/echo "$errOut" >&2; return 1; fi
)

# -----------------------------------------------------------------------------
# Copy the installer to the /Applications folder if not already there, and 
# delete the dmg or sparseimage that encloses it.
# This is called with the --move option.
# -----------------------------------------------------------------------------
move_to_applications_folder() {
    if [[ $app_is_in_applications_folder == "yes" ]]; then
        writelog "[move_to_applications_folder] Valid installer already in $installer_directory folder"
    else
        writelog "[move_to_applications_folder] Moving $working_macos_app to $installer_directory folder"
        # we are actually copying it, not moving it, because we are in a mounted image
        cp -R "$working_macos_app" "$installer_directory/"
        cached_installer=$( find /Volumes/*macOS* -maxdepth 2 -type d -name "Install*.app" -print -quit 2>/dev/null )
        # unmount the image
        if [[ -d "$cached_installer" ]]; then
            writelog "[move_to_applications_folder] Mounted installer will be unmounted: $cached_installer"
            existing_installer_mount_point=$(echo "$cached_installer" | cut -d/ -f 1-3)
            diskutil unmount force "$existing_installer_mount_point"
        fi
        # remove the dmg or sparseimage
        rm -f "$cached_dmg" "$cached_sparseimage"
        working_macos_app=$( find "$installer_directory/Install macOS"*.app -maxdepth 1 -type d -print -quit 2>/dev/null )
        writelog "[move_to_applications_folder] Installer moved to $installer_directory folder"
    fi
}

# -----------------------------------------------------------------------------
# Overwrite an existing installer.
# This is called with the --overwrite option.
# Note that multiple installers left around on the device can cause unexpected
# results.  
# -----------------------------------------------------------------------------
overwrite_existing_installer() {
    writelog "[overwrite_existing_installer] Overwrite option selected. Deleting existing version."
    cached_installer=$( find /Volumes/*macOS* -maxdepth 2 -type d -name "Install*.app" -print -quit 2>/dev/null )
    if [[ -d "$cached_installer" ]]; then
        writelog "[$script_name] Mounted installer will be unmounted: $cached_installer"
        existing_installer_mount_point=$(echo "$cached_installer" | cut -d/ -f 1-3)
        diskutil unmount force "$existing_installer_mount_point"
    fi
    rm -f "$cached_dmg" "$cached_sparseimage" "$cached_installer_pkg" 
    rm -rf "$cached_installer_app"
    app_is_in_applications_folder=""
    if [[ $clear_cache == "yes" ]]; then
        writelog "[overwrite_existing_installer] Cached installers have been removed. Quitting script as --clear-cache-only option was selected"
        exit
    fi
}

# -----------------------------------------------------------------------------
# Things to do after startosinstall has finished preparing
# -----------------------------------------------------------------------------
# shellcheck disable=SC2317
post_prep_work() {
    # set dialog progress for rebootdelay if set
    if [[ "$rebootdelay" -gt 10 && ! $silent && $fs != "yes" ]]; then
        # quit an existing window
        writelog "[post_prep_work] Sending quit message to dialog log ($dialog_log)"
        echo "quit:" >> "$dialog_log"
        writelog "[post_prep_work] Opening full screen dialog (language=$user_language)"

        window_type="utility"
        iconsize=100

        # set the dialog command arguments
        get_default_dialog_args "$window_type"
        dialog_args=("${default_dialog_args[@]}")
        dialog_args+=(
            "--title"
            "${(P)dialog_reinstall_title}"
            "--icon"
            "${dialog_install_icon}"
            "--iconsize"
            "$iconsize"
            "--message"
            "${(P)dialog_rebooting_heading}"
            "--button1disabled"
            "--progress"
            "$rebootdelay"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null & sleep 0.1

        dialog_progress reboot-delay >/dev/null 2>&1 &
    fi

    # run any postinstall commands
    for command in "${postinstall_command[@]}"; do
        if [[ $command ]]; then
            writelog "[post_prep_work] Now running postinstall command: $command"
            eval "$command"
        fi
    done

    if [[ $test_run == "yes" ]]; then
        writelog "[post_prep_work] Simulating reboot delay of ${rebootdelay}s"
        sleep "$rebootdelay"
    else
        # we need to quit so our management system can report back home before being killed by startosinstall
        writelog "[post_prep_work] Reboot delay set to ${rebootdelay}s"
        # then shut everything down
        kill_process "Self Service"
    fi

    # set exit code to 0 which will call finish()
    exit 0
}

# -----------------------------------------------------------------------------
# Run softwareupdate --fetch-full-installer
# Includes some fallbacks, because --list-full-installers might not be 
# available in some versions of Catalina. 
# -----------------------------------------------------------------------------
run_fetch_full_installer() {
    softwareupdate_args=()
    run_list_full_installers
    if [[ -f "$workdir/ffi-list-full-installers.txt" ]]; then
        if [[ $prechosen_version ]]; then
            # check that this version is available in the list
            ffi_available=$(grep -c -E "Version: $prechosen_version," "$workdir/ffi-list-full-installers.txt")
            if [[ $ffi_available -ge 1 ]]; then
                # get the chosen version
                writelog "[run_fetch_full_installer] Found version $prechosen_version"
                softwareupdate_args+=("--full-installer-version")
                softwareupdate_args+=("$prechosen_version")
            else
                writelog "[run_fetch_full_installer] WARNING: $prechosen_version not found. Defaulting to latest available version."
            fi
        elif [[ $prechosen_os ]]; then
            # check that this OS is available in the list
            ffi_available=$(grep -c -E "Version: $prechosen_os." "$workdir/ffi-list-full-installers.txt")
            if [[ $ffi_available -ge 1 ]]; then
                # get the latest version within the chosen OS
                if [[ "$beta" == "yes" ]]; then
                    latest_ffi=$(grep -E "Version: $prechosen_os." "$workdir/ffi-list-full-installers.txt" | head -n1 | cut -d, -f2 | sed 's|.*Version: ||')
                else
                    latest_ffi=$(grep -E "Version: $prechosen_os." "$workdir/ffi-list-full-installers.txt" | grep -v beta | head -n1 | cut -d, -f2 | sed 's|.*Version: ||')
                fi
                
                writelog "[run_fetch_full_installer] Found version $latest_ffi"
                softwareupdate_args+=("--full-installer-version")
                softwareupdate_args+=("$latest_ffi")
            else
                writelog "[run_fetch_full_installer] WARNING: No available version for macOS $prechosen_os found. Defaulting to latest available version."
            fi
        else
            # if no version is selected, we want to obtain the latest. The list obtained from
            # --list-full-installers appears to always be in order of newest to oldest, so we can grab the first one
            if [[ "$beta" == "yes" ]]; then
                latest_ffi=$(grep -E "Version:" "$workdir/ffi-list-full-installers.txt" | head -n1 | cut -d, -f2 | sed 's|.*Version: ||')
            else
                latest_ffi=$(grep -E "Version:" "$workdir/ffi-list-full-installers.txt" | grep -v beta | head -n1 | cut -d, -f2 | sed 's|.*Version: ||')
            fi

            if [[ $latest_ffi ]]; then
                # we need to check if this version is older than the current system and abort if so
                latest_ffi_major=$(cut -d. -f1 <<< "$latest_ffi")
                latest_ffi_minor=$(cut -d. -f2,3 <<< "$latest_ffi")
                if [[ $latest_ffi_major -lt $system_version_major || "$latest_ffi_major" == "$system_version_major" && $(echo "$latest_ffi_minor < $system_version_minor" | bc) == 1 ]]; then
                    writelog "[run_fetch_full_installer] ERROR: latest version in catalog $latest_ffi is older OS than the system version $system_version"
                    echo
                    exit 1
                fi
                softwareupdate_args+=("--full-installer-version")
                softwareupdate_args+=("$latest_ffi")
            else
                writelog "[run_fetch_full_installer] Could not obtain installer information using softwareupdate. Defaulting to no specific version, which should obtain the latest but is not as reliable."
            fi
        fi
    else
        # if --list-full-installers did not work, then we cannot continue
        writelog "[run_fetch_full_installer] Could not obtain installer information using softwareupdate --list-full-installers. Cannot continue."
        echo
        exit 1
    fi

    # now download the installer
    writelog "[run_fetch_full_installer] Running /usr/sbin/softwareupdate --fetch-full-installer $(printf "%q " "${softwareupdate_args[@]}")"
    if /usr/sbin/softwareupdate --fetch-full-installer "${softwareupdate_args[@]}"; then
        # Identify the installer
        if find /Applications -maxdepth 1 -name 'Install macOS*.app' -type d -print -quit 2>/dev/null ; then
            cached_installer_app=$( find /Applications -maxdepth 1 -name 'Install macOS*.app' -type d -print -quit 2>/dev/null )
            # if we actually want to use this installer we should check that it's valid
            if [[ $erase == "yes" || $reinstall == "yes" ]]; then
                check_installer_is_valid
                if [[ $invalid_installer_found == "yes" ]]; then
                    writelog "[run_fetch_full_installer] The downloaded app is invalid for this computer. Try with --version or without --fetch-full-installer"
                    exit 1
                fi
            fi
        else
            writelog "[run_fetch_full_installer] No install app found. I guess nothing got downloaded."
            exit 1
        fi
    else
        writelog "[run_fetch_full_installer] softwareupdate --fetch-full-installer failed. Try without --fetch-full-installer option."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Run mist with chosen options.
# This requires mist, so we first check if it is on the system and download them if not.
# -----------------------------------------------------------------------------
run_mist() {
    # first, if we didn't already check for updates, run mist list to get some needed information about builds
    get_mist_list

    # define mist export file location
    mist_export_file="$workdir/mist-list.json"

    # now clear the variables and build the download command
    mist_args=()
    mist_args+=("download")
    mist_args+=("installer")

    # restrict to a particular major OS if selected
    if [[ $prechosen_os ]]; then
        # check whether chosen OS is older than the system
        if [[ $prechosen_os < $system_version_major ]]; then
            writelog "[run_mist] ERROR: cannot select an older OS than the system"
            echo
            exit 1
        fi
        writelog "[run_mist] Restricting to selected OS $prechosen_os"
        mist_args+=("$prechosen_os")

    # restrict to a particular version if selected
    elif [[ $prechosen_version ]]; then
        prechosen_version_check=$(cut -d. -f1 <<< "$prechosen_version")
        if [[ $prechosen_version_check -eq 10 ]]; then
            prechosen_version_major=$(cut -d. -f1,2 <<< "$prechosen_version")
            prechosen_version_minor=$(cut -d. -f3 <<< "$prechosen_version")
        else
            prechosen_version_major=$(cut -d. -f1 <<< "$prechosen_version")
            prechosen_version_minor=$(cut -d. -f2,3 <<< "$prechosen_version")
        fi
        # check for an older version
        if [[ $(echo "$prechosen_version_major < $system_version_major " | bc) == 1 || "$prechosen_version_major" == "$system_version_major" && $(echo "$prechosen_version_minor < $system_version_minor" | bc) == 1 ]]; then
            writelog "[run_mist] ERROR: cannot select an older version than the system"
            echo
            exit 1
        fi
        writelog "[run_mist] Checking that selected version $prechosen_version is available"
        mist_args+=("$prechosen_version")

    # restrict to a particular build if selected
    elif [[ $prechosen_build ]]; then
        builds_available=$(grep -c build "$mist_export_file")
        build_found=0
        i=0
        while [[ $i -lt $builds_available ]]; do
            build_check=$(ljt $i.build < "$mist_export_file")
            if [[ "$build_check" == "$prechosen_build" ]]; then
                build_found=1
                break
            fi
            ((i++))
        done
        if [[ $build_found = 0 ]]; then
            writelog "[run_mist] ERROR: build is not available"
            echo
            exit 1
        fi
        writelog "[run_mist] Checking that selected build $prechosen_build is available"
        mist_args+=("$prechosen_build")

    # restrict to the same build as the system if selected
    elif [[ $samebuild == "yes" ]]; then
        # temporarily we will just check for the same version
        writelog "[run_mist] Checking that current version $system_version is available"
        mist_args+=("$system_version")

    # restrict to the same major OS as the system if selected
    elif [[ $sameos == "yes" ]]; then
        writelog "[run_mist] Checking that current OS $system_version_major is available"
        mist_args+=("$system_version_major")

    else
        # if no version was selected, we want the latest available, which is the first in the mist-list
        latest_version=$(ljt '0.version' < "$mist_export_file")
        latest_version_check=$(cut -d. -f1 <<< "$latest_version")
        if [[ $latest_version_check -eq 10 ]]; then
            latest_version_major=$(cut -d. -f1,2 <<< "$latest_version")
            latest_version_minor=$(cut -d. -f3 <<< "$latest_version")
        else
            latest_version_major=$(cut -d. -f1 <<< "$latest_version")
            latest_version_minor=$(cut -d. -f2,3 <<< "$latest_version")
        fi
        if [[ $latest_version ]]; then
            if [[ $(echo "$latest_version_major < $system_version_major" | bc) == 1 || ("$latest_version_major" == "$system_version_major" && $(echo "$latest_version_minor < $system_version_minor" | bc) == 1) ]]; then
                writelog "[run_mist] ERROR: latest version in catalog $latest_version is older OS than the system version $system_version"
                echo
                exit 1
            fi
            writelog "[run_mist] Selected $latest_version as the latest version available"
            mist_args+=("$latest_version")
        else
            writelog "[run_mist] ERROR: mist was unable to locate any installers (probably no internet connection)"
            echo
            exit 1
        fi
    fi

    # grab package if --pkg selected and --move is not selected, otherwise we will grab the app
    if [[ $pkg_installer && ! $move_to_applications_folder ]]; then
        mist_args+=("package")
        mist_args+=("--package-name")
        mist_args+=("$default_downloaded_pkg_name")
        mist_args+=("--package-identifier")
        mist_args+=("$default_downloaded_pkg_id")
        mist_args+=("--output-directory")
        mist_args+=("$workdir")
    else
        mist_args+=("application")
        mist_args+=("--application-name")
        mist_args+=("$default_downloaded_app_name")
        mist_args+=("--output-directory")
        mist_args+=("$installer_directory")
    fi

    if [[ "$skip_validation" != "yes" ]]; then
        writelog "[run_mist] Setting mist to only list compatible installers"
        mist_args+=("--compatible")
    fi

    # run in no-ansi mode which is less pretty but better for our logs
    mist_args+=("--no-ansi")

    # reduce output if --quiet mode
    if [[ "$quiet" == "yes" ]]; then
        writelog "[run_mist] Setting mist to quiet mode"
        mist_args+=("--quiet")
    fi

    # optionally cache downloads to save time when doing repeated tests
    if [[ "$cache_downloads" == "yes" ]]; then
        writelog "[run_mist] Setting mist to cache downloads"
        mist_args+=("--cache-downloads")
    fi

    # optionally set mist to use a caching server
    if [[ "$caching_server" ]]; then
        writelog "[run_mist] Setting mist to use Caching Server $caching_server"
        mist_args+=("--caching-server")
        mist_args+=("$caching_server")
    fi

    # force overwrite of existing app or pkg of the same name
    # mist_args+=("--force")

    # set alternative catalog if selected
    if [[ $catalogurl ]]; then
        writelog "[run_mist] Non-standard catalog URL selected"
        mist_args+=("--catalog-url")
        mist_args+=("$catalogurl")
    elif [[ $catalog ]]; then
        darwin_version=$(get_darwin_from_os_version "$catalog")
        get_catalog
        writelog "[run_mist] Non-default catalog selected (darwin version $darwin_version)"
        mist_args+=("--catalog-url")
        mist_args+=("${catalogs[$darwin_version]}")
    elif [[ $beta != "yes" ]]; then
        # we have to restrict the mist-cli search to the production catalog to avoid getting RCs
        darwin_version=$(get_darwin_from_os_version "$system_version_major")
        get_catalog
        writelog "[get_mist_list] Non-default catalog selected (darwin version $darwin_version)"
        mist_args+=("--catalog-url")
        mist_args+=("${catalogs[$darwin_version]}")
    fi

    # include betas if selected
    if [[ $beta == "yes" ]]; then
        writelog "[run_mist] Beta versions included"
        mist_args+=("--include-betas")
    fi

    echo
    writelog "[run_mist] This command is now being run:"
    echo
    writelog "mist ${mist_args[*]}"

    if ! "$mist_bin" "${mist_args[@]}" ; then
        writelog "[run_mist] An error occurred running mist. Cannot continue."
        echo
        exit 1
    fi

    # Identify the downloaded installer
    downloaded_app=$( find "$installer_directory" -maxdepth 1 -name "Install macOS *.app" -type d -print -quit )
    downloaded_installer_pkg=$( find "$workdir" -maxdepth 1 -name "InstallAssistant-*-*.pkg" -type f -print -quit 2>/dev/null )

    # Identify the installer dmg
    cached_dmg=$( find "$workdir" -maxdepth 1 -name 'Install_macOS*.dmg' -type f -print -quit )
    cached_sparseimage=$( find "$workdir" -maxdepth 1 -name 'Install_macOS*.sparseimage' -type f -print -quit )

    if [[ -d "$downloaded_app" ]]; then
        downloaded_app_name=$(basename "$downloaded_app")
        writelog "[run_mist] $downloaded_app_name downloaded to $installer_directory."
        working_macos_app="$downloaded_app"
    elif [[ -f "$downloaded_installer_pkg" ]]; then
        downloaded_installer_pkg_name=$(basename "$downloaded_installer_pkg")
        writelog "[run_mist] $downloaded_installer_pkg_name downloaded to $workdir."
        working_installer_pkg="$downloaded_installer_pkg"
    elif [[ -f "$cached_dmg" ]]; then
        writelog "[run_mist] Mounting disk image to identify installer app."
        if hdiutil attach -quiet -noverify -nobrowse "$cached_dmg" ; then
            working_macos_app=$( find '/Volumes/'*macOS*/*.app -maxdepth 1 -type d -print -quit 2>/dev/null )
        else
            writelog "[run_mist] ERROR: could not mount $cached_dmg"
            exit 1
        fi
    elif [[ -f "$cached_sparseimage" ]]; then
        writelog "[run_mist] Mounting sparse disk image to identify installer app."
        if hdiutil attach -quiet -noverify -nobrowse "$cached_sparseimage" ; then
            working_macos_app=$( find '/Volumes/'*macOS*/Applications/*.app -maxdepth 1 -type d -print -quit 2>/dev/null )
        else
            writelog "[run_mist] ERROR: could not mount $cached_sparseimage"
            exit 1
        fi
    else
        writelog "[run_mist] No installer found. I guess nothing got downloaded."
        exit 1
    fi
}


# -----------------------------------------------------------------------------
# Set localized values for user dialogues 
# -----------------------------------------------------------------------------
set_localisations() {
    # Grab the currently logged in user to set the language for all dialogue messages
    current_user=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}')
    current_uid=$(/usr/bin/id -u "$current_user")

    # Get the proper home directory. We use this because the output of scutil might not 
    # reflect the canonical RecordName or the HomeDirectory at all, which might prevent
    # us from detecting the language
    current_user_homedir=$(/usr/libexec/PlistBuddy -c 'Print :dsAttrTypeStandard\:NFSHomeDirectory:0' /dev/stdin <<< "$(/usr/bin/dscl -plist /Search -read "/Users/${current_user}" NFSHomeDirectory)")
    # detect the user's language
    language=$(/usr/libexec/PlistBuddy -c 'print AppleLanguages:0' "/${current_user_homedir}/Library/Preferences/.GlobalPreferences.plist")
    if [[ $language = de* ]]; then
        user_language="de"
    elif [[ $language = nl* ]]; then
        user_language="nl"
    elif [[ $language = fr* ]]; then
        user_language="fr"
    elif [[ $language = es* ]]; then
        user_language="es"
    else
        user_language="en"
    fi

    # Dialogue localizations - download window - title
    dialog_dl_title_en="Downloading macOS"
    dialog_dl_title_de="macOS wird heruntergeladen"
    dialog_dl_title_nl="macOS downloaden"
    dialog_dl_title_fr="Téléchargement de macOS"
    dialog_dl_title_es="Descarga de macOS"
    dialog_dl_title=dialog_dl_title_${user_language}

    # Dialogue localizations - download window - description
    dialog_dl_desc_en="We need to download the macOS installer to your computer.  \n\nThis may take several minutes, depending on your internet connection."
    dialog_dl_desc_de="Das macOS-Installationsprogramm wird heruntergeladen.  \n\nDies kann einige Minuten dauern, je nach Ihrer Internetverbindung."
    dialog_dl_desc_nl="We moeten het macOS besturingssysteem downloaden.  \n\nDit kan enkele minuten duren, afhankelijk van uw internetverbinding."
    dialog_dl_desc_fr="Nous devons télécharger le programme d'installation de macOS sur votre ordinateur.  \n\nCela peut prendre plusieurs minutes, en fonction de votre connexion Internet."
    dialog_dl_desc_es="Necesitamos descargar el instalador de macOS en tu ordenador.  \n\nEsto puede tardar varios minutos, dependiendo de su conexión a Internet."
    dialog_dl_desc=dialog_dl_desc_${user_language}

    # Dialogue localizations - erase lock screen - title
    dialog_erase_title_en="Erasing macOS"
    dialog_erase_title_de="macOS wiederherstellen"
    dialog_erase_title_nl="macOS herinstalleren"
    dialog_erase_title_fr="Effacement de macOS"
    dialog_erase_title_es="Borrado de macOS"
    dialog_erase_title=dialog_erase_title_${user_language}

    # Dialogue localizations - erase lock screen - description
    dialog_erase_desc_en="### Preparing the installer may take up to 30 minutes.  \n\nOnce completed your computer will reboot and continue the reinstallation."
    dialog_erase_desc_de="### Das Vorbereiten des Installationsprogramms kann bis zu 30 Minuten dauern.  \n\nNach Abschluss des Vorgangs wird Ihr Computer neu gestartet und die Neuinstallation fortgesetzt."
    dialog_erase_desc_nl="### Het voorbereiden van het installatieprogramma kan tot 30 minuten duren.  \n\nNa voltooiing zal uw computer opnieuw opstarten en de herinstallatie voortzetten."
    dialog_erase_desc_fr="### La préparation du programme d'installation peut prendre jusqu'à 30 minutes.  \n\nUne fois terminé, votre ordinateur redémarre et poursuit la réinstallation."
    dialog_erase_desc_es="### La preparación del instalador puede tardar hasta 30 minutos.  \n\nUna vez completado, su ordenador se reiniciará y continuará la reinstalación."
    dialog_erase_desc=dialog_erase_desc_${user_language}

    # Dialogue localizations - reinstall lock screen - title
    dialog_reinstall_title_en="Upgrading macOS"
    dialog_reinstall_title_de="macOS aktualisieren"
    dialog_reinstall_title_nl="macOS upgraden"
    dialog_reinstall_title_fr="Mise à niveau de macOS"
    dialog_reinstall_title_es="Actualización de macOS"
    dialog_reinstall_title=dialog_reinstall_title_${user_language}

    # Dialogue localizations - reinstall lock screen - heading
    dialog_reinstall_heading_en="Please wait as we prepare your computer for upgrading macOS."
    dialog_reinstall_heading_de="Bitte warten Sie, während Ihren Computer für das Upgrade von macOS vorbereitet wird."
    dialog_reinstall_heading_nl="Even geduld terwijl we uw computer voorbereiden voor de upgrade van macOS."
    dialog_reinstall_heading_fr="Veuillez patienter pendant que nous préparons votre ordinateur pour la mise à niveau de macOS."
    dialog_reinstall_heading_es="Por favor, espere mientras preparamos su ordenador para la actualización de macOS."
    dialog_reinstall_heading=dialog_reinstall_heading_${user_language}

    # Dialogue localizations - reinstall lock screen - description
    dialog_reinstall_desc_en="### Preparing the installer may take up to 30 minutes.  \n\nOnce completed your computer will reboot and begin the upgrade."
    dialog_reinstall_desc_de="### Dieser Prozess kann bis zu 30 Minuten benötigen.  \n\nDer Computer startet anschliessend neu und beginnt mit der Aktualisierung."
    dialog_reinstall_desc_nl="### Dit proces duurt ongeveer 30 minuten.  \n\nZodra dit is voltooid, wordt uw computer opnieuw opgestart en begint de upgrade."
    dialog_reinstall_desc_fr="### Ce processus peut prendre jusqu'à 30 minutes.  \n\nUne fois terminé, votre ordinateur redémarrera et commencera la mise à niveau."
    dialog_reinstall_desc_es="### La preparación del instalador puede tardar hasta 30 minutos.  \n\nUna vez completado, su ordenador se reiniciará y comenzará la actualización."
    dialog_reinstall_desc=dialog_reinstall_desc_${user_language}

    # Dialogue localizations - reinstall lock screen - status message
    dialog_reinstall_status_en="Preparing macOS for installation"
    dialog_reinstall_status_de="Vorbereiten von macOS für die Installation"
    dialog_reinstall_status_nl="MacOS voorbereiden voor installatie"
    dialog_reinstall_status_fr="Préparation de macOS pour l'installation"
    dialog_reinstall_status_es="Preparación de macOS para la instalación"
    dialog_reinstall_status=dialog_reinstall_status_${user_language}

    # Dialogue localizations - reebooting screen - heading
    dialog_rebooting_heading_en="The upgrade is now ready for installation.  \n\n### Save any open work now!"
    dialog_rebooting_heading_de="Die macOS-Aktualisierung steht nun zur Installation bereit.  \n\n### Speichern Sie jetzt alle offenen Arbeiten ab!"
    dialog_rebooting_heading_nl="De upgrade is nu klaar voor installatie.  \n\n### Bewaar nu al het open werk!"
    dialog_rebooting_heading_fr="La mise à niveau est maintenant prête à être installée.  \n\n### Sauvegardez les travaux en cours maintenant!"
    dialog_rebooting_heading_es="La actualización ya está lista para ser instalada.  \n\n### ¡Guarde ahora los trabajos pendientes!"
    dialog_rebooting_heading=dialog_rebooting_heading_${user_language}

    # Dialogue localizations - erase confirmation window - description
    dialog_erase_confirmation_desc_en="Please confirm that you want to ERASE ALL DATA FROM THIS DEVICE and reinstall macOS"
    dialog_erase_confirmation_desc_de="Bitte bestätigen Sie, dass Sie ALLE DATEN VON DIESEM GERÄT LÖSCHEN und macOS neu installieren wollen!"
    dialog_erase_confirmation_desc_nl="Weet je zeker dat je ALLE GEGEVENS VAN DIT APPARAAT WILT WISSEN en macOS opnieuw installeert?"
    dialog_erase_confirmation_desc_fr="Veuillez confirmer que vous souhaitez EFFACER TOUTES LES DONNÉES DE CET APPAREIL et réinstaller macOS"
    dialog_erase_confirmation_desc_es="Por favor, confirme que desea BORRAR TODOS LOS DATOS DE ESTE DISPOSITIVO y reinstalar macOS"
    dialog_erase_confirmation_desc=dialog_erase_confirmation_desc_${user_language}

    # Dialogue localizations - reinstall confirmation window - description
    dialog_reinstall_confirmation_desc_en="Please confirm that you want to upgrade macOS on this system now"
    dialog_reinstall_confirmation_desc_de="Bitte bestätigen Sie, dass Sie macOS auf diesem System jetzt aktualisieren möchten."
    dialog_reinstall_confirmation_desc_nl="Bevestig dat u macOS op dit systeem nu wilt updaten"
    dialog_reinstall_confirmation_desc_fr="Veuillez confirmer que vous voulez mettre à jour macOS sur ce système maintenant."
    dialog_reinstall_confirmation_desc_es="Por favor, confirme que desea actualizar macOS en este sistema ahora"
    dialog_reinstall_confirmation_desc=dialog_reinstall_confirmation_desc_${user_language}

    # Dialogue localizations - free space check - description
    dialog_check_desc_en="The macOS upgrade cannot be installed as there is not enough space left on the drive."
    dialog_check_desc_de="macOS kann nicht aktualisiert werden, da nicht genügend Speicherplatz auf dem Laufwerk frei ist."
    dialog_check_desc_nl="De upgrade van macOS kan niet worden geïnstalleerd omdat er niet genoeg ruimte is op de schijf."
    dialog_check_desc_fr="La mise à niveau de macOS ne peut pas être installée car il n'y a pas assez d'espace disponible sur ce volume."
    dialog_check_desc_es="La actualización de macOS no se puede instalar porque no queda espacio suficiente en la unidad."
    dialog_check_desc=dialog_check_desc_${user_language}

    # Dialogue localizations - power check - title
    dialog_power_title_en="Waiting for AC Power Connection"
    dialog_power_title_de="Auf Netzteil warten"
    dialog_power_title_nl="Wachten op stroomadapter"
    dialog_power_title_fr="En attente de l'alimentation secteur"
    dialog_power_title_es="A la espera de la conexión a la red eléctrica"
    dialog_power_title=dialog_power_title_${user_language}

    # Dialogue localizations - power check - description
    dialog_power_desc_en="Please connect your computer to power using an AC power adapter.  \n\nThis process will continue if AC power is detected within the specified time."
    dialog_power_desc_de="Bitte verbinden Sie Ihren Computer mit einem Netzteil.  \n\nDieser Prozess wird fortgesetzt, wenn eine Stromversorgung innerhalb der folgenden Zeit erkannt wird:"
    dialog_power_desc_nl="Sluit uw computer aan met de stroomadapter.  \n\nZodra deze is gedetecteerd gaat het proces verder binnen de volgende:"
    dialog_power_desc_fr="Veuillez connecter votre ordinateur à un adaptateur secteur.  \n\nCe processus se poursuivra une fois que l'alimentation secteur sera détectée dans la suivante:"
    dialog_power_desc_es="Conecte su ordenador a la corriente eléctrica mediante un adaptador de CA.  \n\nEste proceso continuará si se detecta alimentación de CA dentro del tiempo especificado."
    dialog_power_desc=dialog_power_desc_${user_language}

    # Dialogue localizations - no power detected - description
    dialog_nopower_desc_en="### AC power was not connected in the specified time.  \n\nPress OK to quit."
    dialog_nopower_desc_de="### Die Netzspannung wurde nicht in der angegebenen Zeit angeschlossen.  \n\nZum Beenden OK drücken."
    dialog_nopower_desc_nl="### De netspanning was niet binnen de opgegeven tijd aangesloten.  \n\nDruk op OK om af te sluiten."
    dialog_nopower_desc_fr="### Le courant alternatif n'a pas été branché dans le délai spécifié.  \n\nAppuyez sur OK pour quitter."
    dialog_nopower_desc_es="### La alimentación de CA no se ha conectado en el tiempo especificado.  \n\nPulse OK para salir."
    dialog_nopower_desc=dialog_nopower_desc_${user_language}

    # Dialogue localizations - Find My check - title
    dialog_fmm_title_en="Waiting for Find My Mac to be disabled"
    dialog_fmm_title_de="Warte auf die Deaktivierung von «Meinen Mac suchen»"
    dialog_fmm_title_nl="Wachten op Vind mijn Mac"
    dialog_fmm_title_fr="En attente de Localiser mon Mac"
    dialog_fmm_title_es="A la espera de la Buscar mi Mac"
    dialog_fmm_title=dialog_fmm_title_${user_language}

    # Dialogue localizations - Find My check - description
    dialog_fmm_desc_en="Please disable **Find My Mac** in your iCloud settings.  \n\nThis setting can be found in **System Preferences** > **Apple ID** > **iCloud**.  \n\nThis process will continue if Find My has been disabled within the specified time."
    dialog_fmm_desc_de="Bitte deaktiviere **«Meinen Mac suchen»** in Ihren iCloud-Einstellungen.  \n\nDiese Einstellung finden Sie in **Systemeinstellungen** > **Apple ID** > **iCloud**.  \n\nDieser Vorgang wird fortgesetzt, wenn «Meinen Mac suchen» innerhalb der angegebenen Zeit deaktiviert wurde."
    dialog_fmm_desc_nl="Schakel **Vind mijn Mac** uit in uw iCloud-instellingen.  \n\nDeze instelling vindt u in **Systeemvoorkeuren** > **Apple ID** > **iCloud**.  \n\nDit proces wordt voortgezet als **Vind mijn Mac** binnen de opgegeven tijd is uitgeschakeld."
    dialog_fmm_desc_fr="Veuillez désactiver **Localiser mon Mac** dans vos paramètres iCloud.  \n\nCe paramètre se trouve dans **Préférences système** > **Identifiant Apple** > **iCloud**.  \n\nCe processus se poursuivra si Localiser mon Mac a été désactivé dans le délai spécifié."
    dialog_fmm_desc_es="Por favor desactiva **Buscar mi Mac** en los ajustes de iCloud.  \n\nEste ajuste se encuentra en **Preferencias del sistema** > **ID de Apple** > **iCloud**.  \n\nEste proceso continuará si Buscar mi Mac se ha desactivado dentro del tiempo especificado."
    dialog_fmm_desc=dialog_fmm_desc_${user_language}

    # Dialogue localizations - Find My check failed - description
    dialog_fmmenabled_desc_en="### Find My Mac was not disabled in the specified time.  \n\nPress OK to quit."
    dialog_fmmenabled_desc_de="### «Meinem Mac suchen» wurde nicht innerhalb der angegebenen Zeit deaktiviert.  \n\nZum Beenden OK drücken."
    dialog_fmmenabled_desc_nl="### Vind mijn Mac was niet uitgeschakeld in de opgegeven tijd.  \n\nDruk op OK om af te sluiten."
    dialog_fmmenabled_desc_fr="### Localiser mon Mac n'a pas été désactivé dans le temps imparti.  \n\nAppuyez sur OK pour quitter."
    dialog_fmmenabled_desc_es="### Buscar mi Mac no se ha desactivado en el tiempo especificado.  \n\nPulse OK para salir."
    dialog_fmmenabled_desc=dialog_fmmenabled_desc_${user_language}

    # Dialogue localizations - ask for credentials - erase
    dialog_erase_credentials_en="Erasing macOS requires authentication using local account credentials.  \n\nPlease enter your account name and password to start the erase process."
    dialog_erase_credentials_de="Das Löschen von macOS erfordert eine Authentifizierung mit den Anmeldedaten des lokalen Kontos.  \n\nBitte geben Sie Ihren Kontonamen und Ihr Passwort ein, um den Löschvorgang zu starten."
    dialog_erase_credentials_nl="Voor het wissen van macOS is verificatie met behulp van lokale accountgegevens vereist.  \n\nVoer uw accountnaam en wachtwoord in om het wisproces te starten."
    dialog_erase_credentials_fr="L'effacement de macOS nécessite une authentification à l'aide des informations d'identification du compte local.  \n\nVeuillez saisir votre nom de compte et votre mot de passe pour lancer le processus d'effacement."
    dialog_erase_credentials_es="El borrado de macOS requiere la autenticación mediante las credenciales de la cuenta local.  \n\nIntroduce tu nombre de cuenta y contraseña para iniciar el proceso de borrado."
    dialog_erase_credentials=dialog_erase_credentials_${user_language}

    # Dialogue localizations - ask for credentials - reinstall
    dialog_reinstall_credentials_en="Upgrading macOS requires authentication using local account credentials.  \n\nPlease enter your account name and password to start the upgrade process."
    dialog_reinstall_credentials_de="Das Upgrade von macOS erfordert eine Authentifizierung mit den Anmeldedaten des lokalen Kontos.  \n\nBitte geben Sie Ihren Kontonamen und Ihr Passwort ein, um den Upgrade-Prozess zu starten."
    dialog_reinstall_credentials_nl="Voor het upgraden van macOS is verificatie met behulp van lokale accountgegevens vereist.  \n\nVoer uw accountnaam en wachtwoord in om het upgradeproces te starten."
    dialog_reinstall_credentials_fr="La mise à niveau de macOS nécessite une authentification à l'aide des informations d'identification du compte local.  \n\nVeuillez saisir votre nom de compte et votre mot de passe pour lancer le processus de mise à niveau."
    dialog_reinstall_credentials_es="La actualización de macOS requiere la autenticación mediante las credenciales de la cuenta local.  \n\nIntroduce el nombre de tu cuenta y la contraseña para iniciar el proceso de actualización."
    dialog_reinstall_credentials=dialog_reinstall_credentials_${user_language}

    # Dialogue localizations - not a volume owner
    dialog_not_volume_owner_en="### Account is not a Volume Owner  \n\nPlease login using one of the following accounts and try again."
    dialog_not_volume_owner_de="### Konto ist kein Volume-Besitzer  \n\nBitte melden Sie sich mit einem der folgenden Konten an und versuchen Sie es erneut."
    dialog_not_volume_owner_nl="### Account is geen volume-eigenaar  \n\nLog in met een van de volgende accounts en probeer het opnieuw."
    dialog_not_volume_owner_fr="### Le compte n'est pas propriétaire du volume  \n\nVeuillez vous connecter en utilisant l'un des comptes suivants et réessayer."
    dialog_not_volume_owner_es="### La cuenta de usuario no es un Volume Owner   \n\nPor favor, inicie sesión con una de las siguientes cuentas de usuario e inténtelo de nuevo."
    dialog_not_volume_owner=dialog_not_volume_owner_${user_language}

    # Dialogue localizations - invalid user
    dialog_invalid_user_en="### Incorrect user  \n\nThis account cannot be used to to perform the reinstall"
    dialog_invalid_user_de="### Falsche Benutzer  \n\nDieses Konto kann nicht zur Durchführung der Neuinstallation verwendet werden"
    dialog_invalid_user_nl="### Incorrecte account  \n\nDit account kan niet worden gebruikt om de herinstallatie uit te voeren"
    dialog_invalid_user_fr="### Mauvais utilisateur  \n\nCe compte ne peut pas être utilisé pour effectuer la réinstallation"
    dialog_invalid_user_es="### Usuario incorrecto  \n\nEsta cuenta de usuario no puede ser utilizada para realizar la reinstalación"
    dialog_invalid_user=dialog_invalid_user_${user_language}

    # Dialogue localizations - invalid password
    dialog_invalid_password_en="### Incorrect password  \n\nThe password entered is NOT the login password for"
    dialog_invalid_password_de="### Falsches Passwort  \n\nDas eingegebene Passwort ist NICHT das Anmeldepasswort für"
    dialog_invalid_password_nl="### Incorrect wachtwoord  \n\nHet ingevoerde wachtwoord is NIET het inlogwachtwoord voor"
    dialog_invalid_password_fr="### Mot de passe erroné  \n\nLe mot de passe entré n'est PAS le mot de passe de connexion pour"
    dialog_invalid_password_es="### Contraseña incorrecta  \n\nLa contraseña introducida NO es la contraseña de acceso a"
    dialog_invalid_password=dialog_invalid_password_${user_language}

    # Dialogue localizations - buttons - confirm
    dialog_confirmation_button_en="Confirm"
    dialog_confirmation_button_de="Bestätigen"
    dialog_confirmation_button_nl="Bevestig"
    dialog_confirmation_button_fr="Confirmer"
    dialog_confirmation_button_es="Confirmar"
    dialog_confirmation_button=dialog_confirmation_button_${user_language}

    # Dialogue localizations - buttons - cancel
    dialog_cancel_button_en="Cancel"
    dialog_cancel_button_de="Abbrechen"
    dialog_cancel_button_nl="Annuleren"
    dialog_cancel_button_fr="Annuler"
    dialog_cancel_button_es="Cancelar"
    dialog_cancel_button=dialog_cancel_button_${user_language}

    # Dialogue localizations - buttons - enter
    dialog_enter_button_en="Enter"
    dialog_enter_button_de="Eingeben"
    dialog_enter_button_nl="Enter"
    dialog_enter_button_fr="Entrer"
    dialog_enter_button_es="Entrar"
    dialog_enter_button=dialog_enter_button_${user_language}
}

# -----------------------------------------------------------------------------
# Set the Seed Program using seedutil - this is required when using 
# softwareupdate --fetch-full-installer
# -----------------------------------------------------------------------------
set_seedprogram() {
    current_seed=$(/System/Library/PrivateFrameworks/Seeding.framework/Versions/A/Resources/seedutil current | grep "Currently enrolled in:" | sed 's|Currently enrolled in: ||')
    if [[ $seedprogram ]]; then
        writelog "[set_seedprogram] $seedprogram seed program selected"
        if [[ "$current_seed" == "$seedprogram" ]]; then
            writelog "[set_seedprogram] already enrolled in $seedprogram"
        else
            seedutilresult=$(/System/Library/PrivateFrameworks/Seeding.framework/Versions/A/Resources/seedutil enroll "$seedprogram")
            if [[ "$seedutilresult" == *"*NOT*"* ]]; then
                writelog "[set_seedprogram] ERROR: Unable to change to the $seedprogram seed program. You might get unexpected results."
                echo "progresstext: ERROR: Unable to change to the $seedprogram seed program." >> "$dialog_log"
                sleep 5
            fi
        fi
    else
        writelog "[set_seedprogram] Standard seed program selected"
        if [[ "$current_seed" == "(null)" ]]; then
            writelog "[set_seedprogram] already unenrolled"
        else
            seedutilresult=$(/System/Library/PrivateFrameworks/Seeding.framework/Versions/A/Resources/seedutil unenroll)
            if [[ ! "$seedutilresult" == *"Program: (null)"* ]]; then
                writelog "[set_seedprogram] ERROR: Unable to unenroll seed program. You might get unexpected results."
                echo "progresstext: ERROR: Unable to unenroll seed program.." >> "$dialog_log"
                sleep 5
           fi
        fi
    fi
    sleep 5
    current_seed=$(/System/Library/PrivateFrameworks/Seeding.framework/Versions/A/Resources/seedutil current | grep "Currently enrolled in:" | sed 's|Currently enrolled in: ||')
    writelog "[set_seedprogram] Currently enrolled in $current_seed seed program."
}

# -----------------------------------------------------------------------------
# Usage message
# -----------------------------------------------------------------------------
show_help() {
    echo
    /bin/cat << HELP
    $script_name v$version, a script by @GrahamRPugh

    Common usage:
    [sudo] ./$script_name.sh [options]

    Standard options for list, download, reinstall and erase: 

    --list              List available updates only (don't download anything)
    [no flags]          Finds latest current production, non-forked version
                        of macOS, downloads it.
    --move              Moves the downloaded macOS installer to $installer_directory
    --reinstall         After download, reinstalls macOS without erasing the
                        current system
    --erase             After download, erases the current system
                        and reinstalls macOS.
    --confirm           Displays a confirmation dialog prior to erasing or reinstalling macOS.
    --check-power       Checks for AC power if set.
    --power-wait-limit NN
                        Maximum seconds to wait for detection of AC power, if
                        --check-power is set. Default is 60.
    --check-fmm         Prompt the user to disable Find My Mac before proceeding, when using --erase
    --fmm-wait-limit NN Maximum seconds to wait for removal of Find My Mac, if
                        --check-fmm is set. Default is 300.

    Options for filtering which installer to download/use:

    --os X.Y            Finds a specific inputted OS version of macOS if available
                        and downloads it if so. Will choose the latest matching build.
    --version X.Y.Z     Finds a specific inputted minor version of macOS if available
                        and downloads it if so. Will choose the latest matching build.
    --build XYZ         Finds a specific inputted build of macOS if available
                        and downloads it if so.
    --sameos            Finds the version of macOS that matches the
                        existing system version, downloads it. Most useful with --erase.
    --samebuild         Finds the build of macOS that matches the
                        existing system version, downloads it. Most useful with --erase.
    --update            Checks that an existing installer on the system is still the most current
                        valid build, and if not, it will delete it and download the current installer.
    --replace-invalid   Checks that an existing installer on the system is still valid
                        i.e. would successfully build on this system. If not, deletes it
                        and downloads the current installer within the limits set by --os or --version.
    --overwrite         Delete any existing macOS installer found in $installer_directory and download
                        the current installer within the limits set by --os or --version.
    --clear-cache-only  When used in conjunction with --overwrite, --update or --replace-invalid,
                        the existing installer is removed but not replaced. This is useful
                        for running the script after an upgrade to clear the working files.
    --cleanup-after-use Creates a LaunchDaemon to delete $workdir after use. Mainly useful
                        in conjunction with the --reinstall option.


    Advanced options:

    --newvolumename     If using the --erase option, lets you customize the name of the
                        clean volume. Default is 'Macintosh HD'.
    --preinstall-command 'some arbitrary command'
                        Supply a shell command to run immediately prior to startosinstall
                        running. An example might be 'jamf recon -department Spare'.
                        Ensure that the command is in quotes.
    --postinstall-command 'some arbitrary command'
                        Supply a shell command to run immediately after startosinstall
                        completes preparation, but before reboot.
                        An example might be 'jamf recon -department Spare'.
                        Ensure that the command is in quotes.
    --catalog ...       Override the default catalog with one from a different OS 
                        (overrides --seed/--seedprogram).
    --catalogurl ...    Select a non-standard catalog URL (overrides --seed/--seedprogram).
    --caching-server ...
                        Set mist-cli to use a Caching Server, specifying the URL to the server.
    --pkg               Creates a package from the installer. Ignored if --move, --erase or --reinstall is selected.
                        Note that mist takes a long time to build the package from the complete installer, so
                        this method is not recommended for normal workflows.
    --keep-pkg          Retains a cached package if --move is used to extract an installer from it.
    --fs                Uses full-screen windows for all stages, not just the
                        preparation phase.
    --no-fs             Replaces the full-screen dialog window with a smaller dialog,
                        so you can still access the desktop while the script runs.
    --beta              Include beta versions in the search. Works with the no-flag
                        (i.e. automatic), --os and --version arguments.
    --path /path/to     Overrides the destination of --move to a specified directory
    --min-drive-space   Override the default minimum space required for startosinstall
                        to run (45 GB).
    --no-curl           Prevents the download of swiftDialog or mist in case your
                        security team don't like it.
    --no-timeout        The script will normally timeout if the installer has not successfully
                        prepared after 1 hour. This extends that time limit to 1 day.

    Extra packages:
        startosinstall --eraseinstall can install packages after the new installation. 
        By default, erase-install.sh will look for packages in $workdir/extras. 

    --extras /path/to   Overrides the path to search for extra packages

    Parameters for use with Apple Silicon Mac:
        Note that startosinstall requires user authentication on AS Mac. The user
        must have a Secure Token. This script checks for the Secure Token of the
        supplied user. A dialog is used to supply the password, so
        this script cannot be run at the login window or from remote terminal.

    --max-password-attempts NN | infinite
                        Overrides the default of 5 attempts to ask for the user's password. Using
                        'infinite' will disable the Cancel button and asking until the password is
                        successfully verified.

    Experimental features:

    --fetch-full-installer | --ffi | -f
                        Obtain the installer using 'softwareupdate --fetch-full-installer' method instead of
                        using mist
    --list              List installers using 'softwareupdate --list-full-installers' when
                        called with --fetch-full-installer
    --seed ...          Select a non-standard seed program. This is only used with --fetch-full-installer 
                        options.
    --rebootdelay NN    Delays the reboot after preparation has finished by NN seconds (max 300)
                        (--reinstall option only)
    --kc                Keychain containing a user password (do not use the login keychain!!)
    --kc-pass           Password to open the keychain
    --kc-service        The name of the key containing the account and password
    --credentials       A base64 credential set. Only works in conjunction with
    --i-know-the-security-risks-and-i-still-want-to-supply-a-password-in-plain-text
    --silent            Silent mode. No dialogs. Requires use of keychain for Apple Silicon 
                        to provide a password, or the --credentials mode.
    --quiet             Remove output from mist during installer download. Note that no progress 
                        is shown.
    --preservecontainer Preserves other volumes in your APFS container when using --erase
    --set-securebootlevel 
                        Resets Secure Boot Level to High when using --erase
    --clear-firmware    Clears the firmware NVRAM variables when using --erase

    Parameters useful in testing this script:

    --test-run          Run through the script right to the end, but do not actually
                        run the 'startosinstall' command. The command that would be
                        run is shown in stdout.
    --workdir /path/to  Supply an alternative working directory. The default is the same
                        directory in which erase-install.sh is saved.
    --cache-downloads   Caches mist downloads in a temporary directory in /private/tmp/com.ninxsoft.mist
                        Useful when running repeated tests.
HELP
    exit
}

# -----------------------------------------------------------------------------
# Run softwareupdate --list-full-installers and output to a file
# Includes some fallbacks, because this function might not be available in some 
# versions of Catalina
# -----------------------------------------------------------------------------
run_list_full_installers() {
    # include betas if selected
    if [[ $beta == "yes" ]]; then
        writelog "[run_list_full_installers] Beta versions included"
        if [[ ! $seedprogram ]]; then
            seedprogram="PublicSeed"
        fi
    fi
    set_seedprogram

    echo
    # try up to 3 times to workaround bug when changing seed programs
    try=3
    while [[ $try -gt 0 ]]; do
        if /usr/sbin/softwareupdate --list-full-installers | grep -v "Deferred: YES" > "$workdir/ffi-list-full-installers.txt"; then
            if [[ $(grep -c -E "Version:" "$workdir/ffi-list-full-installers.txt") -ge 1 ]]; then
                break
            fi
        fi
        ((try--))
    done
    if [[ $try -eq 0 ]]; then
        writelog "[run_list_full_installers] Could not obtain installer information using softwareupdate."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Unpack an installer package to the Applications folder
# -----------------------------------------------------------------------------
unpack_pkg_to_applications_folder() {
    # if dealing with a package we now have to extract it and check it's valid
    if [[ -f "$working_installer_pkg" ]]; then
        writelog "[unpack_pkg_to_applications_folder] Unpacking $working_installer_pkg into /Applications folder"
        if /usr/sbin/installer -pkg "$working_installer_pkg" -tgt / ; then
            working_macos_app=$( find /Applications -maxdepth 1 -name 'Install macOS*.app' -type d -print -quit 2>/dev/null )
            if [[ -d "$working_macos_app" && "$keep_pkg" != "yes" ]]; then
                writelog "[unpack_pkg_to_applications_folder] Deleting $working_installer_pkg"
                rm -f "$working_installer_pkg"
                working_installer_pkg=""
            fi
        else
            writelog "[unpack_pkg_to_applications_folder] ERROR - $working_installer_pkg could not be unpacked"
            exit 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Open dialog to show that the user is not valid for authenticating 
# startosinstall
# This is required on Apple Silicon Mac
# -----------------------------------------------------------------------------
user_is_invalid() {
    # required for Silicon Macs
    writelog "[user_is_invalid] ERROR - user was not validated."
    if [[ ! $silent ]]; then
        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        dialog_args+=(
            "--title"
            "${dialog_window_title}"
            "--icon"
            "${dialog_warning_icon}"
            "--iconsize"
            "128"
            "--overlayicon"
            "SF=person.fill.xmark,colour=red"
            "--message"
            "${(P)dialog_invalid_user}"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# Open dialog to show that the password is not valid
# This is required on Apple Silicon Mac
# -----------------------------------------------------------------------------
password_is_invalid() {
    # required for Silicon Macs
    writelog "[password_is_invalid] ERROR - password is invalid."
    if [[ ! $silent ]]; then
        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        dialog_args+=(
            "--title"
            "${dialog_window_title}"
            "--icon"
            "${dialog_confirmation_icon}"
            "--iconsize"
            "128"
            "--overlayicon"
            "SF=person.fill.xmark,colour=red"
            "--message"
            "${(P)dialog_invalid_password} $user"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# Open dialog to show that the user is not a Volume Owner.
# This is required on Apple Silicon Mac
# -----------------------------------------------------------------------------
# shellcheck disable=SC2317
user_not_volume_owner() {
    # required for Silicon Macs
    writelog "[user_is_invalid] ERROR - user is not a Volume Owner."
    if [[ ! $silent ]]; then
        # set the dialog command arguments
        get_default_dialog_args "utility"
        dialog_args=("${default_dialog_args[@]}")
        dialog_args+=(
            "--title"
            "${dialog_window_title}"
            "--icon"
            "${dialog_warning_icon}"
            "--iconsize"
            "128"
            "--overlayicon"
            "SF=person.fill.xmark,colour=red"
            "--message"
            "$account_shortname ${(P)dialog_not_volume_owner}: ${enabled_users}"
        )
        # run the dialog command
        "$dialog_bin" "${dialog_args[@]}" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# Rotate existing log files up to a maximum of 9 log files
# Older files will be overwritten
# -----------------------------------------------------------------------------
log_rotate() {
    # logs probably cannot be rotated when running as root
    if [[ $EUID -ne 0 ]]; then
        writelog "[log_rotate] Not running as root so cannot rotate logs"
        return
    fi

    writelog "[log_rotate] Start rotating logs in $logdir"
    max_log_keep=9

    # move all logs up one file
    i="$max_log_keep"
    while [[ "$i" -gt 0 ]];do
        current_filename="$LOG_FILE.$((i-1))"
        new_filename="$LOG_FILE.$i"
        if [[ -f "$current_filename" ]];then
            writelog "[log_rotate] moving $current_filename to $new_filename"
            mv "$current_filename" "$new_filename"
        fi
        ((i--))
    done

    if [[ -f "$LOG_FILE" ]];then
        writelog "[log_rotate] moving $LOG_FILE to $LOG_FILE.1"
        mv "$LOG_FILE" "$LOG_FILE.1"
    fi

    # now create the new log file
    echo "" > "$LOG_FILE"
    exec > >(tee "${LOG_FILE}") 2>&1

    writelog "[log_rotate] Finished rotating logs in $logdir"
}

# -----------------------------------------------------------------------------
# Add context to log messages
# -----------------------------------------------------------------------------
writelog() {
    DATE=$(date +%Y-%m-%d\ %H:%M:%S)
    echo "$DATE | v$version | $1"
}

# =============================================================================
# Main Body 
# =============================================================================

# ensure the finish function is executed when exit is signaled
trap "finish" EXIT

# ensure the finish function is executed and an error code is returned when the script is TERMinated or INTerrupted
trap "terminate" SIGINT SIGTERM

# ensure some cleanup is done after startosinstall is run (thanks @frogor!)
trap "post_prep_work" SIGUSR1

# Safety mechanism to prevent unwanted wipe while testing
erase="no"
reinstall="no"

# default minimum drive space in GB
# Note that the amount of space required varies between macOS installer and system versions.
# Override this default value with the --min-drive-space option.
min_drive_space=45

# default max_password_attempts to 5
max_password_attempts=5

# set language and localisations
set_localisations

# predefine arrays
preinstall_command=()
postinstall_command=()

# print out all the arguments
all_args="$*"

while test $# -gt 0 ; do
    case "$1" in
        -r|--reinstall) 
            reinstall="yes"
            ;;
        -e|--erase) erase="yes"
            ;;
        -m|--move) move="yes"
            ;;
        -s|--samebuild) samebuild="yes"
            ;;
        -t|--sameos) sameos="yes"
            ;;
        -o|--overwrite) overwrite="yes"
            ;;
        -x|--replace-invalid) replace_invalid_installer="yes"
            ;;
        -u|--update) update_installer="yes"
            ;;
        -c|--confirm) confirm="yes"
            ;;
        --beta) beta="yes"
            ;;
        --preservecontainer) preservecontainer="yes"
            ;;
        -f|--ffi|--fetch-full-installer) ffi="yes"
            ;;
        -l|--list) list="yes"
            ;;
        --silent) silent="yes"
            ;;
        --pkg) pkg_installer="yes"
            ;;
        --keep-pkg) keep_pkg="yes"
            ;;
        --no-curl) no_curl="yes"
            ;;
        --no-timeout) no_timeout="yes"
            ;;
        --dialog-on-download) dl_dialog="yes"
            ;;
        --no-fs) no_fs="yes"
            ;;
        --fs) fs="yes"
            ;;
        --skip-validation) skip_validation="yes"
            ;;
        --user)
            shift
            account_shortname="$1"
            ;;
        --max-password-attempts)
            shift
            if [[ ( $1 == "infinite" ) || ( $1 -gt 0 ) ]]; then
                max_password_attempts="$1"
            fi
            ;;
        --rebootdelay)
            shift
            rebootdelay="$1"
            if [[ $rebootdelay -gt 300 ]]; then
                rebootdelay=300
            fi
            ;;
        --test-run) test_run="yes"
            ;;
        --caching-server)
            shift
            caching_server="$1"
            ;;
        --cache-downloads) cache_downloads="yes"
            ;;
        --clear-cache-only) clear_cache="yes"
            ;;
        --cleanup-after-use) cleanup_after_use="yes"
            ;;
        --check-fmm) check_fmm="yes"
            ;;
        --fmm-wait-limit)
            shift
            fmm_wait_timer="$1"
            ;;
        --set-securebootlevel) set_secureboot="yes"
            ;;
        --clear-firmware) clear_firmware="yes"
            ;;
        --check-power)
            check_power="yes"
            ;;
        --quiet)
            quiet="yes"
            ;;
        --power-wait-limit)
            shift
            power_wait_timer="$1"
            ;;
        --min-drive-space)
            shift
            min_drive_space="$1"
            ;;
        --seed|--seedprogram)
            shift
            seedprogram="$1"
            ;;
        --catalogurl)
            shift
            catalogurl="$1"
            ;;
        --catalog)
            shift
            catalog="$1"
            ;;
        --path)
            shift
            installer_directory="$1"
            ;;
        --extras)
            shift
            extras_directory="$1"
            ;;
        --os)
            shift
            prechosen_os="$1"
            ;;
        --newvolumename)
            shift
            newvolumename="$1"
            ;;
        --version)
            shift
            prechosen_version="$1"
            ;;
        --build)
            shift
            prechosen_build="$1"
            ;;
        --workdir)
            shift
            workdir="$1"
            ;;
        --preinstall-command)
            shift
            preinstall_command+=("$1")
            ;;
        --postinstall-command)
            shift
            postinstall_command+=("$1")
            ;;
        --very-insecure-mode) very_insecure_mode="yes"
            ;;
        --credentials)
            shift
            credentials="$1"
            ;;
        --kc)
            shift
            kc="$1"
            ;;
        --kc-pass)
            shift
            kc_pass="$1"
            ;;
        --kc-service)
            shift
            kc_service="$1"
            ;;
        --kc=*)
            kc=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --kc-pass*)
            kc_pass=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --kc-service*)
            kc_service=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --power-wait-limit*)
            power_wait_timer=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --min-drive-space*)
            min_drive_space=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --seedprogram*)
            seedprogram=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --catalogurl*)
            catalogurl=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --catalog*)
            catalog=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --caching-server*)
            caching_server=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --path*)
            installer_directory=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --extras*)
            extras_directory=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --os*)
            prechosen_os=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --user*)
            account_shortname=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --max-password-attempts*)
            new_max_password_attempts=$(echo "$1" | sed -e 's|^[^=]*=||g')
            if [[ ( $new_max_password_attempts == "infinite" ) || ( $new_max_password_attempts -gt 0 ) ]]; then
                max_password_attempts="$new_max_password_attempts"
            fi
            ;;
        --rebootdelay*)
            rebootdelay=$(echo "$1" | sed -e 's|^[^=]*=||g')
            if [[ $rebootdelay -gt 300 ]]; then
                rebootdelay=300
            fi
            ;;
        --version*)
            prechosen_version=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --build*)
            prechosen_build=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --workdir*)
            workdir=$(echo "$1" | sed -e 's|^[^=]*=||g')
            ;;
        --preinstall-command*)
            command=$(echo "$1" | sed -e 's|^[^=]*=||g')
            preinstall_command+=("$command")
            ;;
        --postinstall-command*)
            command=$(echo "$1" | sed -e 's|^[^=]*=||g')
            postinstall_command+=("$command")
            ;;
        -h|--help) show_help
            ;;
    esac
    shift
done

# output that the script has started running
echo
writelog "[$script_name] v$version script execution started: $(date)"
echo
writelog "[$script_name] Arguments provided: $all_args"

# exit out or correct for incompatible options
if [[ $erase == "yes" && $reinstall == "yes" ]]; then
    writelog "[$script_name] ERROR: Choose either --erase or --reinstall options, but not both!"
    exit 1
elif [[ ($prechosen_os && $prechosen_version) || ($prechosen_os && $prechosen_build) || ($prechosen_version && $prechosen_build) || ($sameos && $prechosen_version) || ($sameos && $prechosen_os) || ($sameos && $prechosen_build) ]]; then
    writelog "[$script_name] ERROR: Choose a maximum of one of the --os, --version, --build, or --sameos options at the same time!"
    exit 1
elif [[ ($overwrite == "yes" && $update_installer == "yes") || ($replace_invalid_installer == "yes" && $overwrite == "yes") || ($replace_invalid_installer == "yes" && $update_installer == "yes") ]]; then
    writelog "[$script_name] ERROR: Choose a maximum of one of the --overwrite, --update, or --replace-invalid options at the same time!"
    exit 1
fi

# account for when people mistakenly put a version string instead of a major OS
if [[ "$prechosen_os" ]]; then
    prechosen_os_check=$(cut -d. -f1 <<< "$prechosen_os")
    if [[ $prechosen_os_check = 10 ]]; then
        prechosen_os=$(cut -d. -f1,2 <<< "$prechosen_os")
    else
        prechosen_os=$(cut -d. -f1 <<< "$prechosen_os")
    fi
fi

# announce if the Test Run mode is implemented
if [[ $erase == "yes" || $reinstall == "yes" ]]; then
    if [[ $test_run == "yes" ]]; then
        echo
        writelog "*** TEST-RUN ONLY! ***"
        writelog "* This script will perform all tasks up to the point of erase or reinstall,"
        writelog "* but will not actually erase or reinstall."
        writelog "* Remove the --test-run argument to perform the erase or reinstall."
        writelog "**********************"
        echo
    fi
fi

# some options vary based on installer versions
system_version=$( /usr/bin/sw_vers -productVersion )
system_build=$( /usr/bin/sw_vers -buildVersion )
system_os=$(cut -d. -f 1 <<< "$system_version")
if [[ $system_os -eq 10 ]]; then
    system_version_major=$(cut -d. -f1,2 <<< "$system_version")
    system_version_minor=$(cut -d. -f3 <<< "$system_version")
else
    system_version_major=$(cut -d. -f1 <<< "$system_version")
    system_version_minor=$(cut -d. -f2,3 <<< "$system_version")
fi

writelog "[$script_name] System version: $system_version (Build: $system_build)"

# check if this is the latest version of erase-install
if [[ "$no_curl" != "yes" && $(echo "$system_version_major >= 13" | bc) == 1 ]]; then
    latest_erase_install_vers=$(/usr/bin/curl https://api.github.com/repos/grahampugh/erase-install/releases/latest 2>/dev/null | plutil -extract name raw -- -)
    if [[ $(echo "$latest_erase_install_vers > $version" | bc) -eq 1 ]]; then
        writelog "[$script_name] A newer version of this script is available. Visit https://github.com/grahampugh/erase-install/releases/tag/v$latest_erase_install_vers to obtain the latest version."
    fi
fi

# bail if system is older than macOS 10.15
if [[ $(echo "$system_version_major < 10.15" | bc) == 1 ]]; then
    writelog "[$script_name] This script requires macOS 10.15 or newer. Please use version 27.x of erase-install.sh on older systems."
    echo
    exit 1
fi

# create tmp working and log directories if not running as root
if [[ $EUID -ne 0 && "$list" == "yes" ]]; then
    workdir=$(/usr/bin/mktemp -d /var/tmp/erase-install.XXX)
    writelog "[$script_name] Not running as root so will write output and logs to $workdir."
    logdir="$workdir"
fi

# ensure logdir and workdir exist
if [[ ! -d "$workdir" ]]; then
    writelog "[$script_name] Making working directory at $workdir"
    /bin/mkdir -p "$workdir"
fi
if [[ ! -d "$logdir" ]]; then
    writelog "[$script_name] Making log directory at $logdir"
    /bin/mkdir -p "$logdir"
fi

if [[ ! $silent ]]; then
    # bail if system is older than macOS 11 and --silent mode is not selected
    if [[ $(echo "$system_version_major < 11" | bc) == 1 ]]; then
        writelog "[$script_name] This script requires macOS 11 or newer in interactive mode. Please use version 27.x of erase-install.sh on older systems."
        echo
        exit 1
    fi
    # get dialog app if not silent mode
    check_for_swiftdialog_app
fi

# different dialog icon for OS older than macOS 13
if [[ $(echo "$system_version_major < 13" | bc) == 1 ]]; then
    dialog_confirmation_icon="/System/Applications/System Preferences.app"
fi

# /Applications is the only path for fetch-full-installer
if [[ $ffi ]]; then
    installer_directory="/Applications"
    if [[ $list == "yes" ]]; then
        list_installers="yes"
    fi
fi

# ensure installer_directory (--path) exists
if [[ ! -d "$installer_directory" ]]; then
    writelog "[$script_name] Making installer directory at $installer_directory"
    /bin/mkdir -p "$installer_directory"
fi

# all output from now on is written also to a log file
LOG_FILE="$logdir/erase-install.log"
log_rotate

# if getting a list from softwareupdate then we don't need to make any OS checks
if [[ $list == "yes" && ! $ffi ]]; then
    get_mist_list
    echo
    exit
elif [[ $list_installers ]]; then
    if [[ -f "$workdir/ffi-list-full-installers.txt" ]]; then 
        rm "$workdir/ffi-list-full-installers.txt"
    fi
    run_list_full_installers
    /bin/cat "$workdir/ffi-list-full-installers.txt"
    echo
    exit
fi

# everything after this point requires running as root, so stop here if not doing so
if [[ $EUID -ne 0 ]]; then
    writelog "[$script_name] Not running as root so cannot continue."
    exit
fi

# ensure computer does not go to sleep while running this script
writelog "[$script_name] Caffeinating this script (pid=$$)"
/usr/bin/caffeinate -dimsu -w $$ &

# place any extra packages that should be installed as part of the erase-install into this folder. The script will find them and install.
# https://derflounder.wordpress.com/2017/09/26/using-the-macos-high-sierra-os-installers-startosinstall-tool-to-install-additional-packages-as-post-upgrade-tasks/
extras_directory="$workdir/extras"

# set dynamic dialog titles
if [[ $erase == "yes" ]]; then
    dialog_window_title="${(P)dialog_erase_title}"
else
    dialog_window_title="${(P)dialog_reinstall_title}"
fi

if [[ $erase == "yes" || $reinstall == "yes" ]]; then
    # check for drive space if invoking erase or reinstall options
    check_free_space
fi

# Look for the installer
writelog "[$script_name] Looking for existing installer app or pkg"
find_existing_installer

# Work through various options to decide whether to replace an existing installer
if [[ $overwrite == "yes" && -d "$working_macos_app" && ! $list ]]; then
    # --overwrite option
    overwrite_existing_installer

elif [[ $overwrite == "yes" && ($pkg_installer && -f "$working_installer_pkg") && ! $list ]]; then
    # --overwrite option and --pkg option
    writelog "[$script_name] Deleting invalid installer package"
    rm -f "$working_installer_pkg"
    if [[ $clear_cache == "yes" ]]; then
        writelog "[$script_name] Quitting script as --clear-cache-only option was selected."
        # kill caffeinate
        kill_process "caffeinate"
        exit
    fi

elif [[ $invalid_installer_found == "yes" ]]; then 
    # --replace-invalid option: replace an existing installer if it is invalid
    if [[ -d "$working_macos_app" && ($replace_invalid_installer == "yes" || $update_installer == "yes") ]]; then
        overwrite_existing_installer
    elif [[ ($pkg_installer && ! -f "$working_installer_pkg") && $replace_invalid_installer == "yes" ]]; then
        writelog "[$script_name] Deleting invalid installer package"
        rm -f "$working_installer_pkg"
        overwrite_existing_installer
    elif [[ ($erase == "yes" || $reinstall == "yes") && $skip_validation != "yes" ]]; then
        writelog "[$script_name] ERROR: Invalid installer is present. Run with --overwrite option to ensure that a valid installer is obtained."
        # kill caffeinate
        kill_process "caffeinate"
        exit 1
    else
        writelog "[$script_name] ERROR: Invalid installer is present. --skip-validation was set so we will continue, but failure is highly likely!"
    fi

elif [[ "$prechosen_build" != "" ]]; then
    # automatically replace a cached installer if it does not match the requested build
    writelog "[$script_name] Checking if the cached installer matches requested build..."
    if [[ "$installer_build" ]]; then
        installer_darwin_version=${installer_build:0:2}
    elif [[ "$installer_pkg_build" ]]; then
        installer_darwin_version=${installer_pkg_build:0:2}
    fi
    compare_build_versions "$prechosen_build" "$installer_build"
    if [[ "$builds_match" != "yes" ]]; then
        writelog "[$script_name] Existing installer does not match requested build, so replacing..."
        overwrite_existing_installer
    else
        writelog "[$script_name] Existing installer matches requested build."
    fi

elif [[ "$prechosen_os" != "" ]]; then
    # check if the cached installer matches the requested OS
    # first, get the OS of the existing installer app or pkg
    if [[ "$installer_build" ]]; then
        installer_darwin_version=${installer_build:0:2}
    elif [[ "$installer_pkg_build" ]]; then
        installer_darwin_version=${installer_pkg_build:0:2}
    fi
    prechosen_darwin_version=$(get_darwin_from_os_version "$prechosen_os")
    if [[ $installer_darwin_version -ne $prechosen_darwin_version ]]; then
        writelog "[$script_name] Existing installer does not match requested OS ($prechosen_os), so replacing..."
        overwrite_existing_installer
    fi

elif [[ $update_installer == "yes" ]]; then
    # --update option: checks for a newer installer. This operates within the confines of the --sameos, --os, --version and --beta options if present
    if [[ -d "$working_macos_app" ]]; then
        writelog "[$script_name] Checking for newer installer"
        check_newer_available
        if [[ $newer_build_found == "yes" ]]; then
            writelog "[$script_name] Newer installer found so overwriting existing installer"
            overwrite_existing_installer
        elif [[ $clear_cache == "yes" ]]; then
            writelog "[$script_name] Quitting script as --clear-cache-only option was selected."
            # kill caffeinate
            kill_process "caffeinate"
            exit
        fi
    elif [[ $pkg_installer && -f "$working_installer_pkg" ]]; then
        writelog "[$script_name] Checking for newer installer package"
        check_newer_available
        if [[ $newer_build_found == "yes" ]]; then
            writelog "[$script_name] Newer installer found so deleting existing installer package"
            rm -f "$working_installer_pkg"
        fi
        if [[ $clear_cache == "yes" ]]; then
            writelog "[$script_name] Quitting script as --clear-cache-only option was selected."
            # kill caffeinate
            kill_process "caffeinate"
            exit
        fi
    fi
fi

# Silicon Macs require a username and password to run startosinstall
# We therefore need to be logged in to proceed, if we are going to erase or reinstall
# This goes before the download so users aren't waiting for the prompt for username
# Check for Apple Silicon using sysctl, because arch will not report arm64 if running under Rosetta.
[[ $(/usr/sbin/sysctl -q -n "hw.optional.arm64") -eq 1 ]] && arch="arm64" || arch=$(/usr/bin/arch)
writelog "[$script_name] Running on architecture $arch"
if [[ "$arch" == "arm64" && ($erase == "yes" || $reinstall == "yes") ]]; then
    if ! pgrep -q Finder ; then
        writelog "[$script_name] ERROR! The startosinstall binary requires a user to be logged in."
        echo
        # kill caffeinate
        kill_process "caffeinate"
        exit 1
    fi
    get_user_details
fi

# check for Find My
[[ "$check_fmm" == "yes"  && ($erase == "yes") ]] && check_fmm

# check for power
[[ "$check_power" == "yes"  && ($erase == "yes" || $reinstall == "yes") ]] && check_power_status

if [[ ! -d "$working_macos_app" && ! -f "$working_installer_pkg" ]]; then
    if [[ ! $silent ]]; then
        # if erasing or reinstalling, open a dialog to state that the download is taking place.
        if [[ $erase == "yes" || $reinstall == "yes" || $dl_dialog == "yes" ]]; then
            # if no_fs is set, show a utility window instead of the full screen display (for test purposes)
            if [[ $fs == "yes" ]]; then
                window_type="fullscreen"
                iconsize=200
            else
                window_type="utility"
                iconsize=100
            fi
            # set the dialog command arguments
            get_default_dialog_args "$window_type"
            dialog_args=("${default_dialog_args[@]}")
            dialog_args+=(
                "--title"
                "${(P)dialog_dl_title}"
                "--icon"
                "${dialog_confirmation_icon}"
                "--overlayicon"
                "SF=arrow.down"
                "--iconsize"
                "$iconsize"
                "--message"
                "${(P)dialog_dl_desc}"
                "--progress"
                "100"
            )
            # run the dialog command
            "$dialog_bin" "${dialog_args[@]}" 2>/dev/null & sleep 0.1
        fi

        if [[ $ffi ]]; then
            dialog_progress fetch-full-installer >/dev/null 2>&1 &
        else
            dialog_progress mist >/dev/null 2>&1 &
        fi
    fi
    # now run mist or softwareupdate to download the installer, showing progress
    if [[ $ffi ]]; then
        run_fetch_full_installer
    else
        run_mist
    fi
fi

if [[ -d "$working_macos_app" ]]; then
    writelog "[$script_name] Installer is at: $working_macos_app"
fi

# Move to $installer_directory if move_to_applications_folder flag is included
# Not relevant for fetch_full_installer option
if [[ $move == "yes" && ("$cached_installer_pkg" || "$cached_installer_app" || "$cached_sparseimage" || "$cached_dmg" ) ]]; then
    writelog "[$script_name] Invoking --move option"
    echo "progresstext: Moving installer to Applications folder" >> "$dialog_log"
    if [[ -f "$working_installer_pkg" ]]; then
        unpack_pkg_to_applications_folder
    else
        move_to_applications_folder
    fi
fi

if [[ $erase != "yes" && $reinstall != "yes" ]]; then
    if [[ ! $silent ]]; then
        # quit dialog when the download is complete
        writelog "[$script_name] Sending quit message to dialog log ($dialog_log)"
        echo "quit:" >> "$dialog_log" & sleep 0.1
    fi

    # Unmount the dmg
    if [[ ! $ffi ]]; then
        cached_installer=$(find /Volumes/*macOS* -maxdepth 2 -type d -name "Install*.app" -print -quit 2>/dev/null )
        if [[ -d "$cached_installer" ]]; then
            writelog "[$script_name] Mounted installer will be unmounted: $cached_installer"
            existing_installer_mount_point=$(echo "$cached_installer" | cut -d/ -f 1-3)
            diskutil unmount force "$existing_installer_mount_point"
        fi
    fi
    # Clear the working directory
    writelog "[$script_name] Cleaning working directory '$workdir/content'"
    rm -rf "$workdir/content"

    # kill caffeinate
    kill_process "caffeinate"
    echo
    exit
fi

# re-check if there is enough space after a possible installer download
check_free_space

# -----------------------------------------------------------------------------
# Steps beyond here are to run startosinstall
# -----------------------------------------------------------------------------

echo
# if we still have a packege we need to move it before we can install it
if [[ -f "$working_installer_pkg" ]]; then
    unpack_pkg_to_applications_folder
fi

# now look for an installer app
if [[ ! -d "$working_macos_app" ]]; then
    writelog "[$script_name] ERROR: Can't find the installer! "
    # kill caffeinate
    kill_process "caffeinate"
    exit 1
fi

# warnings
if [[ $erase == "yes" ]]; then 
    writelog "[$script_name] WARNING! Running $working_macos_app with eraseinstall option"
elif [[ $reinstall == "yes" ]]; then 
    writelog "[$script_name] WARNING! Running $working_macos_app with reinstall option"
fi
echo

if [[ ! $silent ]]; then
    # quit dialog when the download is complete
    writelog "[$script_name] Sending quit message to dialog log ($dialog_log)"
    echo "quit:" >> "$dialog_log" & sleep 0.1
fi

# if configured to do so, display a confirmation window to the user
if [[ $confirm == "yes" && ! $silent ]]; then
    confirm
fi

# set eraseinstall argument for erase option
install_args=()
if [[ $erase == "yes" ]]; then
    install_args+=("--eraseinstall")
fi

# reinstall option: determine SIP status, as the volume name is required in the startosinstall command if SIP is disabled
if [[ $reinstall == "yes" ]]; then
    if /usr/bin/csrutil status | sed -n 1p | grep -q 'disabled'; then
        volname=$(diskutil info -plist / | grep -A1 "VolumeName" | tail -n 1 | awk -F '<string>|</string>' '{ print $2; exit; }')
        install_args+=("--volume")
        install_args+=("/Volumes/$volname")
    fi
fi

# check for packages then add install_package_list to end of command line (empty if no packages found)
find_extra_packages

# some cli options vary based on installer versions
installer_build=$( /usr/bin/defaults read "$working_macos_app/Contents/Info.plist" DTSDKBuild )
installer_darwin_version=${installer_build:0:2}
# add --preservecontainer to the install arguments if specified (for macOS 10.14 (Darwin 18) and above)
if [[ $preservecontainer == "yes" ]]; then
    install_args+=("--preservecontainer")
fi

# macOS 11 (Darwin 20) and above requires the --allowremoval option
if [[ $installer_darwin_version -ge 20 ]]; then
    install_args+=("--allowremoval")
fi

# macOS 10.15 (Darwin 19) and above can use the --rebootdelay option (reinstall option only)
if [[ "$rebootdelay" -gt 0 && "$reinstall" == "yes" ]]; then
    install_args+=("--rebootdelay")
    install_args+=("$rebootdelay")
else
    # cancel rebootdelay for older systems as we don't support it
    rebootdelay=0
fi

# macOS 10.15 (Darwin 19) and above requires the --forcequitapps options
install_args+=("--forcequitapps")

# pass new volume name if specified
if [[ $erase == "yes" && $newvolumename ]]; then
    install_args+=("--newvolumename")
    install_args+=("$newvolumename")
fi

# icon for dialogs
macos_installer_icon="$working_macos_app/Contents/Resources/InstallAssistant.icns"
if [[ -f "$macos_installer_icon" ]]; then
    dialog_install_icon="$macos_installer_icon"
else
    dialog_install_icon="warning"
fi

# window type for erase and reinstall dialogs
if [[ $fs == "yes" || ($erase == "yes" && $no_fs != "yes") || ($reinstall == "yes" && $no_fs != "yes" && $rebootdelay -lt 10) ]]; then
    window_type="fullscreen"
    iconsize=200
else
    window_type="utility"
    iconsize=100
fi

# dialogs for erase
if [[ $erase == "yes" && ! $silent ]]; then
    # set the dialog command arguments
    get_default_dialog_args "$window_type"
    dialog_args=("${default_dialog_args[@]}")
    dialog_args+=(
        "--title"
        "${(P)dialog_erase_title}"
        "--icon"
        "${dialog_install_icon}"
        "--message"
        "${(P)dialog_erase_desc}"
        "--progress"
        "100"
    )
    # run the dialog command
    "$dialog_bin" "${dialog_args[@]}" 2>/dev/null & sleep 0.1

    dialog_progress startosinstall >/dev/null 2>&1 &

# dialogs for reinstallation
elif [[ $reinstall == "yes" && ! $silent ]]; then
    # set the dialog command arguments
    get_default_dialog_args "$window_type"
    dialog_args=("${default_dialog_args[@]}")
    dialog_args+=(
        "--title"
        "${(P)dialog_reinstall_title}"
        "--icon"
        "${dialog_install_icon}"
        "--message"
        "${(P)dialog_reinstall_desc}"
        "--progress"
        "100"
    )
    # run the dialog command
    "$dialog_bin" "${dialog_args[@]}" 2>/dev/null & sleep 0.1

    dialog_progress startosinstall >/dev/null 2>&1 &
fi

# set launchdaemon to remove $workdir if $cleanup_after_use is set
if [[ $cleanup_after_use != "" && $test_run != "yes" ]]; then
    writelog "[$script_name] Writing LaunchDaemon which will remove $workdir at next boot"
    create_launchdaemon_to_remove_workdir
fi

# run preinstall commands
for command in "${preinstall_command[@]}"; do
    if [[ $command ]]; then
        writelog "[$script_name] Now running preinstall command: $command"
        eval "$command"
    fi
done

# preparation for arm64
if [[ "$arch" == "arm64" ]]; then
    install_args+=("--stdinpass")
    install_args+=("--user")
    install_args+=("$account_shortname")
    if [[ $test_run != "yes" && "$erase" == "yes" ]]; then
        # startosinstall --eraseinstall may fail if a user was converted to admin using the Privileges app
        # this command supposedly fixes this problem (experimental!)
        writelog "[$script_name] updating preboot files (takes a few seconds)..."
        sleep 0.1
        /bin/echo "progresstext: Updating preboot files..." >> "$dialog_log"
        if /usr/sbin/diskutil apfs updatepreboot / > /dev/null; then
            writelog "[$script_name] preboot files updated"
        else
            writelog "[$script_name] WARNING! preboot files could not be updated."
        fi

        # if --clear-firmware (thanks @mvught)
        if [[ "$clear_firmware" == "yes" ]]; then
            # note this process can take up to 10 seconds
            writelog "[$script_name] Clearing the firmware settings with the nvram command"
            /bin/echo "progresstext: Clearing firmware settings..." >> "$dialog_log"
            if /usr/sbin/nvram -c; then
                writelog "[$script_name] nvram command exited with success"
            else
                writelog "[$script_name] WARNING! nvram command exited with error."
            fi
        fi

        # if --set-securebootlevel (thanks @mvught)
        if [[ "$set_secureboot" == "yes" ]]; then
            # note this process can take up to 10 seconds
            writelog "[$script_name] Setting high secure boot level with bputil command"
            /bin/echo "progresstext: Setting high secure boot level..." >> "$dialog_log"
            if /usr/bin/bputil -f -u "$current_user" -p "$account_password"; then
                writelog "[$script_name] bputil command exited with success"
            else
                writelog "[$script_name] WARNING! bputil command exited with error."
            fi
        fi
    fi
fi

# fix for a bug in mist-cli to correct the installer app permissions
/bin/chmod -R 755 "$working_macos_app"

# now actually run startosinstall
launch_startosinstall

if [[ "$arch" == "arm64" && $test_run != "yes" ]]; then
    writelog "[$script_name] Sending password to startosinstall"
    /bin/cat >&3 <<< "$account_password"
fi
exec 3>&-

# wait for cat command to quit, but no longer than 1 hour
sleep_time=3600
if [[ $no_timeout == "yes" ]]; then
    sleep_time=86400
fi

(sleep $sleep_time; writelog "[$script_name] Timeout reached for PID $pipePID!"; kill -TERM $pipePID) &
wait $pipePID

# we are not supposed to end up here due to USR1 signalling, so something went wrong.
writelog "[$script_name] Reached end of script unexpectedly. This probably means startosinstall failed to complete within $((sleep_time/60)) minutes."
exit 42
