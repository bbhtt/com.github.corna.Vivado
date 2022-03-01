#!/bin/bash

if [ -z "${XILINX_INSTALL_PATH:-}" ]; then
	XILINX_INSTALL_PATH="$XDG_DATA_HOME/xilinx-install"
fi

function xilinx_detect() {
	readarray -t installed_versions < <(find "$XILINX_INSTALL_PATH" -mindepth 2 -maxdepth 2 -type d -regex ".*/[0-9\.]+" -exec basename {} \; | sort | uniq)
}

function xilinx_detect_xsetup() {
	readarray -t installed_versions < <(find "$XILINX_INSTALL_PATH/.xinstall" -mindepth 2 -maxdepth 2 -type f -name xsetup -exec sh -c 'basename "$(dirname "$1")"' _ {} \; | sort)
}

function xilinx_install_vivado_if_missing() {
	if [ "${#installed_versions[@]}" -eq "0" ]; then
		zenity --class "$CURRENT_WM_CLASS" --width=400 --question --title "Missing software" --text "Xilinx Vivado Design Suite is not installed. Do you want to install it now?"
		xilinx_install
		xilinx_detect
	fi
}

function xilinx_choose_version() {
	xilinx_install_vivado_if_missing

	if [ "${#installed_versions[@]}" -eq "1" ]; then
		chosen_version=${installed_versions[0]}
	else
		local zenity_versions=()
		for version in "${installed_versions[@]}"; do
			zenity_versions+=(FALSE "$version")
		done
		zenity_versions[0]=TRUE
		chosen_version=$(zenity --class "$CURRENT_WM_CLASS" --list --title "Xilinx Vivado Design Suite version" --text "Which version do you want to use?" --radiolist --column "Pick" --column "Version" "${zenity_versions[@]}")
	fi
}

function xilinx_install() {
	XILINX_DOWNLOADER=$(dirname "${BASH_SOURCE[0]}")/download_vivado.py

	local installer_dir
	installer_dir="$XDG_DATA_HOME/xilinx-installer-tmpdir"
	trap "rm -rf \"$installer_dir\"" EXIT
	rm -rf "$installer_dir"

	local installer_path

	if zenity --class "$CURRENT_WM_CLASS" --width=400 --question --title "Download" --text "Do you want to automatically download the latest available version on xilinx.com?"; then

		# Get username and password
		local user_pass
		user_pass=$(zenity --class "$CURRENT_WM_CLASS" --password --title "xilinx.com login" --username)

		local user
		user=$(echo "$user_pass" | cut -d '|' -f 1)

		local pass
		pass=$(echo "$user_pass" | sed 's/^[^|]*|//')

		installer_path="$installer_dir/installer.bin"

		# Download Vivado
		echo "$pass" | \
			( "$XILINX_DOWNLOADER" "$user" "$installer_path" || ( zenity --class "$CURRENT_WM_CLASS" --width=400 --error --title "Download failed" --text "Unable to download the installer with the provided credentials."; exit 1 ) ) | \
			zenity --class "$CURRENT_WM_CLASS" --width=400 --progress --title="Downloading Vivado" --text "Retrieving download information..." --auto-close 

	else
		zenity --class "$CURRENT_WM_CLASS" --width=400 --info --title "Xilinx installer required" --text "Please download the Xilinx Unified installer and select it in the next window."

		# Launch the browser
		xdg-open 'https://www.xilinx.com/support/download.html'

		# Get the installer path
		installer_path=$(zenity --class "$CURRENT_WM_CLASS" --file-selection --title "Select the Xilinx installer (Xilinx_Unified_*_Lin64.bin)")
	fi

	zenity --class "$CURRENT_WM_CLASS" --width=600 --warning --text "The Xilinx installer will now start. Do not change the default installation path."

	# Extract the installer
	sh "$installer_path" --noexec --target "$installer_dir"

	# Get the installer version
	local installer_version
	installer_version=$(grep Vivado_Shortcuts_Vivado_LIN_SHORTCUT_NAME= "$installer_dir/data/dynamic_language_bundle.properties" | grep -Eo '[0-9]+\.[0-9]+')

	# Change the default installation folder
	sed -i "s|^DEFAULT_DESTINATION_FOLDER_LIN_Install=.*|DEFAULT_DESTINATION_FOLDER_LIN_Install=$XILINX_INSTALL_PATH|" "$installer_dir/data/dynamic_language_bundle.properties"

	# Run the installer
	mkdir -p "$XILINX_INSTALL_PATH"
	"$installer_dir/xsetup"

	# Apply the patch (ignoring failures)
	"$(dirname "${BASH_SOURCE[0]}")/patch_vitis_HwSpecFile.sh" "$XILINX_INSTALL_PATH/Vitis/$installer_version" || true

	rm -rf "$installer_dir"
	xilinx_detect
	zenity --class "$CURRENT_WM_CLASS" --width=600 --info --text "Installation is complete.\nTo allow access to the hardware devices (necessary to program them within Vivado and Vitis), run <b>cd \"$XILINX_INSTALL_PATH/Vivado/${installed_versions[0]}/data/xicom/cable_drivers/lin64/install_script/install_drivers/\" &amp;&amp; sudo ./install_drivers &amp;&amp; sudo udevadm control --reload</b>, then reconnect all the devices (if any)"
}

