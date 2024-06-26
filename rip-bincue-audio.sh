#!/bin/bash
#
#
# Bulk CD Ripping Automation
#     by Shelby Jueden / Tech Tangents
#
# This script is designed to be used with a single or multiple CD-ROM 
# drives for ripping many discs in a single session with minimal user 
# interaction. The script takes a single parameter that is a CSV file
# containing a drive, filename, and text description of each disc to
# be ripped. The following is an example of the file format:
# 
# /dev/sr0,doomii,Doom II
# /dev/sr1,rctycoon-ll,Roller Coaster Tycoon Loopy Landscapes
# /dev/sr0,hotwheelsvx,Hot Wheels Velocity X
# /dev/sr1,legorace,LEGO Racer
# 
# When a line containing a previously ripped drive is encountered, all
# drives that have been ripped will be ejected for replacement discs to 
# be put in.
# 
# Discs are ripped as BIN/CUE primarilly. This is the prefered file
# format for CDs over ISOs because it preserves audio data. BIN/CUEs
# are then converted into an ISO and WAV files if there is audio. WAV
# files are converted to FLAC and MP3 and then discarded.
# 
# All discs are checked against a CDDB source for metadata. Audio CDs
# will likely have data available and when FLAC and MP3 files are created
# the CDDB info will be used for filenames and added as metadata. If no
# CDDB entry is found and there are audio tracks, the description will be
# use as an album name.
# 
# Required programs to use this script:
# cdrdao abcde bchunk flac lame p7zip cuetools gddrescue libcdio-utils

# Rip output directory
output="${2:-"$(pwd)"}"

# CDDB server to use for metadata
cddb_server="http://gnudb.gnudb.org/~cddb/cddb.cgi"

    
# CD driver for cdrdao
cd_driver="generic-mmc-raw:0x20000" # Most common driver
#cd_driver="generic-mmc-raw" # Most common driver Byte Swapped
#cd_driver="plextor" # Useful for older drives

# String sanatization for path names
clean () {
    echo "$1" | sed -e 's/[\/\\\&:\"<>\?\*|]/-/g'
}

# Rip BIN/CUE of current disc
rip_bincue () {
    echo "Ripping [$name] from [$drive]"

    # Rip BIN
    cdrdao read-cd --read-raw --datafile "$name".bin --device "$drive" --session $session --driver $cd_driver "$name".toc 2>&1 | tee -a $logs/rip-log.txt

    # Generate CUE from TOC
    toc2cue "$name".toc "$name".cue  2>&1 | tee -a $logs/toc2cue.txt # Part of cdrdao but doesn't keep multiple track index listings
}

# Get CDDB entry using rip with toc2cddb
cddb_get_toc () {
    return toc2cddb "$name".toc > $logs/cddb.txt
}
# Find and save CDDB entry for disc if available
cddb_get () {
    echo "Fetching CDDB info for [$name] from [$drive]"
    
    # Get disc ID to identify with cddb
    if [[ ! -e $logs/disc_id.txt ]]
    then
	cd-discid $drive > $logs/disc_id.txt
    fi

    # Run query to get possible genres
    query="$(cddb-tool query "$cddb_server" 6 $(whoami) $(hostname) `cat $logs/disc_id.txt`)"
    
    # If disc not in CDDB exit and return error code
    if [[ "$query" == *"202"* ]]; then
        return 202
    fi

    # Use first available genere if multiple are found
    if [[ "$query" == *"Found"* ]]; then
        genre="$(echo "$query" | grep "/" | head -n 1 | awk '{print $1}')"
    else
        genre="$(echo "$query" | awk '{print $2}')"
    fi
    
    # Get the cddb entry
    cddb-tool read $cddb_server 6 $(whoami) $(hostname) $genre `cat logs/disc_id.txt` > $logs/cddb.txt
}

