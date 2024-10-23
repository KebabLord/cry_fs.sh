## CryptSetup wrapper script for Android 
This script provides you an additional encryption layer on android by creating an encrypted container which you can put your files or, even android applications on it 
```bash
~ $ ./cry.sh
USAGE: ./cry.sh [load|eject|enc_app|enc_extra|load_app] [pkg_name|pkg_name folder_path]

  load:                       Mount the encrypted image to the android filesystem
  eject:                      Unmount the encrypted image
  enc_app <package>:          Move an app to the encrypted image
  enc_extra <package> <path>: Move an extra folder of app to the image
  load_app <package:          Mount all folders from encrypted image to android fs


Example: ./cry.sh load
         ./cry.sh enc_app org.telegram.messenger

Dont forget to configure the IMG_PATH and MNT_PATH in the script if you haven't already.
```
![misato](https://i.imgur.com/BuFyFXl.png)
