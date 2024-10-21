#!/data/data/com.termux/files/usr/bin/bash
# Script to mount & umount encrypted image to android filesystem
#
# You can install the dependencies by:
#  pkg install root-repo # Enables the root-repository
#  pkg install tsu cryptsetup mount-utils util-linux
#
# You have to create an empty container before using this script
#   sudo dd if=/dev/zero of=/path/to/your/file.img bs=1M count=4096
# OR:
#   fallocate -l 4G file.img 
#
# Please configure the IMG_PATH to be the location of the image file you created
# and MNT_PATH to be the mount point of your decrypted partition

#OPT: Path to the existing container file
IMG_PATH="/path/to/your/file.img"

#OPT: Path to the mount point
MNT_PATH="/path/to/your/mountpoint"

#OPT: Default filesystem for the block: ext4, exfat, ext3
# - More filesystems could be supported depending on your system
FORMAT_FS=ext4

#OPT: PBKDF algorithm to be used: pbkdf2, argon2id, argon2i
PBKDF=pbkdf2

#OPT: Type of device metadata: luks1, luks2, plain, loopaes, tcrypt
TYPE=luks2

#OPT: Default name of the LUKS device for the mapper, (can be anything)
MAP_NAME="cry_fs"


# Validate if everything is set correctly
function check_dependency(){
    # Check if all dependencies are installed.
    depends="cryptsetup losetup nsenter mount sudo"
    err_msg="You can install the dependencies by:\n  pkg install root-repo #Enable root repo\n  pkg install tsu cryptsetup mount-utils util-linux"
    for cmd in $depends; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: $cmd not found on path."
            echo -e "$err_msg"
            exit 12
        fi
    done
    
    # Fetch the full path of given files, validate their existence
    IMG_PATH=$(readlink -fve "$IMG_PATH");file1=$?
    MNT_PATH=$(readlink -fve "$MNT_PATH");file2=$?
    if [[ $file1!=0 || $file2!=0 ]]; then
        echo "ERROR: The mount folder or the container file is not configured or doesn't exist."
        echo "Please configure them by editing the IMG_PATH and MNT_PATH in script."
        exit 1
    fi
}

# Function that: Binds loopback & Formats & Encrypts & Mkfs & Mounts if necessary.
function load_luks(){
    # Check if loopback device for container file already exist, create if doesn't.
    lo_res=$(sudo losetup -a | grep "$IMG_PATH")
    if [ $? -eq 0 ]; then
        lo=$(awk -F ':' '{print $1}' <<< $lo_res)
        echo " - Loopback found at: $lo"
    else 
        lo=$(sudo losetup -f --show "$IMG_PATH") || {
            echo "ERROR: Binding loopback failed."; exit 1
        }
        echo " - Loopback created at: $lo"
    fi

    # Check if the lo is already a valid LUKS device, format if it's not.
    if ! sudo cryptsetup isLuks $lo; then
        reset -w &>/dev/null # Some old SU binaries corrupt the width, fix for the next stdin.
        read -p "!) The block doesn't look like it's LUKS formatted, do it now? (y/n) " answer
        [[ $answer != "y" && $answer != "Y" ]] && { echo "Then please format it manually before mounting it."; exit 2; }
        sudo cryptsetup luksFormat --type $TYPE --pbkdf $PBKDF "$lo" || { echo "ERROR: Something went wrong with formatting"; exit 3; }
        echo " - Successfully formatted the block as LUKS device."
        isFormatted=1
    else
        echo " - Validated LUKS device."
    fi

    # Open the luks if not already opened.
    if ! sudo ls "/dev/mapper/$MAP_NAME" &>/dev/null; then
        echo -n " - "
        sudo cryptsetup luksOpen $lo $MAP_NAME || { echo "ERROR: Couldn't open the luks device."; exit 4; }
        echo " - Successfully opened the LUKS device at: /dev/mapper/$MAP_NAME"
    else
        echo " - Found the mapper at /dev/mapper/$MAP_NAME"
    fi
    
    # Build a valid filesystem / partition at the container
    if [[ "$isFormatted" == "1" ]]; then
        sudo mkfs -t $FORMAT_FS /dev/mapper/$MAP_NAME || { echo "ERROR: Couldn't create filesystem."; exit 5; }
        echo " - Created $FORMAT_FS file system."
    fi

    # Mount the mapper device if not already mounted.
    if ! mount | grep /dev/mapper/$MAP_NAME; then
        #sudo mount /dev/mapper/$MAP_NAME $MNT_PATH || {                 # Mount only for termux namespace
        sudo nsenter -t 1 -m mount /dev/mapper/$MAP_NAME $MNT_PATH || {  # Make mount available to all namespaces
            echo "ERROR: Couldn't mount the mapper."; exit 6; }
        echo " - Successfully mounted the $MAP_NAME at $MNT_PATH"
    else
        echo " - Device already mounted at above locations"
    fi
}


# Function that: unmounts, closes the LUKS, removes loopback
function eject_luks(){
    set -o pipefail
    # Unmount all mount points from pid 1 namespace
    while : ; do
        mounts=$(sudo nsenter -t 1 -m mount | grep /dev/mapper/$MAP_NAME ) || break
        mnt=$(awk -F ' on ' '{print $2}' <<< $mounts | awk -F ' type ' '{print $1}' | head -n 1)
        sudo nsenter -t 1 -m umount "$mnt" || { echo "ERROR: Couldn't unmount $mnt , program exiting."; exit 7; }
        echo " - Unmounted: $mnt"
    done

    # Unmount all mount points from termux namespace
    pid=$(sudo pidof com.termux)
    while : ; do
        mounts=$(sudo nsenter -t $pid -m mount | grep /dev/mapper/$MAP_NAME ) || break
        mnt=$(awk -F ' on ' '{print $2}' <<< $mounts | awk -F ' type ' '{print $1}' | head -n 1)
        sudo nsenter -t $pid -m umount "$mnt" || { echo "ERROR: Couldn't unmount $mnt , program exiting."; exit 8; }
        echo " - Unmounted: $mnt"
    done

    # Close the LUKS device
    if sudo ls "/dev/mapper/$MAP_NAME" &>/dev/null; then
        sudo cryptsetup luksClose $MAP_NAME || { echo "ERROR: Couldn't close $MAP_NAME."; exit 9; }
        echo " - Successfully closed $MAP_NAME."
    fi

    # Remove the loopback device
    lo_res=$(sudo losetup -a | grep "$IMG_PATH") || { echo "ERROR: Couldn't find the loopback"; exit 10; }
    lo=$(awk -F ':' '{print $1}' <<< $lo_res)
    sudo losetup -d $lo || { echo "ERROR: Couldn't release the loopback device"; exit 11; }
    echo " - Successfully released loopback device."
}

check_dependency
if [[ "$1" == "load" ]];then
    load_luks
elif [[ "$1" == "eject" ]];then
    eject_luks
else
    echo -e "USAGE:\n  $0 load\n  $0 eject\n\nConfigure the mountpoint and image path in script."
    exit 127
fi
