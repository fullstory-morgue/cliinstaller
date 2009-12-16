#!/bin/sh                                                                   
#                                                                                 
# Copyright  (C) 2009 Nikolas Poniros <edhunter@sidux.com                                      
#                          
# heavily based on install-gui written by
#	Horst Tritremmel <peter_weber69@gmx.at>                        
#                                                                                 
# This program is free software; you can redistribute it and/or                   
# modify it under the terms of the GNU General Public License                     
# as published by the Free Software Foundation; either version 2                  
# of the License, or (at your option) any later version.                          
#                                                                                 
# This program is distributed in the hope that it will be useful,                 
# but WITHOUT ANY WARRANTY; without even the implied warranty of                  
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                   
# GNU General Public License for more details.                                    
#                                                                                 
# You should have received a copy of the GNU General Public License               
# along with this package; if not, write to the Free Software                     
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,                          
# MA 02110-1301, USA.                                                             
#                                                                                 
# On Debian GNU/Linux systems, the text of the GPL license can be                 
# found in /usr/share/common-licenses/GPL.                                        
#                                                                                 
# version: 0.2.4
#--------------------------------------------------------------------------

#Short description of the script:
#The script creates the config file ($HOME/.sidconfig) needed by the fll-installer
#and then calls the fll-installer to install sidux using said config file. 
#Exit codes are: 0 if successful, 1 if user abords before the config file is written
#2 if user abords after config file is written (whenever a user presses OK at an error message
#it is considered as a user abort even if he has no other choice)

call_help ()
{
	echo "Usage: installer-cli -I [interface]"
	echo "Options:"
	echo " -v print program version"
	echo " -h print this help message"
	echo " -I interface"
	echo "		select an interface to use with ssft."
	echo "		options are: text , dialog "
	echo "		Default is dialog"
	exit
}

while getopts vhI: opt
	do
		case $opt in
			v)  echo "Version: 0.2.4"; exit;;
			I)  interface="$OPTARG";;
			h)  call_help;;
		esac
	done

if [ $( id -u ) -ne 0 ]; then
	echo >&2 "E: You need to be root to run the script"
	exit 1
fi

if [ -f /usr/bin/ssft.sh ]; then
	. /usr/bin/ssft.sh || exit 1
	[ "${interface}" = "text" ] && SSFT_FRONTEND="${interface}" || SSFT_FRONTEND="dialog"
else
	echo "Please install ssft.sh"
	exit 1
fi

### DEFINE CONSTANTS ###
#------------------------------------------------------------------------------------------------------------
CONFIG_FILE="${HOME}/.sidconf"
SIGINT=2
SIGTERM=15
HOSTNAME_ALLOWED_CHARS="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
# '-' needs to be at the end because of grep
HOSTNAME_ALLOWED_CHAR_OTHERS="0123456789.-"
USERNAME_ALLOWED_CHARS="abcdefghijklmnopqrstuvwxyz0123456789.-"

# Dont change the order of the character because it might not work with grep anymore
NAME_NAME_NOT_ALLOWED_CHARS="]°!\"§$%&/(){}=?\`+*~#;:=,><|_^\\\[-"

PARTITION_PROG="cfdisk"
CHECK_IF_HOME_EXISTS="no"
HOME_PARTITION=""
IS_DISK_USB="no"
ROOT_IS_LVM="no"

# Temp file to hold a list of available partitions that can be used for installation
# (must be pre-formated)
PARTITIONS_LIST=$(mktemp /tmp/part_list.XXXXXXXX)
# I need 2 because I cant use sed -i
PARTITIONS_LIST_2=$(mktemp /tmp/part_list_2.XXXXXXXX)


if [ -f ${CONFIG_FILE} ]; then
	echo >&2 "E: Config file exists please remove it and run the script again"
	exit 1
fi


# If we use dialog as front-end then redirect all stderr to ERROR_LOG
if [ $SSFT_FRONTEND = "dialog" ]; then
	
	# Log file to write in potential error messages
	ERROR_LOG=$(mktemp /tmp/error_log.XXXXXXXX)

	exec 3>&2

	# Use this so all stderr goes to ERROR_LOG
	exec 2> $ERROR_LOG
fi


### VARIABLES NEEDED BY THE CONFIG FILE
#----------------------------------------------------------------------------------------------------------------------------

FORMAT_HD="yes"
FILESYSTEM="ext3"
ROOT_PARTITION=""
MOUNT_POINT_LIST=""
IGNORE_DISK_SPACE="no"
AUTO_SWAP="yes"
SWAP_LIST=""
REAL_NAME=""
USERNAME=""
USERPASS=""
ROOTPASS=""
# not using HOSTNAME as its an evn variable
HOST_NAME="siduxbox"
SERVICES_LIST=""
BOOT_LOADER="grub"
BOOT_DISK="no"
BOOT_WHERE="mbr"
AUTOMOUNT_BOOT="yes"

