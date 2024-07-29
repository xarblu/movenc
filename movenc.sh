#!/usr/bin/env bash

# Usage:
#   movenc.sh [<args>...] <infile> [<outfile>]
#
# Dependencies:
# ffmpeg with codecs you want to use (all currently supported libx264, libx265, libfdk_aac)
# jq
# mkvpropedit (mkvtoolnix)
# mediainfo

set -o errexit -o nounset

# helper
die() {
    echo "[ERROR] ${FUNCNAME[0]}: ${*}" 1>&2
    echo "Stacktrace:"
    local stackheight=${#FUNCNAME[@]}
    local stackcur=0
    
    while (( stackcur < stackheight )); do
        echo -e "  ${FUNCNAME[${stackcur}]} at line ${BASH_LINENO[${stackcur}]} in ${BASH_SOURCE[${stackcur}]}"
        stackcur=$(( stackcur + 1 ))
    done

    exit 1
}

info() {
    echo "[INFO] ${*}" 1>&2
}

# pass in ${@} args to parse
parse_args() {
    local args=()
    local arg
    for arg in "${@}"; do
        case "${arg}" in
            --streams=*)
                STREAMS=( ${arg#*=} )
                ;;
            --alangs=*)
                ALANGS=( ${arg#*=} )
                ;;
            --crop=*)
                CROP="${arg#*=}"
                ;;
            --tune=*)
                TUNE="${arg#*=}"
                ;;
            --vcodec=*)
                VCODEC="${arg#*=}"
                ;;
            --acodec=*)
                ACODEC="${arg#*=}"
                ;;
            --pretend)
                PRETEND="true"
                ;;
            --*)
                die "Unknown flag: ${arg}"
                ;;
            *)
                # positional arg
                args+=( "${arg}" )
                ;;
        esac
        shift
    done

    # after parsing --flags we expect either 1 - 2 args
    if (( ${#args[@]} < 1 )); then
        die "Too few positional args. Expected at least 1."
    elif (( ${#args[@]} > 2 )); then
        die "Too many positional args. Expected at most 2."
    elif (( ${#args[@]} == 1 )); then
        # avoid unbound variable
        args[1]=""
    fi

    # arg 1 is input file
    if [[ -f "${args[0]}" ]]; then
        INFILE="${args[0]}"
    else
        die "INFILE \"${args[0]}\" doesn't exist"
    fi

    # arg 2 is output file (defaults to ${INFILE%.*}+done.mkv)
    # if it's a dir use 2/1
    if [[ -z "${args[1]}" ]]; then
        OUTFILE="${INFILE%.*}+done.mkv"
    elif [[ -d "${args[1]}" ]]; then
        OUTFILE="${args[1]%/}/${INFILE%.*}.mkv"
    elif [[ ! -f "${args[1]}" ]]; then
        OUTFILE="${args[1]}"
    else
        die "OUTFILE \"${args[1]}\" exists"
    fi
}

# initialise the MEDIA_JSON metadata
init_media_json() {
    if [[ -n "${MEDIA_JSON}" ]]; then
        info "Overwriting previously set MEDIA_JSON"
    fi
    if [[ -z "${INFILE}" ]]; then
        die "INFILE is empty"
    fi
    MEDIA_JSON="$(mediainfo --output=JSON "${INFILE}" | tr -d '\n')"
}

# die if $1 is empty or invalid
assert_json() {
    if [[ -z "${1}" ]]; then
        die "MEDIA_JSON is unset"
    fi
    if ! jq <<<"${1}" &>/dev/null; then
        die "MEDIA_JSON is not valid json. Got: ${MEDIA_JSON}"
    fi
}

assert_media_json() {
    assert_json "${MEDIA_JSON}"
}

# usage: mjq [-r] <query> <json>
# dies on failure
mjq() {
    assert_media_json
    local raw=""
    if [[ "${1}" == "-r" ]]; then
        raw="-r"
        shift
    fi
    jq ${raw} <<<"${2}" "${1}" || die "jq failed: expr: ${1} --- json ${2}"
}

# select the best quality audio stream for language $1
# returns the ffmpeg stream id if found else dies
best_astream() {
    if [[ ${#} -eq 1 ]] && [[ ${#1} -ne 2 ]]; then
        die "lang should be a 2 letter identifier"
    fi

    assert_media_json

    local query="[ .[\"media\"].[\"track\"][] | select(.[\"@type\"] == \"Audio\")"

    # limit to lang if requested
    if [[ -n "${1}" ]]; then
        query+=" | select(.[\"Language\"] == \"${1}\")"
    fi

    query+=" ]"

    streams="$(mjq "${query}" "${MEDIA_JSON}")"

    if [[ "$(mjq "length" "${streams}")" -eq 0 ]]; then
        die "No stream found"
    fi

    # parameters to sort by
    local queries=(
        # lossless
        "[ .[] | select(.[\"Compression Mode\"] == \"Lossless\") ]"
        # TrueHD
        "[ .[] | select(.[\"CodecID\"] == \"A_TRUEHD\") ]"
        # DTS
        "[ .[] | select(.[\"CodecID\"] == \"A_DTS\") ]"
        # AC3
        "[ .[] | select(.[\"CodecID\"] == \"A_AC3\") ]"
        # most channels
        "[ (sort_by(.[\"Channels\"] | tonumber) | reverse | .[0][\"Channels\"] | tonumber) as \$max | .[] | select(.[\"Channels\"] | tonumber == \$max) ]"
        # highest avg bitrate
        "[ (sort_by(.[\"BitRate\"] | tonumber) | reverse | .[0][\"BitRate\"] | tonumber) as \$max | .[] | select(.[\"BitRate\"] | tonumber == \$max) ]"
        # fall back to using the first stream left
        "[ first ]"
        )

    local i=0
    while (( i < ${#queries[@]} )); do
        result="$(mjq "${queries[${i}]}" "${streams}")"
        # if only 1 result stream use that
        if [[ "$(mjq -r "length" "${result}")" -eq 1 ]]; then
            echo -n "$(mjq -r ".[0][\"StreamOrder\"]" "${result}")"
            return
        # if more than one continue with those
        elif [[ "$(mjq -r "length" "${result}")" -gt 0 ]]; then
            streams="${result}"
        fi
        # start next query
        i="$(( i + 1 ))"
    done
}

# usage: stat_stream <global ffmpeg streamid> <mediainfo key>
stat_stream() {
    if [[ ${#} -ne 2 ]]; then
        die "takes 2 args"
    fi

    local query="[ .[\"media\"].[\"track\"][] | select(.[\"StreamOrder\"] != null) ][${1}]"
    local result="$(mjq -r "${query}" "${MEDIA_JSON}")"
    
    if [[ "${result}" == null ]]; then
        die "stream ${1} not found"
    fi

    query+=".[\"${2}\"]"
    result="$(mjq -r "${query}" "${MEDIA_JSON}")"

    echo -n "${result}"
}

# usage: stat_video <mediainfo key>
# like stat_stream
stat_video() {
    if [[ ${#} -ne 1 ]]; then
        die "takes 1 arg"
    fi

    local query="[ .[\"media\"].[\"track\"][] | select(.[\"@type\"] == \"Video\") ] | first | .[\"StreamOrder\"]"
    local vstream="$(mjq -r "${query}" "${MEDIA_JSON}")"
    
    local result="$(stat_stream "${vstream}" "${1}")"
    
    echo -n "${result}"
}

# get resulting video height
# no crop -> source height
# crop    -> crop height
stat_video_height() {
    case "${CROP}" in
        # auto should never be set except when PRETEND=true
        auto|none)
            local result="$(stat_video Height)"
            echo -n "${result}"
            ;;
        *)
            echo -n "${CROP}" | cut -d ":" -f 2
            ;;
    esac
}

# returns target gop
# it's min(10 * FPS, 300)
stat_video_gop() {
    local result="$(stat_video FrameRate)"

    # some deinterlacing filters double framerate
    local expr
    case "$(filter_video_deinterlace 2>/dev/null)" in
        bwdif)
            expr="${result} * 10 * 2"
            ;;
        *)
            expr="${result} * 10"
            ;;
    esac

    result="$(echo "if ( ${expr} < 300 ) ${expr} else 300" | bc | xargs printf "%1.0f" )"
    echo -n "${result}"
}

# resolve *LANGS
# and sort manually selected STREAMS
setup_streams() {
    ASTREAMS=()
    SSTREAMS=()
    local stream type lang

    # first map the manual streams
    for stream in "${STREAMS[@]}"; do
        type="$(stat_stream "${stream}" "@type")"
        case "${type}" in
            Audio)
                info "Selecting stream ${stream} (${type})"
                ASTREAMS+=( "${stream}" )
                ;;
            Text)
                info "Selecting stream ${stream} (${type})"
                SSTREAMS+=( "${stream}" )
                ;;
            *)
                die "Unknown stream (${stream}) or stream type (${type})"
                ;;
        esac
    done

    # then then best for each selected language not manually set
    local haslang="false"
    for lang in "${ALANGS[@]}"; do
        # skip lang if a manual stream covers it
        for stream in "${ASTREAMS[@]}"; do
            if [[ "${lang}" == "$(stat_stream "${stream}" "Language")" ]]; then
                info "Language \"${lang}\" already covered by manually selected stream ${stream} - Skipping"
                haslang="true"
            fi
        done
        ${haslang} && continue

        stream="$(best_astream "${lang}")"
        info "Selecting stream ${stream} for language ${lang} (Audio)"
        ASTREAMS+=( "${stream}" )
    done

    # if we don't have any audio stream selected autoselect the best one
    if [[ ${#ASTREAMS[@]} -eq 0 ]]; then
        stream="$(best_astream)"
        info "Selecting best audio stream ${stream} because none was selected manually (Audio)"
        ASTREAMS+=( "${stream}" )
    fi
}

# check if video stream is interlaced
# if it is apply bwdif
filter_video_deinterlace() {
    local scantype="$(stat_video ScanType)"
    case "${scantype}" in
        Interlaced|MBAFF)
            info "Detected interlaced video - applying bwdif filter"
            echo -n "bwdif"
            ;;
        Progressive)
            ;;
        *)
            info "Don't know how to handle scantype ${scantype}. Check manually if needed."
            ;;
    esac
}

# get sar filter
filter_video_sar() {
    local result="$(stat_video PixelAspectRatio)"
    case "${result}" in
        *.*)
            info "Setting SAR ${result}"
            echo -n "setsar=sar=${result}"
            ;;
        *)
            die "Invalid SAR format ${result}"
            ;;
    esac
}

# get crop filter string
filter_video_crop() {
    case "${CROP}" in
        none)
            ;;
        auto)
            echo -n "crop=[pretending]"
            ;;
        *)
            echo -n "crop=${CROP}"
            ;;
    esac
}

# detect crop via ffmpeg cropdetect over full video
# might take a while as it decodes everything
detect_crop() {
    info "Starting crop detection. This may take a while."
    local crop="$(ffmpeg -loglevel info -i "${INFILE}" \
        -vf cropdetect -map 0:v:0 -f null - 2>&1 | \
        grep "^\[Parsed_cropdetect" | tail -1 | awk '{ print $NF }')"
    CROP="${crop#crop=}"
    info "Detected crop: ${CROP}"
    if ! grep -E '^[0-9]+:[0-9]+:[0-9]+:[0-9]+$' <<<"${CROP}" >/dev/null; then
        die "Detected crop '${CROP}' invalid."
    fi
}

check_env() {
    # *STREAMS
    # stat_stream will die if a stream isn't found
    local stream
    for stream in "${ASTREAMS[@]}" "${SSTREAMS[@]}"; do
        stat_stream "${stream}" ID >/dev/null
    done

    # CROP
    # if auto this will be re-checked after detection
    if ! grep -E '^([0-9]+:[0-9]+:[0-9]+:[0-9]+|auto|none)$' <<<"${CROP}" >/dev/null; then
        die "Crop '${CROP}' invalid. Should be 'XXXX:XXXX:XX:XX', 'auto' or 'none'."
    fi
    
    # *LANGS
    for lang in "${ALANGS[@]}"; do
        if ! grep -E '^[a-z]{2}$' <<<"${lang}" >/dev/null; then
            die "Lang '${lang}' invalid. Should be a 2 lowercase letter code."
        fi
    done
}

# video related flags
add_vflags() {
    # resulution classes
    # UHD-BD -> BD -> DVD
    local vheight="$(stat_video_height)"
    local resclass
    if (( vheight > 1080 )); then
        resclass="4k"
    elif (( vheight > 576 )); then
        resclass="fhd"
    else
        resclass="sd"
    fi

    # codec dependent options
    case "${VCODEC}" in
        libx264)
            FFMPEG_ARGS+=( -codec:v libx264 )
            # "visually lossless"
            # at "acceptable speeds"
            case "${resclass}" in
                4k)
                    FFMPEG_ARGS+=(
                        -preset slow
                        -crf 18
                    )
                    ;;
                fhd)
                    FFMPEG_ARGS+=(
                        -preset slower
                        -crf 17
                    )
                    ;;
                sd)
                    FFMPEG_ARGS+=(
                        -preset veryslow
                        -crf 16
                    )
                    ;;
            esac
            # optionally add a tune
            case "${TUNE}" in
                # the others don't make sense
                film|animation|grain)
                    FFMPEG_ARGS+=( -tune "${TUNE}" )
                    ;;
                # default to film
                "")
                    FFMPEG_ARGS+=( -tune film )
                    ;;
                # special value "none" to disable
                none) ;;
                *)
                    die "Unknown libx264 tune \"${TUNE}\""
                    ;;
            esac
            ;;
        libx265|"")
            FFMPEG_ARGS+=( -codec:v libx265 )
            # "visually lossless"
            # at "acceptable speeds"
            case "${resclass}" in
                4k)
                    FFMPEG_ARGS+=(
                        -preset medium
                        -crf 18
                    )
                    ;;
                fhd)
                    FFMPEG_ARGS+=(
                        -preset slow
                        -crf 17
                    )
                    ;;
                sd)
                    FFMPEG_ARGS+=(
                        -preset slow
                        -crf 16
                    )
                    ;;
            esac
            # always do 10bit
            FFMPEG_ARGS+=( -profile:v main10 -pix_fmt yuv420p10le )
            # optionally add a tune
            case "${TUNE}" in
                # emulate a film tune
                film|"")
                    FFMPEG_ARGS+=(
                        -x265-params "psy-rd=2.0:rdoq=2:psy-rdoq=1.5:rskip=2:deblock=-3,-3:rc-lookahead=60"
                    )
                    ;;
                animation)
                    FFMPEG_ARGS+=(
                        -x265-params "psy-rd=0.5:rdoq=2:psy-rdoq=0.3:rskip=2:deblock=1,1:rc-lookahead=60,bframes=6:aq-strength=0.4"
                    )
                    ;;
                grain)
                    FFMPEG_ARGS+=( -tune "${TUNE}" )
                    ;;
                # special value "none" to disable
                none) ;;
                *)
                    die "Unknown libx265 tune \"${TUNE}\""
                    ;;
            esac
            ;;
        libsvtav1)
            FFMPEG_ARGS+=( -codec:v libsvtav1 )
            # "visually lossless"
            # at "acceptable speeds"
            case "${resclass}" in
                4k)
                    FFMPEG_ARGS+=(
                        -preset 5
                        -crf 10
                    )
                    ;;
                fhd)
                    FFMPEG_ARGS+=(
                        -preset 5
                        -crf 10
                    )
                    ;;
                sd)
                    FFMPEG_ARGS+=(
                        -preset 5
                        -crf 10
                    )
                    ;;
            esac
            # optionally add a tune
            case "${TUNE}" in
                film|"")
                    FFMPEG_ARGS+=( -svtav1-params "tune=0:film-grain=8:film-grain-denoise=0:asm=avx2" )
                    ;;
                animation|grain)
                    die "not implemented"
                    ;;
                # special value "none" to disable
                none) ;;
                *)
                    die "Unknown libsvtav1 tune \"${TUNE}\""
                    ;;
            esac
            ;;
        *)
            die "Codec \"${VCODEC}\" not implemented"
            ;;
    esac

    # codec independent options
    # GOP is 10*fps capped at 300
    FFMPEG_ARGS+=( -g "$(stat_video_gop)" )

    # setup video filters
    local vfilters=( 
        $(filter_video_sar)
        $(filter_video_deinterlace)
        $(filter_video_crop)
    )
    IFS=","
    FFMPEG_ARGS+=( -filter:v "${vfilters[*]}" )
    unset IFS
}

