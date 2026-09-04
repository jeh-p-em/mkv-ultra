#!/bin/bash

compress_check=true
ntfy_id="72c947f5-7ab2-4bc2-b536-8576b998c8a4"
compression_lvl="24"
base_temp_dir="~/mkv-ultra"
temp_dir=""
source_dir="."
file_name=""
no_replace=false
keep_temp_files=false

usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -h, --help
        Show this help message and exit.

  -f, --force
        Compress files even if they are already marked as compressed.

  -k, --keep-temp-files
        Keep temporary files after processing.

  -n, --no-replace
        Runs through the whole compression process and reports 
        the amount of data that was saved and the time it took.
        The original source files are not replaced with the commpressed versions.

  -y, --ntfy-id
        Specify your own ntfy ID string to send updates to.
        Default: $ntfy_id

  -t, --temp-dir DIRECTORY
        Directory to use for temporary files.
        Default: $base_temp_dir

  -l, --compression-level LEVEL
        HEVC VAAPI compression level, from 20 to 30.
        The higher the number, the more compression occurs.
        Default: $compression_lvl

  -s, --source-dir DIRECTORY
        Directory to search for media files.
        Default: $source_dir

  -x, --file-name FILE
        Process only the specified file.

EOF
}

OPTIONS=$(getopt \
	--options hfkny:t:l:s:x: \
	--longoptions help,force,keep-temp-files,no-replace,ntfy-id:,temp-dir:,compression-level:,source-dir:,file-name: \
	--name "$0" \
	-- "$@"
)

if [[ $? -ne 0 ]]; then
	usage
	exit 1
fi

eval set -- "$OPTIONS"

while true; do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		-f|--force)
			compress_check=false
			shift
			;;
		-k|--keep-temp-files)
			keep_temp_files=true
			shift
			;;
		-n|--no-replace)
			no_replace=true
			shift
			;;
		-y|--ntfy-id)
			ntfy_id="$2"
			shift 2
			;;
		-t|--temp-dir)
			base_temp_dir="$2"
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
		-s|--source-dir)
			source_dir="$2"
			shift 2
			;;
		-x|--file-name)
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
		found_file=$(find "$source_dir" -type f -name "*$file_name" -print -quit)
		if [[ -z "$found_file" ]]; then
			echo "File not found: $file_name" >&2
			return 1
		fi
		printf '%s\0' "$found_file"
	else
		find "$source_dir" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \) -print0 | sort -zV
	fi
}

elapsed_time() {
	printf "%02d:%02d:%02d" \
		$((SECONDS/3600)) \
		$(((SECONDS%3600)/60)) \
		$((SECONDS%60))
}

ntfy() {
	echo "$1"
	curl -s -o /dev/null -d "$1" "ntfy.sh/$ntfy_id"
}

ntfy_data() {
	printf "%s\n%s > %s\n%s" \
		"$basename_file" \
		"$before_size_mb" \
		"$after_size_mb" \
		"$elapsed"
}

cleanup() {
	if [[ "$keep_temp_files" == false ]]; then
		echo "Deleting temporary files."
    rm -rf -- "$temp_dir"/*
	fi
}


if [[ ! -d "$base_temp_dir" ]]; then
	echo "Creating directory: $base_temp_dir"
	if ! mkdir -p -- "$base_temp_dir"; then
		echo "Failed to create directory: $base_temp_dir"
		exit 1
	fi
fi

temp_dir=$(mktemp -d "$base_temp_dir"/mkv_ultra.XXXXXX) || {
	echo "Failed to create temporary directory"
	exit 1
}


while IFS= read -r -d '' source_file; do
	SECONDS=0

	compressed=$(ffprobe -v error \
		-show_entries format_tags=comment \
		-of default=noprint_wrappers=1:nokey=1 \
		"$source_file")

	if [[ "$compressed" == "COMPRESSED" && "$compress_check" == true ]]; then
		echo "File already compressed: $source_file"
		continue
	fi

	echo "Processing: $source_file"
	basename_file=$(basename "$source_file")
	final_file="${source_file%.*}.mkv"
	ext="${source_file##*.}"
	ext="${ext,,}"

	temp_file=$(mktemp --suffix=".$ext" "$temp_dir"/ffmpeg.XXXXXX)
	output_file=$(mktemp --suffix=".mkv" "$temp_dir"/output.XXXXXX)
	attach_dir=$(mktemp -d "$temp_dir"/attachments.XXXXXX)

	echo "Copying: $source_file to $temp_file"
	if ! cp -- "$source_file" "$temp_file"; then
		echo "Failed to copy $source_file"
		cleanup
		continue
	fi

	before_size=$(stat -c %s "$temp_file")
	before_size_mb="$((before_size / 1024 / 1024))MB"

	if [[ "$ext" == "mkv" ]]; then
		echo "Checking attachments..."
		attachment_count=$(mkvmerge -J "$temp_file" | jq '.attachments | length')

		if [[ "$attachment_count" -gt 0 ]]; then
			echo "Extracting $attachment_count attachments..."
			while IFS=: read -r id name; do
				if ! mkvextract -q attachments "$temp_file" \
					"$id:$attach_dir/$name"
				then
					echo "Failed to extract attachment: $name"
					cleanup
					continue 2
				fi
			done < <(
				mkvmerge -J "$temp_file" |
					jq -r '.attachments[] | "\(.id):\(.file_name)"'
			)
		else
			echo "No attachments found."
		fi
	else
		attachment_count=0
	fi

	source_pix_fmt=$(ffprobe -v error \
		-select_streams v:0 \
		-show_entries stream=pix_fmt \
		-of default=noprint_wrappers=1:nokey=1 \
		"$temp_file")

	case "$source_pix_fmt" in
		yuv420p)
			format="nv12"
			profile="main"
			;;
		yuv420p10le)
			format="p010le"
			profile="main10"
			;;
		yuv422p10le)
			format="yuv422p10le"
			profile="rext"
			;;
		yuv444p10le)
			format="yuv444p10le"
			profile="rext"
			;;
		*)
			echo "Unsupported pixel format: $source_pix_fmt"
			cleanup
			continue
			;;
	esac

	echo "Encoding: $temp_file to $output_file"
	if ffmpeg \
		-hide_banner \
		-v error \
		-nostdin \
		-y \
		-probesize 100M \
		-analyzeduration 100M \
		-vaapi_device /dev/dri/renderD128 \
		-i "$temp_file" \
		-filter_complex "[0:v:0]hqdn3d=0.8:0.8:3:3,format=$format,hwupload[v]" \
		-map "[v]" \
		-profile:v:0 "$profile" \
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
		-c:a copy \
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
			ntfy "Compression Failed: $(ntfy_data)"
			cleanup
			echo "----------------------------------------"
			continue
		fi

		if [[ "$no_replace" == false ]]; then
			echo "Copying: $output_file to $source_file"
			if cp -f -- "$output_file" "$source_file"; then
				mv -- "$source_file" "$final_file"
				elapsed=$(elapsed_time)
				ntfy "File Compressed: $(ntfy_data)"
			else
				elapsed=$(elapsed_time)
				ntfy "Failed to replace: $source_file - Original file kept."
			fi
		else
			elapsed=$(elapsed_time)
			ntfy "Test Run Complete: $(ntfy_data)"
		fi

	else
		ntfy "Compression Failed: $basename_file"
	fi

	cleanup
	echo "----------------------------------------"
done < <(get_files)


if [[ "$keep_temp_files" == false ]]; then
	rm -rf -- "$temp_dir"
fi

sleep 1
ntfy "Script Complete"