# make sure that if ctrl+C is pushed, the config file and the temporary files are removed
# same for SIGTERM
trap "rm -f ${CONFIG_FILE}; rm -f ${PARTITIONS_LIST}; rm -f ${PARTITIONS_LIST_2}; exit 2" $SIGINT $SIGTERM

### GENERAL PURPOSE FUNCTIONS
#----------------------------------------------------------------------------------------------------------------------------

# Function to call ssft_yesno
# $1 is the title for ssft_yesno
# $2 is the text for ssft_yesno
# returns 0 if yes was selected != 0 otherwise
yesno ()
{
	title="$1"
	msg="$2"
	ssft_yesno "${title}" "${msg}"
	return $?
}

# Function to display an error message
# Clean up the temp files
# and exit the program
# Be carefull of the exit_code used! Use exit_code = 2 if you dont want
# the config to be deleted
error_msg () 
{
	title="ERROR"
	msg="$1"
	msg="${msg} ${ERROR_LOG} might contain more information"
	exit_code="$2"
	ssft_display_error "${title}" "${msg}"
	rm -f ${PARTITIONS_LIST}
	rm -f ${PARTITIONS_LIST_2}
	if [ $exit_code -ne 2 ]; then
		rm -f ${CONFIG_FILE}
	fi
	exit $exit_code
}

display_msg () 
{
	title="$1"
	msg="$2"
	ssft_display_message "${title}" "${msg}"
}

# Function to call ssft_select_multiple
# $1 is the title for ssft_select_multiple
# $2 is the text for ssft_select_multiple
# $@ the items list for ssft_select_multiple
# returns the exit code of ssft_select_multiple
select_more () 
{
	title="$1"
	msg="$2"
	shift 2
	ssft_select_multiple "${title}" "${msg}" $@
	return $?
}

# Function to call ssft_select_single
# $1 is the title for ssft_select_single
# $2 is the text for ssft_select_single
# $@ the items list for ssft_select_single
# returns the exit code of ssft_select_single
select_one () 
{
	title="$1"
	msg="$2"
	shift 2
	ssft_select_single "${title}" "${msg}" $@
	return $?
}

input_pass () 
{
	title="Input Password"
	msg="$1"
	ssft_read_password "${title}" "${msg}"
	return $?
}

input_string () 
{
	title="$1"
	msg="$2"
	ssft_read_string "${title}" "${msg}"
	return $?
}

# Function to check the length of a string
# $1 the string
# $2 string type can be "user" "root" "username" "hostname" "real name"
# $3 var to check if string is a password
length_check () 
{
	string="$1"
	type="$2"
	is_pass="$3"
	num="$4"
	title="$5"
	if [ ${is_pass} = "yes" ]; then
		while [ ${#string} -lt 6 ]; do
			msg="The password is too short!
				It needs to be at least 6 characters long

				Enter a $type password. Will not be echoed"
			input_pass "${msg}"
			if [ $? -eq 0 ]; then
				string="${SSFT_RESULT}"
			else
				error_msg "Can not continue without a password" "1"
			fi
		done
	else
		while [ ${#string} -lt ${num} ]; do
			msg="The ${type} is too short!
				It needs to be at least ${num} characters long

				Enter ${type} again."
			input_string "${title}" "${msg}"
			if [ $? -eq 0 ]; then
				string="${SSFT_RESULT}"
			else
				error_msg "Can not continue without a ${type}" "1"
			fi
		done
	fi
	case "$type" in
		user)	USERPASS="${string}";;
		root)	ROOTPASS="${string}";;
		"hostname")	HOST_NAME="${string}";;
		username)	USERNAME="${string}";;
		*)	REAL_NAME="${string}"
	esac
}

# Function to compare 2 passwords
# $1 password 1
# $2 password 2
# $3 password type "user" or "root"
compare_pass () 
{
	pass1="${1}"
	pass2="${2}"
	type="$3"
	while [ "${pass1}" != "${pass2}" ]
		do
			msg="The passwords do not match
				Enter a ${type} password. Will not be echoed"
			input_pass "${msg}"
			if [ $? -eq 0 ]; then
				pass1="${SSFT_RESULT}"
			else
				error_msg "Can not continue without a ${type} password" "1"
			fi
			# This line will set ${type}PASS assuming that it passes the length test
			length_check "${pass1}" "${type}" "yes"

			input_pass "Please enter the password again. Will not be echoed"

			if [ $? -eq 0 ]; then
				pass2="${SSFT_RESULT}"
			else
				error_msg "Can not continue without a ${type} password" "1"
			fi
		done
}