function xilinx_source_settings64() {
	local version_escaped_dot=${1/./\\.}

	local settings64_dir
	settings64_dir=$(mktemp -d)

	# Copy the ".settings64" scripts
	find "$XILINX_INSTALL_PATH" -maxdepth 3 -regextype posix-egrep -regex ".*/($version_escaped_dot|DocNav)/\.settings64[^/]*\.sh" -exec cp {} "$settings64_dir" \;

	# Get the original installation folder
	local installation_folder
	installation_folder=$(grep "[ \t]*export XILINX_VIVADO=" "$settings64_dir/.settings64-Vivado.sh")
	installation_folder=${installation_folder#*=}
	installation_folder=$(dirname $(dirname "$installation_folder"))

	# Fix the paths in .settings64*.sh (so that the installation can be freely moved)
	find "$settings64_dir" -type f -exec sed -i "s^$installation_folder^$XILINX_INSTALL_PATH^g" {} \;

	# Replace the absolute paths in Vivado/*/settings64.sh with relative ones
	sed "s|source .*/.settings64|source $settings64_dir/.settings64|g" "$XILINX_INSTALL_PATH/Vivado/$1/settings64.sh" > "$settings64_dir/settings64.sh"

	source "$settings64_dir/settings64.sh"
	rm -rf "$settings64_dir"

	# XIC is not added to the PATH by settings64: add it now
	if [ -d "$XILINX_INSTALL_PATH/xic" ]; then
		PATH=$XILINX_INSTALL_PATH/xic:$PATH
	fi
}

function xilinx_get_cmd_abs_path() {
	PATH=$(echo "$PATH" | sed -E 's@(^|:)/app/bin/?($|:)@:@g')
	export xilinx_cmd_abs_path
	xilinx_cmd_abs_path="$(which "$1")" || (zenity --class "$CURRENT_WM_CLASS" --width=400 --error --title "Missing software" --text "$2"; false)
	PATH=$PATH:/app/bin
}

function xilinx_versioned_install_if_needed() {
	xilinx_detect
	xilinx_choose_version
	xilinx_source_settings64 "$chosen_version"
	xilinx_get_cmd_abs_path "$1" "$1 $chosen_version is not installed, please run the installation wizard to install it."
}

function xilinx_install_if_needed() {
	xilinx_detect
	xilinx_install_vivado_if_missing
	chosen_version=${installed_versions[0]}
	xilinx_source_settings64 "$chosen_version"
	xilinx_get_cmd_abs_path "$1" "$1 is not installed, please run the installation wizard to install it."
}

function xilinx_xsetup_install_if_needed() {
	xilinx_detect_xsetup
	xilinx_choose_version
	PATH=$XILINX_INSTALL_PATH/.xinstall/$chosen_version:$PATH
	xilinx_get_cmd_abs_path xsetup "xsetup $chosen_version is not installed, please run the installation wizard to install it."
}