# audio related flags
add_aflags() {
    case "${ACODEC}" in
        libfdk_aac)
            FFMPEG_ARGS+=(
                -codec:a libfdk_aac
                -vbr 5
            )
            ;;
        copy|"")
            FFMPEG_ARGS+=(
                -codec:a copy
            )
            ;;
        #libopus)
        #    local channels=$(jffprobe)
        #    FFMPEG_ARGS+=(
        #        -codec:a libopus
        #        -b:a 128k * channels
        #        -vbr on
        #        -compression_level 10
        #        -mapping_family $(channels <= 2 -> 0, else 1)
        #        -ac channels
        #    )
        #    ;;
        *)
            die "Codec \"${ACODEC}\" not implemented"
            ;;
    esac
}

# subtitle related flags
# for now nothing fancy, just copy
add_sflags() {
    FFMPEG_ARGS+=(
        -c:s copy
    )
}

# map streams and some metadata
add_mappings() {
    local i val
    # map global metadata
    FFMPEG_ARGS+=( -map_metadata 0 )

    # map video
    FFMPEG_ARGS+=( -map 0:v:0 )

    # no default metadata mappings
    FFMPEG_ARGS+=( -map_metadata:s:v -1 )
    FFMPEG_ARGS+=( -map_metadata:s:a -1 )
    FFMPEG_ARGS+=( -map_metadata:s:s -1 )

    # map audio and subtitles only keeping language and title metadata
    # audio
    i=0
    for s in "${ASTREAMS[@]}"; do
        FFMPEG_ARGS+=( -map "0:${s}" )
        # make first track the default
        FFMPEG_ARGS+=( "-disposition:a:${i}" "$([[ "${i}" -eq 0 ]] && echo -n default || echo -n 0)" )
        for tag in Language Title; do
            val="$(stat_stream "${s}" "${tag}")"
            [[ "${val}" != "null" ]] && FFMPEG_ARGS+=( "-metadata:s:a:${i}" "${tag,,}=${val}" )
        done
        i=$(( i + 1 ))
    done

    # subtitles
    i=0
    for s in "${SSTREAMS[@]}"; do
        FFMPEG_ARGS+=( -map "0:${s}" )
        for tag in Language Title; do
            val="$(stat_stream "${s}" "${tag}")"
            [[ "${val}" != "null" ]] && FFMPEG_ARGS+=( "-metadata:s:s:${i}" "${tag,,}=${val}" )
        done
        i=$(( i + 1 ))
    done
}