# Function to check if there is a username USERNAME in the home partition
# chosen by the user. If yes it asks for a new username or removal of the 
# mount point
home_exists () 
{
	# As long as there is a HOME_PARTITION set ask for new name or mount point removal
	while [ -n "${HOME_PARTITION}" ]
		do
			# check_existing_home.sh is the script that does the actuall checking

			/usr/share/cli-installer/scripts/check_existing_home.sh ${HOME_PARTITION} ${USERNAME}
			exit_status=$?
			# No username USERNAME exists on HOME_PARTITION
			if [ $exit_status -eq 0 ]; then
				# Now add home to the MOUNT_POINT_LIST
				mount_point="${HOME_PARTITION}:/home"
				# Need this to make sure that there is no space
				# in front of the first entry
				if [ -n "${MOUNT_POINT_LIST}" ]; then
					MOUNT_POINT_LIST="${MOUNT_POINT_LIST} ${mount_point}"
				else
					MOUNT_POINT_LIST="${mount_point}"
				fi
				break
			elif [ $exit_status -eq 1 ]; then
				error_msg "Could not mount partition. Abording" "1"
			# exit_status of check_existing_home.sh is 2
			else
				#needs some more info
				display_msg "Check home" "Username exists"
				msg="Username already exists on the partition you selected as home
					Do you want to choose a new username or remove the mount point?"
				select_one "Check home" "${msg}" "username mount-point"
				if [ $? -eq 0 ]; then
					if [ "${SSFT_RESULT}" = "username" ]; then
						 input_username
					else
						 HOME_PARTITION=""
					fi
				else
					error_msg "Check home" "Cancelling.." "1"
				fi
			fi
		done
}

# Function to call cfdisk_wrapper.sh to format the hard disk
format_disk () 
{
	title="Format disk"
	msg="Do you want to run cfdisk to format your hard disk?"
	yesno "${title}" "${msg}" 

	if [ $? -eq 0 ]; then
		msg="Please choose a disk to format. Available disks are:"
		partition_list=$(ls -1 /dev/[hs]d?)
		select_more "${title}" "${msg}" $partition_list
		if [ $? -eq 0 ]; then
			for disk in ${SSFT_RESULT} ; do
				/usr/share/cli-installer/scripts/cfdisk_wrapper.sh ${PARTITION_PROG} ${disk}
			done
		fi
	else
		msg="You have chosen not to format your hard disk
			If you have not at least one partition on the disk
			the installer will not be able to complete the installation
			If you do not have a partition please abord now!
		
			Press ctrl+C to abord or ENTER to continue"
		display_msg "${title}" "${msg}"
	fi
}

# Function for timezone selection
set_timezone () 
{
	title="Timezone selection"
	msg="Current timezone is: "$(cat /etc/timezone)"
	
		Do you want to change the timezone?"
	yesno "${title}" "${msg}"

	if [ $? -eq 0 ]; then
		dpkg-reconfigure tzdata
	else
		display_msg "${title}" "Keeping current timezone"
	fi
}

# Function where the user can enter a root partition in case
# the script didnt detect any partitions or the correct partition
custom_root ()
{
	#give the user the option to manually set a root partition in case no partitions were found
	title="Partitioning"
	msg="No partitions were detected by the installer. Do you want to manually set a partion?"
	yesno "$title" "$msg"
	if [ $? -eq 0 ]; then
		msg="Please input a root partition."
		input_string "Root partition" "$msg"
		if [ $? -eq 0 ]; then
			ROOT_PARTITION="${SSFT_RESULT}"
			partition_invalid=true
			while true; do
				partition_valid="true"
				if [ ! -b "${ROOT_PARTITION}" ]; then
					msg="The partition you entered is not a block device. Please enter a root partition."
					# not a block device. not valid partition
					partition_valid="false"
				fi

				# make sure that if device is of the form /dev/[h,s]d? it is actually a partition (number at the end)
				# in case of /dev/mapper/* make no checks as we can not assume anything about the partition name
				if [ "$(echo "${ROOT_PARTITION}" | grep "/dev/[h,s]d.")" != "" ]; then
					if [ "$(echo "${ROOT_PARTITION}" | grep "[h,s]d.[0-9]")" = "" ]; then
						msg="You have not entered a valid partition. Please enter a root partition"
						# turns out partition was not valid
						partition_valid="false"
					fi
				fi
				if [ "$partition_valid" = "true" ]; then
					# all good
					break
				else
					input_string "Root partition" "$msg"
					if [ $? -eq 0 ]; then
						ROOT_PARTITION="${SSFT_RESULT}"
					else
						error_msg "Can not continue without root partition" "1"
					fi
				fi
			done
			# Get just the partition name like sda1, sdb2 etc
			partition=$(echo "${ROOT_PARTITION}" | cut -d "/" -f 3)
			# Get the mapper name in case user choose a mapper
			if [ "$partition" = "mapper" ]; then 
				partition=$(echo "${ROOT_PARTITION}" | cut -d "/" -f 4)
			fi

			# Check if the disk / is on is USB
			if [ -n "$(/usr/share/cli-installer/scripts/disk --usb="${partition%?}")" ]; then 
				IS_DISK_USB="yes"
			fi
		else
			error_msg "Can not continue without root partition" "1"
		fi
	else
		error_msg "Can not continue without partition" "1"
	fi
}


