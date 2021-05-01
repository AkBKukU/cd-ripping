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
# cdrdao abcde bchunk flac lame p7zip cueconvert

# Rip output directory
output="${2:-"$(pwd)"}"

# CDDB server to use for metadata
cddb_server="http://gnudb.gnudb.org/~cddb/cddb.cgi"

    
# CD driver for cdrdao
cd_driver="generic-mmc-raw:0x20000" # Most common driver
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
    cueconvert "$name".toc > "$name".cue # Multiple index compatible but not great with some data CDs
    result=$?
    if [[ "$result" != "0" ]]
    then
        rm "$name".cue
        toc2cue "$name".toc "$name".cue # Part of cdrdao but doesn't keep multiple track index listings
    fi

}

# Get CDDB entry using rip with toc2cddb
cddb_get_toc () {
    return toc2cddb "$name".toc > $logs/cddb.txt
}
# Find and save CDDB entry for disc if available
cddb_get () {
    echo "Fetching CDDB info for [$name] from [$drive]"
    
    # Get disc ID to identify with cddb
    cd-discid $drive > $logs/disc_id.txt

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
    ttitles="$(echo "$cddb" | grep "TTITLE" | sed "s/TTITLE.*=//")"
    
    # Process track titles into array
    SAVEIFS=$IFS   # Save current IFS
    IFS=$'\n\r'      # Change IFS to new line
    ttitle=($ttitles) # split to array $names
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
    
    # Check that ISOs exist
    if [[ "${isos[$i]}" == "*.iso" ]]
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
        
        mkdir "$isoname"
        cd "$isoname"
        7z -y x ../"${isos[$i]}" | tee ../../$logs/7zip.txt
        cd ..
        echo "mv ${isos[$i]} $isoname"
        mv "${isos[$i]}" "$isoname".iso
    done
}

# Track script runtime
time_start=`date +%s`

# Track drives for ejecting
drives_used=()

# Begin ripping loop
while IFS="," read -r drive name fullname <&9
do
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
    
    # Check for multiple sessions
    sessions="$(cdrdao disk-info --device $drive --driver $cd_driver 2>&1 | grep "Sessions" | sed 's/^Sessions.*://g' | xargs)"

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
        rip_bincue
        
        # CDDB information on disc
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
        
        # Convert files
        mkdir content
        cd content
        convert_bincue
        
        # Check for extracted audio and convert it
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
        
        # Get files out of data tracks
        convert_iso
        
        cd ../..
    done

done 9< <(cat $1)

# End ripping session and print durration
time_end=`date +%s`
time_run=$(($time_end-$time_start))
echo "Rip time: $(($time_run / 60)) minutes"
