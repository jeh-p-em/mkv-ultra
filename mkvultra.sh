#!/bin/bash

version="1.0"

ntfy="019fef32-f77b-70cb-8831-fb48caf399e1"
compression_lvl="24"

find /opt/compress_mkv -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -delete
rm -rf /opt/compress_mkv/attachments*

find . -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -print0 | sort -zV |
while IFS= read -r -d '' file; do
        compressed=$(ffprobe -v error \
                -show_entries format_tags=comment \
                -of default=noprint_wrappers=1:nokey=1 \
                "$file")
        if [[ "$compressed" == "COMPRESSED_V$version" ]]; then
                echo "File already compressed: $file"
                continue
        fi
        SECONDS=0
        echo "Processing: $file"
        basename_file=$(basename "$file")
        ext="${file##*.}"
        tmp_file=$(mktemp --suffix=".$ext" /opt/compress_mkv/ffmpeg.XXXXXX)
        output_file=$(mktemp --suffix=".$ext" /opt/compress_mkv/output.XXXXXX)
        attach_dir=$(mktemp -d /opt/compress_mkv/attachments.XXXXXX)
        echo "Copying: $file to $tmp_file"
        if ! cp -- "$file" "$tmp_file"; then
                echo "Failed to copy $file"
                rm -f "$tmp_file"
                rm -rf "$attach_dir"
                continue
        fi
        before_size=$(( $(stat -c %s "$tmp_file") / 1024 / 1024 ))
        before_size_mb="${before_size}MB"
        echo "Checking attachments..."
        attachment_count=$(mkvmerge -J "$tmp_file" | jq '.attachments | length')
        if [[ "$attachment_count" -gt 0 ]]; then
                echo "Extracting $attachment_count attachments..."
                while IFS=: read -r id name; do
                mkvextract -q attachments "$tmp_file" \
                        "$id:$attach_dir/$name"
                done < <(
                        mkvmerge -J "$tmp_file" |
                        jq -r '.attachments[] | "\(.id):\(.file_name)"'
                )
        else
                echo "No attachments found."
        fi
        echo "Encoding: $tmp_file to $output_file"
        if ffmpeg \
                -hide_banner \
                -v error \
                -nostdin \
                -y \
                -probesize 100M \
                -analyzeduration 100M \
                -vaapi_device /dev/dri/renderD128 \
                -i "$tmp_file" \
                -filter_complex "[0:v:0]format=nv12,hwupload[v]" \
                -map "[v]" \
                -map 0:a? \
                -map 0:s? \
                -map 0:v:1? \
                -map_metadata 0 \
                -map_chapters 0 \
                -metadata comment="COMPRESSED_V$version" \
                -c:v:0 hevc_vaapi \
                -rc_mode:v:0 ICQ \
                -qp:v:0 "$compression_lvl" \
                -c:v:1 copy \
                -c:a libopus \
                -b:a 128k \
                -ac 2 \
                -c:s copy \
                "$output_file"
        then
                if [[ "$attachment_count" -gt 0 ]]; then
                        echo "Restoring attachments..."
                        for attachment in "$attach_dir"/*; do
                                [[ -f "$attachment" ]] || continue
                                if ! mkvpropedit -q "$output_file" \
                                        --add-attachment "$attachment"
                                then
                                        echo "Failed adding attachment: $attachment"
                                        rm -f "$output_file"
                                        exit 1
                                fi
                        done
                fi
                after_size=$(( $(stat -c %s "$output_file") / 1024 / 1024 ))
                after_size_mb="${after_size}MB"
                if [[ "$after_size" -gt "$before_size" ]]; then
                        elapsed=$(printf "%02d:%02d:%02d" \
                                $((SECONDS/3600)) \
                                $(((SECONDS%3600)/60)) \
                                $((SECONDS%60)))
                        echo "Did not shrink file size: $file - $before_size > $after_size"
                        curl -s -o /dev/null -d "Compression Failed:
$basename_file
$before_size_mb > $after_size_mb
$elapsed" "ntfy.sh/$ntfy"
                        rm -f -- "$output_file"
                        rm -f -- "$tmp_file"
                        rm -rf -- "$attach_dir"
                        echo "----------------------------------------"
                        continue
                fi
                echo "Moving: $output_file to $file"
                mv -f -- "$output_file" "$file"
                elapsed=$(printf "%02d:%02d:%02d" \
                        $((SECONDS/3600)) \
                        $(((SECONDS%3600)/60)) \
                        $((SECONDS%60)))
                echo "Successfully compressed: $file - $before_size > $after_size"
                curl -s -o /dev/null -d "File Compressed:
$basename_file
$before_size_mb > $after_size_mb
$elapsed" "ntfy.sh/$ntfy"
        else
                echo "Error compressing: $tmp_file. Original kept."
                curl -s -o /dev/null -d "Compression Failed:
$basename_file" "ntfy.sh/$ntfy"
        fi
        echo "Cleaning up"
        rm -f -- "$output_file"
        rm -f -- "$tmp_file"
        rm -rf -- "$attach_dir"
        echo "----------------------------------------"
done
sleep 10
curl -s -o /dev/null -d "Script Complete"  "ntfy.sh/$ntfy"
find /opt/compress_mkv -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -delete
rm -rf /opt/compress_mkv/attachments*