escape_chars ()
{
	echo "$(echo $1 | sed -e 's/!/\\!/g' -e 's/\"/\\"/g' -e 's/\$/\\$/g' -e 's/%/\\%/g' \
			      -e 's/&/\\&/g' -e 's/{/\\{/g' -e 's/(/\\(/g' -e 's/\[/\\[/g' \
			      -e 's/)/\\)/g' -e 's/]/\\]/g' -e 's/=/\\=/g' -e 's/}/\\}/g' \
			      -e 's/?/\\?/g' -e 's/\\/\\/g' -e 's/*/\\*/g' -e 's/+/\\+/g' \
			      -e 's/~/\\~/g' -e "s/'/\\'/g" -e 's/#/\\#/g' -e 's/>/\\>/g' \
			      -e 's/</\\</g' -e 's/`/\\`/g' -e 's/|/\\|/g' -e 's/;/\\;/g' \
			      -e 's/-/\\-/g' -e 's/ /\\ /g' )"
}

# Create a list of available partitions
# and add those into the temp file
/usr/share/cli-installer/scripts/disk -p 2>/dev/null > ${PARTITIONS_LIST}

### FUNCTIONS TO GET THE VALUES FOR THE VARIABLES THAT WILL BE PASSED LATER TO THE CONFIG FILE
#-------------------------------------------------------------------------------------------------------------------------

# Only for root partition
format_root () 
{
	title="Format hard disk"
	msg="Do you want the installer to format your
		root partition?"
	yesno "${title}" "${msg}"

	if [ $? -ne 0 ]; then
		FORMAT_HD="no"
	fi

}

# Only for root partition
select_fs () 
{
	title="Filesystem selection"
	msg="Select a file system for your root partition"
	options="ext3 ext4 ext2 reiserfs"
	SSFT_DEFAULT="ext3"
	select_one "${title}" "${msg}" $options
	if [ $? -eq 0 ]; then
		FILESYSTEM="${SSFT_RESULT}"
	else
		msg="Could not set filesystem. Using ${FILESYSTEM}"
		display_msg "${title}" "${msg}"
	fi

}

choose_root () 
{
	title="Install Partition"
	msg="Choose a partition to install sidux onto.
		Available partitions are:"
	select_one "${title}" "${msg}" $(cat ${PARTITIONS_LIST} | cut -d "," -f1) "custom"

	if [ $? -eq 0 ]; then
		ROOT_PARTITION="${SSFT_RESULT}"
		if [ "${ROOT_PARTITION}" = "custom" ]; then
			 custom_root
		fi
	else
		# give the user the option to manually set partition in case the partition he wants was not detected
		custom_root
	fi

	# Get just the partition name like sda1, sdb2 etc
	partition=$(echo "${ROOT_PARTITION}" | cut -d "/" -f 3)
	# Get the mapper name in case user choose a mapper
	if [ "$partition" = "mapper" ]; then 
		partition=$(echo "${ROOT_PARTITION}" | cut -d "/" -f 4)
	fi

	# Check if the disk / is on is USB
	if [ -n "$(/usr/share/cli-installer/scripts/disk --usb="${partition%?}")" ]; then 
		IS_DISK_USB="yes"
	fi

	#if [ grep "${ROOT_PARTITION}" ${PARTITIONS_LIST} | grep "lvm" ]; then
	#	ROOT_IS_LVM="yes"
	#fi

	cp ${PARTITIONS_LIST} ${PARTITIONS_LIST_2}
	# Find the partition name $partition and remove it from the list
	sed -e "/${partition}/d" ${PARTITIONS_LIST_2} > ${PARTITIONS_LIST}
}

