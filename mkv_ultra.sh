#!/bin/bash

compress_check=true
retain_files=false
ntfy_id="72c947f5-7ab2-4bc2-b536-8576b998c8a4"
compression_lvl="24"
temp_dir="/opt/compress_mkv"
work_dir="."
file_name=""

OPTIONS=$(getopt \
	--options frdt:l:w:x: \
	--longoptions force,retain-files,dry-run,temp-dir:,compression-level:,work-dir:,file: \
	--name "$0" \
	-- "$@"
)

if [[ $? -ne 0 ]]; then
	echo "Usage: $0 [--force] [--retain-files] [--dry-run] [--temp-dir DIRECTORY] [--compression-level LEVEL] [--work-dir WORKING_DIRECTORY] [--file FILE_NAME]"
	exit 1
fi

eval set -- "$OPTIONS"

while true; do
	case "$1" in
		-f|--force)
			compress_check=false
			shift
			;;
		-r|--retain-files)
			retain_files=true
			shift
			;;
		-d|--dry-run)
			dry_run=true
			shift
			;;
		-t|--temp-dir)
			temp_dir="$2"
			if [[ ! -d "$temp_dir" ]]; then
				echo "Creating temp directory: $temp_dir"
				if ! mkdir -p -- "$temp_dir"; then
					echo "Failed to create temp directory: $temp_dir"
					exit 1
				fi
			fi
			shift 2
			;;
		-l|--compression-level)			
			compression_lvl="$2"
			if ! [[ "$compression_lvl" =~ ^[0-9]+$ ]] || (( compression_lvl < 20 || compression_lvl > 30 )); then
				echo "Invalid compression level: $compression_lvl"
				echo "Compression level must be between 20 and 30."
				exit 1
			fi
			shift 2
			;;
		-w|--work-dir)
			work_dir="$2"
			shift 2
			;;
		-x|--file)
			file_name="$2"
			shift 2
			;;
		--)
			shift
			break
			;;
		*)
			echo "Unexpected option: $1"
			exit 1
			;;
	esac
done


get_files() {
	if [[ -n "$file_name" ]]; then
		if [[ ! -f "$work_dir/$file_name" ]]; then
			echo "File not found: $work_dir/$file_name" >&2
			return 1
		fi
		printf '%s\0' "$work_dir/$file_name"
	else
		find "$work_dir" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -print0 | sort -zV
	fi
}

elapsed_time() {
	printf "%02d:%02d:%02d" \
		$((SECONDS/3600)) \
		$(((SECONDS%3600)/60)) \
		$((SECONDS%60))
}

ntfy() {
	curl -s -o /dev/null \
		-d "$1" \
		"ntfy.sh/$ntfy_id"
}

ntfy_data() {
	printf "%s\n%s > %s\n%s" \
		"$basename_file" \
		"$before_size_mb" \
		"$after_size_mb" \
		"$elapsed"
}

cleanup() {
	if [[ "$retain_files" == false ]]; then
		echo "Cleaning up."
		find "$temp_dir" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -delete
		rm -rf "$temp_dir"/attachments*
	else
		echo "Temporary files retained."
	fi
}

cleanup

while IFS= read -r -d '' src_file; do
	SECONDS=0

	compressed=$(ffprobe -v error \
		-show_entries format_tags=comment \
		-of default=noprint_wrappers=1:nokey=1 \
		"$src_file")

	if [[ "$compressed" == "COMPRESSED" && "$compress_check" == true ]]; then
		echo "File already compressed: $src_file"
		continue
	fi

	echo "Processing: $src_file"
	basename_file=$(basename "$src_file")
	ext="${src_file##*.}"
	ext="${ext,,}"

	tmp_file=$(mktemp --suffix=".$ext" "$temp_dir"/ffmpeg.XXXXXX)
	output_file=$(mktemp --suffix=".$ext" "$temp_dir"/output.XXXXXX)
	attach_dir=$(mktemp -d "$temp_dir"/attachments.XXXXXX)

	echo "Copying: $src_file to $tmp_file"
	if ! cp -- "$src_file" "$tmp_file"; then
		echo "Failed to copy $src_file"
		cleanup
		continue
	fi

	before_size=$(stat -c %s "$tmp_file")
	before_size_mb="$((before_size / 1024 / 1024))MB"

	if [[ "$ext" == "mkv" ]]; then
		echo "Checking attachments..."
		attachment_count=$(mkvmerge -J "$tmp_file" | jq '.attachments | length')

		if [[ "$attachment_count" -gt 0 ]]; then
			echo "Extracting $attachment_count attachments..."
			while IFS=: read -r id name; do
				if ! mkvextract -q attachments "$tmp_file" \
					"$id:$attach_dir/$name"
				then
					echo "Failed to extract attachment: $name"
					cleanup
					continue 2
				fi
			done < <(
				mkvmerge -J "$tmp_file" |
					jq -r '.attachments[] | "\(.id):\(.file_name)"'
			)
		else
			echo "No attachments found."
		fi
	else
		attachment_count=0
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
		-metadata comment="COMPRESSED" \
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
		if [[ "$ext" == "mkv" && "$attachment_count" -gt 0 ]]; then
			echo "Restoring attachments..."
			for attachment in "$attach_dir"/*; do
				[[ -f "$attachment" ]] || continue
				if ! mkvpropedit -q "$output_file" \
					--add-attachment "$attachment"
				then
					echo "Failed adding attachment: $attachment"
					cleanup
					exit 1
				fi
			done
		fi

		after_size=$(stat -c %s "$output_file")
		after_size_mb="$((after_size / 1024 / 1024))MB"


		if [[ "$after_size" -ge "$before_size" ]]; then
			elapsed=$(elapsed_time)

			echo "Did not shrink file size: $src_file - $before_size_mb > $after_size_mb"
			ntfy "Compression Failed: $(ntfy_data)"
			cleanup
			echo "----------------------------------------"
			continue
		fi

		if [[ ! "$dry_run" ]]; then
			echo "Copying: $output_file to $src_file"
			if cp -f -- "$output_file" "$src_file"; then
				elapsed=$(elapsed_time)
				echo "File Compressed: $src_file - $before_size_mb > $after_size_mb"
				ntfy "File Compressed: $(ntfy_data)"
			else
				elapsed=$(elapsed_time)
				echo "Failed to replace: $src_file - Original file kept."
				ntfy "Failed to replace: $src_file - Original file kept."
			fi
		else
			elapsed=$(elapsed_time)
			echo "Dry-run Complete: $src_file - $elapsed - $before_size_mb > $after_size_mb"
			ntfy "Dry-run Complete: $(ntfy_data)"
		fi


	else
		echo "Error compressing: $tmp_file - Original file kept."
		ntfy "Compression Failed: $basename_file"
	fi

	cleanup
	echo "----------------------------------------"
done < <(get_files)

cleanup
ntfy "Script Complete"
