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

#OPT: Default package/app's mount namespace to be used, it should be running prior to this script.
NAME_SPACE="init" # This is the default namespace for android system
#NAME_SPACE="com.termux"

#OPT: Shred the old data after copying to encrypted container
SHRED_OLD=true

#OPT: Folders to look for app data and their custom names in the encrypted image
ENC_PATHS="
/data/data/<pkg>                   internal_data
/data/media/0/Android/media/<pkg>  media
/data/media/0/Android/data/<pkg>   external_data
/data/media/0/Android/obb/<pkg>    obb
"

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
    if [[ $file1 -ne 0 || $file2 -ne 0 ]]; then
        echo "ERROR: The mount folder or the container file is not configured / doesn't exist / bad permissions."
        echo "Please configure them by editing the IMG_PATH and MNT_PATH in script."
        exit 1
    fi

    ns_pid=$(sudo pidof "$NAME_SPACE") || { echo "ERROR: Couldn't find pid of $NAME_SPACE, is it running?"; exit 13; }
    ns_pid=$(echo $ns_pid | tr ' ' '\n' | sort -n | head -n 1)
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
    touch $MNT_PATH/.insecure # If this file still present after mount, then mount failed.
    if ! mount | grep /dev/mapper/$MAP_NAME; then
        #sudo mount /dev/mapper/$MAP_NAME $MNT_PATH || {                 # Mount only for termux namespace
        sudo nsenter -t $ns_pid -m mount /dev/mapper/$MAP_NAME $MNT_PATH || {  # Make mount available to all namespaces
            echo "ERROR: Couldn't mount the mapper."; exit 6; }
        if [[ -f $MNT_PATH/insecure ]]; then
            echo "WARNING: Mount success, but only visible to root namespace."
            echo "This happens because of your SU binary or android system, reports are appreciated."
            echo "You can still edit the NAME_SPACE variable in the script to make it visible to your app."
        else
            echo " - Successfully mounted the $MAP_NAME at $MNT_PATH"
        fi
    else
        echo " - Device already mounted at above locations"
    fi
}