# set mount points for partitions other than root
set_mount_points () 
{
	title="Set mount points"
	msg="Do you want to set mount points for other partitions?
	
		W: The partitions need to be already formated
	
		I: The root partition is already set and you should not
		set it again"
	yesno "${title}" "${msg}"

	# Code to select mount point and partition
	if [ $? -eq 0 ]; then
		## Loop while PARTITIONS_LIST is not empty. If user selects cancel loop will break
		while [ -n "$(cat ${PARTITIONS_LIST})" ]
			do
				msg="Choose a partition to set its mount point.
					Available partitions are:"
				select_one "${title}" "${msg}" $(cat ${PARTITIONS_LIST}  | cut -d "," -f1)
				if [ $? -eq 0 ]; then

					partition="${SSFT_RESULT}"
					# Get just the partition name like sda1, sdb2 etc
					partition_name=$(echo "${partition}" | cut -d "/" -f 3)
					# Get the mapper name in case user choose a mapper
					if [ "$partition_name" = "mapper" ]; then 
						partition_name=$(echo "${partition}" | cut -d "/" -f 4)
					fi

					## SEE IF THIS IS BETTER TO BE CALLED AFTER MOUNT POINT IS SET IN
					## CASE USER CANCELS
					cp ${PARTITIONS_LIST} ${PARTITIONS_LIST_2}
					# Find the partition name $partition_name and remove it from the list
					sed /${partition_name}/d ${PARTITIONS_LIST_2} > ${PARTITIONS_LIST}
					msg="Choose a mount point for ${partition}"
					available_mount_points="home boot opt root tmp usr var"
					select_one "${title}" "${msg}" "${available_mount_points}"
					# If user pressed cancel break out of the loop

					## SEE TO OFFER THE USER THE OPTION TO CANCEL IN CASE HE CHOSE THE WRONG MOUNT POINT
					if [ $? -ne 0 ]; then
						break
					fi
					# Remove the mount point chosen by the user from the list of available mount points
					temp=$( echo "$available_mount_points" | sed "s/$SSFT_RESULT//" )
					available_mount_points="${temp}"
					case $SSFT_RESULT in
						home )
							# If chosen it will be written into MOUNT_POINT_LIST after
							# check_home is called
							HOME_PARTITION="${partition}"
							CHECK_IF_HOME_EXISTS="yes"
							;;
						boot )	
							mount_point="${partition}:/boot"
							# Need this to make sure that there is no space
							# in front of the first entry
							if [ -n "${MOUNT_POINT_LIST}" ]; then
								MOUNT_POINT_LIST="${MOUNT_POINT_LIST} ${mount_point}"
							else
								MOUNT_POINT_LIST="${mount_point}"
							fi
							;;
						opt )	
							mount_point="${partition}:/opt"
							# Need this to make sure that there is no space
							# in front of the first entry
							if [ -n "${MOUNT_POINT_LIST}" ]; then
								MOUNT_POINT_LIST="${MOUNT_POINT_LIST} ${mount_point}"
							else
								MOUNT_POINT_LIST="${mount_point}"
							fi
							;;
						root )	
							mount_point="${partition}:/root"
							# Need this to make sure that there is no space
							# in front of the first entry
							if [ -n "${MOUNT_POINT_LIST}" ]; then
								MOUNT_POINT_LIST="${MOUNT_POINT_LIST} ${mount_point}"
							else
								MOUNT_POINT_LIST="${mount_point}"
							fi
							;;
						tmp )
							mount_point="${partition}:/tmp"
							# Need this to make sure that there is no space
							# in front of the first entry
							if [ -n "${MOUNT_POINT_LIST}" ]; then
								MOUNT_POINT_LIST="${MOUNT_POINT_LIST} ${mount_point}"
							else
								MOUNT_POINT_LIST="${mount_point}"
							fi
							;;
						usr )
							mount_point="${partition}:/usr"
							# Need this to make sure that there is no space
							# in front of the first entry
							if [ -n "${MOUNT_POINT_LIST}" ]; then
								MOUNT_POINT_LIST="${MOUNT_POINT_LIST} ${mount_point}"
							else
								MOUNT_POINT_LIST="${mount_point}"
							fi
							;;
						var )
							mount_point="${partition}:/var"
							# Need this to make sure that there is no space
							# in front of the first entry
							if [ -n "${MOUNT_POINT_LIST}" ]; then
								MOUNT_POINT_LIST="${MOUNT_POINT_LIST} ${mount_point}"
							else
								MOUNT_POINT_LIST="${mount_point}"
							fi
							;;
						* )	
							error_msg "Invalid option" "1"
					esac
				else
					break
				fi
			done
	fi
	display_msg "${title}" "Finished setting mount points"
}

# Asks the user if the installer should not check if there is 
# enough space on the partition
ignore_disk_space () 
{
	title="Check for space"
	msg="Do you want the program NOT to check if there is enough space to install sidux?
		If you don't know what this means please choose 'no'"
	yesno "${title}" "${msg}"
	if [ $? -eq 0 ]; then
		IGNORE_DISK_SPACE="yes"
	fi
}

auto_detect_swap () 
{
	title="Swap autodetect"
	msg="Do you want the installer to autodetect swap?"
	yesno "${title}" "${msg}"
	if [ $? -ne 0 ]; then
		AUTO_SWAP="no"
	fi
}

select_swap () 
{
	if [ -s ${SWAP_PART_LIST} ]; then
		title="Select swap"
		msg="Select the partitions you want to be used as swap by the installer"
		select_more "$title" "$msg" $(cat $SWAP_PART_LIST)
		if [ $? -eq 0 ]; then
			#ssft returns a list with \n in it. remove it and also use sed to remove the space
			#at the end of the line
			SWAP_LIST="$(echo ${SSFT_RESULT} | tr '\n' ' ' | sed 's/ $//g' )"
		fi
	else
		title="Select swap"
		msg="You have no swap partitions. Nothing to select"
		display_msg "$title" "$msg"
	fi
}