# global vars and default settings
# cli args
STREAMS=()
ALANGS=()
CROP="auto"
TUNE=""
VCODEC=""
ACODEC=""
PRETEND="false"
# internal
INFILE=""
OUTFILE=""
ASTREAMS=()
SSTREAMS=()
FFMPEG_ARGS=()
MEDIA_JSON=""

# parse args, overriding global vars
parse_args "${@}"

# setup media metada
init_media_json

# resolve streams from *LANGS
# and sort into correct *STREAMS var
setup_streams

# check if created environment is sane
check_env

# auto detect crop by default
if [[ "${CROP}" == auto ]]; then
    ${PRETEND} || detect_crop
fi

# build ffmpeg args
FFMPEG_ARGS+=( -i "${INFILE}" )
add_vflags
add_aflags
add_sflags
add_mappings
FFMPEG_ARGS+=( "${OUTFILE}" )

# start ffmpeg command for encode, PRETEND only echos command
info "[cmd]: ffmpeg ${FFMPEG_ARGS[*]}"
${PRETEND} || ffmpeg "${FFMPEG_ARGS[@]}"

# add missing track stats with mkvpropedit
info "[cmd]: mkvpropedit --add-track-statistics-tags ${OUTFILE}"
${PRETEND} || mkvpropedit --add-track-statistics-tags "${OUTFILE}"