# Function that: unmounts, closes the LUKS, removes loopback
function eject_luks(){
    set -o pipefail
    # Unmount all mount points from pid 1 namespace
    while : ; do
        mounts=$(sudo nsenter -t $ns_pid -m mount | grep /dev/mapper/$MAP_NAME ) || break
        mnt=$(awk -F ' on ' '{print $2}' <<< $mounts | awk -F ' type ' '{print $1}' | head -n 1)
        sudo nsenter -t $ns_pid -m umount "$mnt" || { echo "ERROR: Couldn't unmount $mnt , program exiting."; exit 7; }
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

# Shred the old data after copied to encrypted image. 
function shred_old_data(){
    if [[ $(su -c "getenforce") == "Enforcing" ]]; then
        su -c "setenforce 0"
        disabled_selinux=true
    fi
    sudo find $1 -mindepth 1 -exec shred -vun 3 "{}" \; 1>/dev/null
    sudo find $1 -mindepth 1 -exec rmdir -rf "{}" \; 1>/dev/null
    [[ "$disabled_selinux" == "true" ]] && su -c "setenforce 1"
}

# Move an application to the encrypted image
function encrypt_app(){
    PKG=$1


    # Kill if application is running.
    pid=$(sudo pidof $PKG) && {
        sudo kill -s9 $pid
        echo " - Killed the running $PKG"
    }

    # Check if application really exist.
    if ! sudo ls "/data/data/$PKG" &>/dev/null; then
        echo "ERROR: Couldn't find $1 at /data/data/, incorrect pkg name?"
        exit 12;
    fi

    # Copy folder to encrypted image with correct user, permissions & security context.
    function copy_to_crypt(){
        SRC=$1
        DEST=$2
        lsout=$(su -c "ls -lZd $SRC")
        read owner security <<< $(awk '{print $3":"$4" "$5}' <<< $lsout)
        perm=$(sudo stat -c "%a" $SRC)
        sudo mkdir -p "$DEST"
        sudo cp -r $SRC/. "$DEST" || { echo "ERROR: Couldn't copy data to $DEST"; exit 13; }
        sudo chown -R $owner "$DEST"
        sudo chmod -R $perm "$DEST"
        sudo chcon $security "$DEST"
    }


    if [[ $(su -c "getenforce") == "Enforcing" ]]; then
        sudo setenforce 0
        disabled_selinux=true
    fi

    sudo mkdir -p "$MNT_PATH/apps/$PKG"

    # Copy the app data to the encrypted image & shred the old data if enabled.
    for line in $( printf $ENC_PATHS );do
        [[ "$line" == "" ]] && continue
        IFS=";" read path name <<< $( sed "s/pkg/$PKG/g" <<< $line)
        ! sudo ls "$path" &>/dev/null && continue
        copy_to_crypt "$path" "$MNT_PATH/apps/$PKG/$name"
        echo " - Moved to encrypted \`$name\`"
        [[ "$SHRED_OLD" == "true" ]] && {
            shred_old_data "$path"
            echo " - Shredded old \`$path\`"
        }
    done

    [[ "$disabled_selinux" == "true" ]] && su -c "setenforce 1"
    echo -e "\n - Successfully moved $PKG to encrypted image!\n"
    echo "WARNING: There could be more data in other locations, such as Downloads/??? Pictures/??? etc."
    echo -e "You can move them manually to the encrypted image by:\n   $0 enc_extra $PKG <PATH_TO_FOLDER>"
}

# Move an extra folder to the encrypted image
function encrypt_extra_folder(){
    pkg=$1
    folder=$2
    [[ ! -d "$folder" ]] && { echo "ERROR: Couldn't find the folder at $folder"; exit 14; }
    sudo mkdir -p "$MNT_PATH/apps/$pkg/extra"
    sudo cp -r $folder "$MNT_PATH/apps/$pkg/" || { echo "ERROR: Couldn't copy data to $MNT_PATH/apps/$pkg/extra"; exit 15; }
    echo " - Successfully moved $folder to encrypted image!"
    [[ "$SHRED_OLD" == "true" ]] && shred_old_data "$folder"
    echo " - Shredded the old $folder"
    echo "$folder" >> "$MNT_PATH/apps/$pkg/extra/mountpoints.list"
}

# Mount all folders of an application from the encrypted image to the android filesystem
function load_app(){
    PKG=$1
    [[ ! -d "$MNT_PATH/apps/$PKG" ]] && { echo "ERROR: Couldn't find the app at $MNT_PATH/apps/$PKG"; exit 16; }
    while IFS= read -r line; do
        [[ "$line" == "" ]] && continue
        read path name <<< $( sed "s/<pkg>/$PKG/g" <<< $line)
        [[ ! -d "$MNT_PATH/apps/$PKG/$name" ]] && continue
        sudo nsenter -t 1 -m mount --bind "$MNT_PATH/apps/$PKG/$name" "$path" || { echo "ERROR: Couldn't mount $name"; exit 17; }
        echo " - Mounted $name to $path"
    done <<< "$ENC_PATHS"

    # Mount extra folders if available
    if [[ -f "$MNT_PATH/apps/$PKG/extra/mountpoints.list" ]]; then
        while IFS= read -r folder; do
            name=$(basename $folder)
            sudo nsenter -t 1 -m mount --bind "$MNT_PATH/apps/$PKG/extra/$name" "$folder" || { echo "ERROR: Couldn't mount $folder"; exit 18; }
            echo " - Mounted $folder"
        done < "$MNT_PATH/apps/$PKG/extra/mountpoints.list"
    fi
}

help_text="USAGE: $0 [load|eject|enc_app|enc_extra|load_app] [pkg_name|pkg_name folder_path]\n\n\
  load:                       Mount the encrypted image to the android filesystem\n\
  eject:                      Unmount the encrypted image\n\
  enc_app <package>:          Move an app to the encrypted image\n\
  enc_extra <package> <path>: Move an extra folder of app to the image\n\
  load_app <package:          Mount all folders from encrypted image to android fs\n\n\n\
Example: $0 enc_app org.telegram.messenger\n\
         $0 enc_extra org.telegram.messenger /sdcard/Telegram\n\n\
Don't forget to configure the IMG_PATH and MNT_PATH in the script if you haven't already.\n\n"

check_dependency
if [[ "$1" == "load" ]];then
    load_luks
elif [[ "$1" == "eject" ]];then
    eject_luks
elif [[ "$1" == "enc_app" && "$2" != "" ]];then
    encrypt_app $2
elif [[ "$1" == "enc_extra" && "$3" != "" ]];then
    encrypt_extra_folder $2 $3
elif [[ "$1" == "load_app" && "$2" != "" ]];then
    load_app $2
else
    printf "$help_text"
    exit 127
fi