input_real_name () 
{
	title="Input Real Name"
	msg="Please enter your real name"

	input_string "${title}" "${msg}"
	if [ $? -eq 0 ]; then
		name="${SSFT_RESULT}"
	fi

	length_check "${name}" "real name" "no" "1" "${title}"
	# Need this as length_check sets REAL_NAME but I still
	# need to check chars
	name="${REAL_NAME}"
	# Make sure that name contains only valid characters
	while [ -n "$( echo "${name}" | grep "[${NAME_NAME_NOT_ALLOWED_CHARS}]" )" ]
		do
			title="Input Real Name"
			msg="Your input contains characters which are not allowed
				Characters which are not allowed are:
		
				${NAME_NAME_NOT_ALLOWED_CHARS}
			
				Please enter again your real name"
			input_string "${title}" "${msg}"
			if [ $? -eq 0 ]; then
				name="${SSFT_RESULT}"
			fi

			length_check "${name}" "real name" "no" "1" "${title}"

			name="${REAL_NAME}" # length_check set the REAL_NAME but i still need to escape chars
		done
	## Used to escape spaces and quotes (')
	REAL_NAME=$( echo "$name" | sed -e "s/ /\\\ /g" -e "s/'/\\\'/g" )
}

input_username () 
{
	title="Input username"
	msg="Please input your username"

	input_string "${title}" "${msg}"
	if [ $? -eq 0 ]; then
		USERNAME="${SSFT_RESULT}"
	fi

	length_check "${USERNAME}" "username" "no" "1" "${title}"

	while [ ! $(echo "${USERNAME}" | grep "^[${USERNAME_ALLOWED_CHARS}]*$") ]
		do
			title="Input username"
			msg="Username contains characters which are not allowed
				Allowed characters are:

				${USERNAME_ALLOWED_CHARS}

				Please enter username"
		
			input_string "${title}" "${msg}"
			if [ $? -eq 0 ]; then
				USERNAME="${SSFT_RESULT}"
			fi

			length_check "${USERNAME}" "username" "no" "1" "${title}"
		done
	if [ "${CHECK_IF_HOME_EXISTS}" != "no" ]; then
		home_exists
	fi
}

input_user_pass ()
{
	input_pass "Enter a user password. Will not be echoed"
	if [ $? -eq 0 ]; then
		USERPASS="${SSFT_RESULT}"
	else
		error_msg "Can not continue without a user password" "1"
	fi

	length_check "${USERPASS}" "user" "yes"

	input_pass "Please enter the password again. Will not be echoed"

	if [ $? -eq 0 ]; then
		pass2="${SSFT_RESULT}"
	else
		error_msg "Can not continue without a user password" "1"
	fi

	compare_pass "${USERPASS}" "${pass2}" "user"
	# If the passwords dont pass the test at the first time then 
	# USERPASS will be set by length_check which is called in compare_pass
	pass1="${USERPASS}"
	pass2=$(escape_chars $pass1)
	## create hashed password and escape $
	USERPASS=$( echo $pass2 | mkpasswd --method=sha-256 -s | sed  's/\$/\\$/g' )

}

input_root_pass ()
{
	input_pass "Enter a root password. Will not be echoed"
	if [ $? -eq 0 ]; then
		ROOTPASS="${SSFT_RESULT}"
	else
		error_msg "Can not continue without a root password" "1"
	fi

	length_check "${ROOTPASS}" "root" "yes"

	input_pass "Please enter the password again. Will not be echoed"

	if [ $? -eq 0 ]; then
		pass2="${SSFT_RESULT}"
	else
		error_msg "Can not continue without a root password" "1"
	fi

	compare_pass "${ROOTPASS}" "${pass2}" "root"
	# If the passwords dont pass the test at the first time then 
	# ROOTPASS will be set by length_check which is called in compare_pass
	pass1="${ROOTPASS}"
	pass2=$(escape_chars $pass1)
	## create hashed password and escape $
	ROOTPASS=$( echo $pass2 | mkpasswd --method=sha-256 -s | sed  's/\$/\\$/g' )
}

input_hostname () 
{
	title="Input hostname"
	msg="Please input hostname"
	SSFT_DEFAULT="${HOST_NAME}"
	input_string "${title}" "${msg}"
	if [ $? -eq 0 ]; then
		HOST_NAME="${SSFT_RESULT}"
	fi

	length_check "${HOST_NAME}" "hostname" "no" "0" "${title}"

	while [ ! $(echo "${HOST_NAME}" | grep "^[${HOSTNAME_ALLOWED_CHARS}][${HOSTNAME_ALLOWED_CHARS}${HOSTNAME_ALLOWED_CHAR_OTHERS}]*$") ]
      		do
			title="Input hostname"
			msg="Username contains characters which are not allowed!
				Allowed characters are:

				${HOSTNAME_ALLOWED_CHARS}
  
				${HOSTNAME_ALLOWED_CHAR_OTHERS}

				W: The hostname must start with a letter!

				Please enter hostname"

			input_string "${title}" "${msg}"
			if [ $? -eq 0 ]; then
				HOST_NAME="${SSFT_RESULT}"
			fi

			length_check "${HOST_NAME}" "hostname" "no" "0" "${title}"
		done
}