# Parse CDDB info into global variables to use when encoding FLAC and MP3
cddb_parse () {
	echo "Parsing CDDB info for [$name] from [$drive]"

	# Load cddb entry
	cddb="$(cat $logs/cddb.txt)"

	# Parse out album information
	dyear="$(echo "$cddb" | grep "DYEAR" | sed "s/DYEAR=//" | sed "s/\r//" | xargs)"
	dgenre="$(echo "$cddb" | grep "DGENRE" | sed "s/DGENRE=//" | sed "s/\r//" | xargs)"
	dalbum="$(echo "$cddb" | grep "DTITLE" | sed "s/DTITLE=//" | sed "s/\r//" | sed "s|.* / ||" | xargs)"
	dartist="$(echo "$cddb" | grep "DTITLE" | sed "s/DTITLE=//" | sed "s/\r//" | sed "s| / .*||" | xargs)"
	ttitles_split="$(echo "$cddb" | grep "TTITLE" )"


	# Process track titles into array
	SAVEIFS=$IFS   # Save current IFS
	IFS=$'\n\r'      # Change IFS to new line
	ttitle_split=($ttitles_split) # split to array $names
	ttitle=()

	# Unsplit titles
	lasttitle=""
	echo "$dyear - $album : by $dartist"
	for (( i=0; i<${#ttitle_split[@]}; i++ ))
	do
		# Check if previous title matches current
		if [[ "$lasttitle" == "$(echo "${ttitle_split[$i]}" | sed "s/=.*//")" ]]
		then
			echo "Appending [$lasttitle]"
			ttitle[-1]="${ttitle[-1]}$(echo "${ttitle_split[$i]}" | sed "s/TTITLE.*=//")"
		else
			lasttitle="$(echo "${ttitle_split[$i]}" | sed "s/=.*//")"
			ttitle+=("$(echo "${ttitle_split[$i]}" | sed "s/TTITLE.*=//")")
			echo "Changing title [$lasttitle]"
		fi
	done


    IFS=$SAVEIFS   # Restore IFS
}

# Extract ISO and WAVs from BIN/CUE file
convert_bincue () {
    #bchunk -sw ../"$name".bin ../"$name".cue track # Use -s to swap audio byte order
    bchunk -w ../"$name".bin ../"$name".cue track
}

# Convert WAVs to FLAC and MP3 without CDDB data
convert_audio () {
    # Create folders
    mkdir -p "flac/$(clean "$description")" "mp3/$(clean "$description")"

    # If pregap track exists convert it first
    if [[ -e "pregap.wav" ]]
    then
        # Set track number to 00
        num=00

        # Rip FLAC
        flac pregap.wav \
            --tag=ALBUM="$description" \
            --tag=TITLE="Pre-gap" \
            --tag=TRACKNUMBER="0"
        mv "pregap.wav.flac" "flac/$(clean "$description")/$num - Pre-gap.flac"

        # Rip MP3
        lame -b 320 pregap.wav \
            --tl "$description" \
            --tt "Pre-gap" \
            --tn "0"
        mv "pregap.wav.mp3" "mp3/$(clean "$description")/$num - Pre-gap.mp3"

        rm pregap.wav
    fi

    # Convert all WAVs to FLAC and MP3 using CSV info
    wavs=(*.wav)
    for (( i=0; i<${#wavs[@]}; i++ ))
    do
        # Get zero padded track number
        num="$(printf %02d $(expr $i + 1))"
        
        # Rip FLAC
        flac "${wavs[$i]}" \
            --tag=ALBUM="$description" \
            --tag=TRACKNUMBER="$(expr $i + 1)"
        mv "${wavs[$i]%.wav}.flac" "flac/$(clean "$description")/$num - ${wavs[$i]%.wav}.flac"
            
        # Rip MP3
        lame -b 320 "${wavs[$i]}" \
            --tl "$description" \
            --tn "$(expr $i + 1)"
        mv "${wavs[$i]%.wav}.mp3" "mp3/$(clean "$description")/$num - ${wavs[$i]%.wav}.mp3"
    done

}

# Convert WAVs to FLAC and MP3 using CDDB data for metadata
convert_audio_cddb () {
    # Create folders
    mkdir -p "flac/$(clean "$dartist")/$dyear - $(clean "$dalbum")" "mp3/$(clean "$dartist")/$dyear - $(clean "$dalbum")"
    
    # Remove data tracks from CDDB titles
    isos=(*.iso)
    local tempttitles=()
    for (( i=0; i<${#isos[@]}; i++ ))
    do       
        # Match ISO track name to CDDB entry
        datatrack="$(echo "${isos[$i]}" | sed 's/^track//g' | sed 's/^0*//g' | sed 's/\.iso//g' | xargs)"
        datatrack="$(expr $datatrack - 1)"
        echo "Data track [$datatrack] found with CDDB title \"${ttitle[$datatrack]}\" will be removed."
        
        # Remove the data track title
        for (( i=0; i<${#ttitle[@]}; i++ ))
        do
            if [[ "$i" != "$datatrack" ]]
            then
                tempttitles+=("${ttitle[$i]}")
            fi
        done
        ttitle=()
        ttitle=("${tempttitles[@]}")
    done


    # If pregap track exists convert it first
    if [[ -e "pregap.wav" ]]
    then
        # Set track number to 00
        num=00

        # Rip FLAC
        flac "pregap.wav" \
            --tag=ALBUM="$dalbum" \
            --tag=ARTIST="$dartist" \
            --tag=TITLE="Pre-gap" \
            --tag=TRACKNUMBER="0" \
            --tag=DATE="$dyear" \
            --tag=GENRE="$dgenre"
        mv "pregap.flac" "flac/$(clean "$dartist")/$dyear - $(clean "$dalbum")/$num - Pre-gap.flac"

        # Rip MP3
        lame -b 320 "pregap.wav" \
            --tl "$dalbum" \
            --ta "$dartist" \
            --tt "Pre-gap" \
            --tn "0" \
            --ty "$dyear" \
            --tg "$dgenre"
        mv "pregap.mp3" "mp3/$(clean "$dartist")/$dyear - $(clean "$dalbum")/$num - Pre-gap.mp3"

        rm pregap.wav
    fi
    
    # Convert all WAVs to FLAC and MP3 with cddb info
    wavs=(*.wav)
    for (( i=0; i<${#wavs[@]}; i++ ))
    do
        # Get zero padded track number
        num="$(printf %02d $(expr $i + 1))"
        
        # Rip FLAC
        flac "${wavs[$i]}" \
            --tag=ALBUM="$dalbum" \
            --tag=ARTIST="$dartist" \
            --tag=TITLE="${ttitle[$i]}" \
            --tag=TRACKNUMBER="$(expr $i + 1)" \
            --tag=DATE="$dyear" \
            --tag=GENRE="$dgenre" 
        mv "${wavs[$i]%.wav}.flac" "flac/$(clean "$dartist")/$dyear - $(clean "$dalbum")/$num - $(clean "${ttitle[$i]}").flac"
            
        # Rip MP3
        lame -b 320 "${wavs[$i]}" \
            --tl "$dalbum" \
            --ta "$dartist" \
            --tt "${ttitle[$i]}" \
            --tn "$(expr $i + 1)" \
            --ty "$dyear" \
            --tg "$dgenre"
        mv "${wavs[$i]%.wav}.mp3" "mp3/$(clean "$dartist")/$dyear - $(clean "$dalbum")/$num - $(clean "${ttitle[$i]}").mp3"
    done
}

# Extract contents of ISO files to directory
convert_iso () {
    # Loop through all ISOs extracted
    isos=(*.iso)
    
    echo "isos: $isos"
    #echo "{isos[i]}: ${isos[$i]}"
    isotest="$(echo $isos | grep \*)"
    
    # Check that ISOs exist
    if [[ "$isotest" != "" ]]
    then 
        return 0
    fi
    
    # Extract ISOs
    for (( i=0; i<${#isos[@]}; i++ ))
    do
        # Get ISO volume name
        isoname="$(isoinfo -i "${isos[$i]}" -d | grep "Volume id" | sed 's/^Volume id.*://g' | xargs)"
        
        # Check for blank Valume id
        if [[ "$isoname" == "" ]]
        then
            isoname="ISO-$i"
        fi
        
        echo "mv ${isos[$i]} $isoname.iso"
        mv "${isos[$i]}" "$isoname".iso
        mkdir "$isoname"
        cd "$isoname"
        (timeout 20m 7z -y x ../"$isoname".iso | tee ../../$logs/7zip.txt &)
        cd ..
    done
}

# Check for Pre-gap track and rip it if exists
pregap () {
    # Get the first track information on the disc
    track="$(cdparanoia -Q 2>&1 | tee | grep " 1. ")"

    # Pregap assumption point
    # NOTE: This value is the number of frames Track 1 is offset from the start of the disc.
    # There are 75 frames per second, this is a 5 second limit.
    pregap_max="375"

    # If Track 1 is beyond the pregap limit, rip it to a wav
    if [[ "$(echo "$track" | awk '{print $4}')" > "$pregap_max" ]]
    then
        echo "$(echo "$track" | awk '{print $4}') > $pregap_max"
        cdparanoia -t -"$(echo "$track" | awk '{print $4}')" "1[0.0]-1$(echo "$track" | awk '{print $5}')" pregap.wav
    fi
}

# Track script runtime
time_start=`date +%s`

# Track drives for ejecting
drives_used=()

# Begin ripping loop
while IFS="," read -r drive name fullname <&9
do
    if [[ "$drive" == "" ]]
    then
        echo "Empty line, ending"
        exit 0
    fi

    # Trim input
    drive="$(echo "$drive" | xargs)"
    name="$(echo "$name" | xargs)"
    fullname="$(echo "$fullname" | xargs)"
    
    # Default log directory
    logs="logs"
    
    # Check if drive(s) needs new disc
    if [[ "${drives_used[@]}" =~ "$drive" ]]; then
        echo "---Old disc in [$drive]---"
        for i in "${drives_used[@]}"
        do
            echo "Ejecting: $i"
            eject "$i"
        done
        drives_used=()
        echo ""
        echo ""
        echo "Next expected disc[$name]: $fullname"
        echo ""
        echo ""
        read -p "Replace disc(s) and press enter to continue..."
    fi
    drives_used+=("$drive")

    # Prepare new directory for disc
    cd "$output"
    mkdir "$name"
    cd "$name"
    mkdir logs
    echo "$fullname" > description.txt
    
    # Log disc information
    cd-info $drive | tee -a $logs/cd-info.log
    
    # Check if DVD
    dvd="$(cat $logs/cd-info.log | grep "Disc mode is listed as: DVD-ROM")"
    if [[ "$dvd" != "" ]]
    then
        echo ""
        echo "This disc is a DVD, an ISO will be created with ddrescue" | tee -a $logs/dvd.log
        echo ""
        mkdir content
        cd content
        blkid $drive | tee -a ../$logs/dvd-blkid.log
        #dd if=$drive of=$name.iso  | tee -a $logs/dvd.log # Plain dd option
        ddrescue -b 2048 -n -v $drive $name.iso mapfile  | tee -a ../$logs/dvd-ddrescue.log
        ddrescue -b 2048 -d -r 3 -v $drive $name.iso mapfile  | tee -a ../$logs/dvd-ddrescue.log
        ddrescue -b 2048 -d -R -r 3 -v $drive $name.iso mapfile  | tee -a ../$logs/dvd-ddrescue.log
    fi
    
    
    # Check for multiple sessions
    if [[ "$dvd" == "" ]]; then
        sessions="$(cdrdao disk-info --device $drive --driver $cd_driver 2>&1 | grep "Sessions" | sed 's/^Sessions.*://g' | xargs)"
        echo "Sessions found: $sessions"
    fi
        
    if [[ "$sessions" == "" ]]
    then
        echo "WARNING: Your CD drive may not support multiple sessions."
        echo "         Defaulting to single session."
        sessions=1
    fi
    session="$sessions"
    
    # Rip all sessions
    for (( session=sessions; session>0; session-- ))
    do
        echo "looping sessions"
        if [[ "$sessions" != "1" ]] ; then
            echo "Ripping session $session/$sessions"
            mkdir "$name-$session"
            cd "$name-$session"
            mkdir $logs
        fi
    
        # Rip BIN/CUE
        if [[ "$dvd" == "" ]]; then
           rip_bincue
           echo "hi"
        fi
        
        
        # CDDB information on disc
        if [[ "$dvd" == "" ]]; then
            cddb_get # Custom CDDB retreival
            #cddb_get_toc # Cdrdao CDDB retreival
            found=$?
            if [[ "$found" == "202" ]] ; then
                echo "No CDDB entry found, attempting toc2cddb"
                cddb_get_toc # Cdrdao CDDB retreival
                result=$?
                if [[ "$result" == "0" ]]
                then
                    cddb_parse 
                    found="210"
                fi
            else
                cddb_parse
            fi
        fi
        
        # Convert files
        if [[ "$dvd" == "" ]]; then
            mkdir content
            cd content
            convert_bincue
            pregap # Works off of disc, not BIN/CUE
        fi
        
        # Check for extracted audio and convert it
        if [[ "$dvd" == "" ]]; then
            count=`ls -1 *.wav 2>/dev/null | wc -l`
            if [ $count != 0 ]
            then
                if [[ "$found" == "202" ]] ; then
                    convert_audio
                else
                    convert_audio_cddb
                fi
                
                # Remove converted WAVs
                rm *.wav
            fi
        fi
        
        
        # Get files out of data tracks
        convert_iso

        # Next Session
        cd ..

    done
    # Next Disc
    cd ..

done 9< <(cat $1)

# End ripping session and print durration
time_end=`date +%s`
time_run=$(($time_end-$time_start))
echo "Rip time: $(($time_run / 60)) minutes"