# Function so that the user can input some services that should
# start during boot
input_services () 
{
	title="Services"
	msg="Select the services you want to start on boot"
	#services="cups smail ssh samba"
	services="ssh"
	select_more "$title" "$msg" $services
	if [ $? -eq 0 ]; then
		#ssft returns a list with \n in it. remove it and also use sed to remove the space
		#at the end of the line
		SERVICES_LIST="$(echo ${SSFT_RESULT} | tr '\n' ' ' | sed 's/ $//g')"
	fi
}

#set_bootloader () {}

# Ask the user if he wants to create a boot disk
#create_boot_disk ()
#{
#	title="Create boot-disk"
#	msg="Do you want to create a boot-disk?"
#	yesno "${title}" "${msg}"
#	if [ $? -eq 0 ]; then
#		BOOT_DISK="yes"
#	fi
#}

# Ask the user where he wants to place the boot-loader mbr or partition
place_boot_loader ()
{
	title="Bootloader"
	msg="Where do you want the boot-loader to be installed?"
	options="mbr partition"
	SSFT_DEFAULT="${BOOT_WHERE}"
	select_one "${title}" "${msg}" $options
	if [ $? -eq 0 ]; then
		BOOT_WHERE="${SSFT_RESULT}"
	else
		msg="Could not set bootloader. Using ${BOOT_WHERE}"
		display_msg "${title}" "${msg}"
	fi
}

# Function to ask the user if he wants the partitions to be
# auto-mounted on boot
# default is yes
auto_mount_partitions () 
{
	title="Automount"
	msg="Do you want the partitions to be automounted on boot?"
	yesno "${title}" "${msg}"
	if [ $? -ne 0 ]; then
		AUTOMOUNT_BOOT="no"
	fi
}

write_config () 
{
	echo "REGISTERED=' SYSTEM_MODULE HD_MODULE HD_FORMAT HD_FSTYPE HD_CHOICE HD_MAP HD_IGNORECHECK SWAP_MODULE SWAP_AUTODETECT SWAP_CHOICES NAME_MODULE NAME_NAME USER_MODULE USER_NAME USERPASS_MODULE USERPASS_CRYPT ROOTPASS_MODULE ROOTPASS_CRYPT HOST_MODULE HOST_NAME SERVICES_MODULE SERVICES_START BOOT_MODULE BOOT_LOADER BOOT_DISK BOOT_WHERE AUTOLOGIN_MODULE INSTALL_READY HD_AUTO'" > ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "SYSTEM_MODULE='configured'" >> ${CONFIG_FILE}
	echo "HD_MODULE='configured'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# Determines if the HD should be formatted. (mkfs.*)" >> ${CONFIG_FILE}
	echo "# Possible are: yes|no" >> ${CONFIG_FILE}
	echo "# Default value is: yes" >> ${CONFIG_FILE}
	echo "HD_FORMAT='${FORMAT_HD}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# Sets the Filesystem type." >> ${CONFIG_FILE}
	echo "# Possible are: ext3|ext4|ext2|reiserfs" >> ${CONFIG_FILE}
	echo "# Default value is: ext3" >> ${CONFIG_FILE}
	echo "HD_FSTYPE='${FILESYSTEM}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# Here the sidux-System will be installed" >> ${CONFIG_FILE}
	echo "# This value will be checked by function module_hd_check" >> ${CONFIG_FILE}
	echo "HD_CHOICE='${ROOT_PARTITION}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# Here you can give additional mappings. (Experimental) You need to have the partitions formatted yourself and give the correct mappings like: '"'/dev/hda4:/boot /dev/hda5:/var /dev/hda6:/tmp'"'" >> ${CONFIG_FILE}
	echo "HD_MAP='${MOUNT_POINT_LIST}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# If set to yes, the program will NOT check if there is enough space to install sidux on the selected partition(s). Use at your own risk! Useful for example with HD_MAP if you only have a small root partition." >> ${CONFIG_FILE}
	echo "# Possible are: yes|no" >> ${CONFIG_FILE}
	echo "# Default value is: no" >> ${CONFIG_FILE}
	echo "HD_IGNORECHECK='${IGNORE_DISK_SPACE}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "SWAP_MODULE='configured'" >> ${CONFIG_FILE}
	echo "# If set to yes, the swap partitions will be autodetected." >> ${CONFIG_FILE}
	echo "# Possible are: yes|no" >> ${CONFIG_FILE}
	echo "# Default value is: yes" >> ${CONFIG_FILE}
	echo "SWAP_AUTODETECT='${AUTO_SWAP}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# The swap partitions to be used by the installed sidux." >> ${CONFIG_FILE}
	echo "# This value will be checked by function module_swap_check (install-gui)" >> ${CONFIG_FILE}
	echo "SWAP_CHOICES='${SWAP_LIST}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "NAME_MODULE='configured'" >> ${CONFIG_FILE}
	echo "NAME_NAME=${REAL_NAME}" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "USER_MODULE='configured'" >> ${CONFIG_FILE}
	echo "USER_NAME='${USERNAME}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "USERPASS_MODULE='configured'" >> ${CONFIG_FILE}
	echo "USERPASS_CRYPT='${USERPASS}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "ROOTPASS_MODULE='configured'" >> ${CONFIG_FILE}
	echo "ROOTPASS_CRYPT='${ROOTPASS}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "HOST_MODULE='configured'" >> ${CONFIG_FILE}
	echo "HOST_NAME='${HOST_NAME}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "SERVICES_MODULE='configured'" >> ${CONFIG_FILE}
	echo "# Possible services are for now: cups smail ssh samba" >> ${CONFIG_FILE}
	echo "# Default value is: cups" >> ${CONFIG_FILE}
	echo "SERVICES_START='${SERVICES_LIST}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "BOOT_MODULE='configured'" >> ${CONFIG_FILE}
	echo "# Chooses the Boot-Loader" >> ${CONFIG_FILE}
	echo "# Possible are: grub" >> ${CONFIG_FILE}
	echo "# Default value is: grub" >> ${CONFIG_FILE}
	echo "BOOT_LOADER='${BOOT_LOADER}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# If set to 'yes' a boot disk will be created!" >> ${CONFIG_FILE}
	echo "# Possible are: yes|no" >> ${CONFIG_FILE}
	echo "# Default value is: no" >> ${CONFIG_FILE}
	echo "BOOT_DISK='${BOOT_DISK}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "# Where the Boot-Loader will be installed" >> ${CONFIG_FILE}
	echo "# Possible are: mbr|partition" >> ${CONFIG_FILE}
	echo "# Default value is: mbr" >> ${CONFIG_FILE}
	echo "BOOT_WHERE='${BOOT_WHERE}'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}

	echo "AUTOLOGIN_MODULE='configured'" >> ${CONFIG_FILE}
	echo "INSTALL_READY='yes'" >> ${CONFIG_FILE}

	echo >> ${CONFIG_FILE}
	echo >> ${CONFIG_FILE}

	echo "# mount partitions on boot. Default value is: yes" >> ${CONFIG_FILE}
	echo "HD_AUTO='${AUTOMOUNT_BOOT}'" >> ${CONFIG_FILE}
}

### MAIN
#--------------------------------------------------------------------------------------------------------------------------

format_disk

set_timezone

format_root

if [ -z "${ROOT_PARTITION}" ]; then	
	# root partition was not selected manually above
	choose_root
fi

# User must specify the file system of the root partition
select_fs

set_mount_points

ignore_disk_space

auto_detect_swap

if [ "${AUTO_SWAP}" = "no" ]; then
	select_swap
else
	SWAP_CHOICES="$(cut -d" " -f1 /proc/swaps | grep -v "Filename" | tr '\n' ' ' | sed 's/ $//g')"
fi

input_real_name

input_username

input_user_pass

input_root_pass

input_hostname

input_services

#set_bootloader

# Leave disabled for now
#create_boot_disk

# If the disk choosen as root is USB then force partition
if [ "${IS_DISK_USB}" = "no" ]; then
	place_boot_loader
else
	BOOT_WHERE="partition"
fi

auto_mount_partitions

write_config

display_msg "cli-installer" "Finished creating configuration file"


# remove the temporary file with the partition list
rm -f ${PARTITIONS_LIST}
rm -f ${PARTITIONS_LIST_2}

### CODE TO CHECK IF THERE ARE PARTITIONS STILL MOUNTED
/usr/share/cli-installer/scripts/um_all.sh "check"
exit_status=$?
if [ $exit_status -eq 1 ]; then
	title="Unmount Partitions"
	msg="Some partitions are still mounted.
		You need to unmount them for the installer to continue.
		
		Unmount now?"
	yesno "${title}" "${msg}"
	if [ $? -eq 0 ]; then
		/usr/share/cli-installer/scripts/um_all.sh
		exit_status=$?
		if [ $exit_status -eq 1 ]; then
			msg="Could not unmount all partitions

				Abording..
			      
				I: If you choose 'no' the configuration file will stay
				in ${CONFIG_FILE}!"
			error_msg "${msg}" "2"
		else 
			display_msg "${title}" "Partitions unmounted successfully"
		fi
	else
		msg="You chose not to unmount the partitions
			Abording..
      
			I: If you choose 'no' the configuration file will stay
			in ${CONFIG_FILE}!"
		error_msg "${msg}" "2"
	fi
fi

# restore stderr and close file descriptor 3 (only if the interface was dialog)
if [ $SSFT_FRONTEND = "dialog" ]; then

	exec 2>&3 3>&-
fi

### CALL INSTALLER
title="Call Installer"
msg="Finished all checks.
	Do you want to start the installation?
	I: If you choose 'no' the configuration file will stay
	in ${CONFIG_FILE}!"
yesno "${title}" "${msg}"
if [ $? -eq 0 ]; then
	fll-installer || echo "Some error occured. Looking at ${ERROR_LOG} might provide you with answers" && exit 1
fi

# if all goes well remove log
rm -f $ERROR_LOG

exit 0
