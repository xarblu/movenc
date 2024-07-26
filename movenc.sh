#!/usr/bin/env bash

# Usage:
#   movenc.sh <infile> [<outfile>]
#
# User variables/args:
#   CROP - ffmpeg crop filter of format xx:xx:xx:xx
#   ASTREAMS - ffmpeg audio stream
#   SSTREAMS - ffmpeg subtitle stream
#   TUNE - x264 tune
#
# Dependencies:
# ffmpeg with needed codecs
# jq
# mkvpropedit (mkvtoolnix)
#
# TODO:
# - auto subtitle stream detection
# - select default audio codec based on what original is
# - default audio codec copy?
# - av1 + opus profile
#   - av1
#     - psy options
#     - grain stuff
#     - visually lossless
#   - opus
#     - per stream
#       - bitrate 128k * channels
#       - layout mapping (mainly 5.1(side) -> 5.1)
#       - explicit -mapping_family 0 or 1

set -e

# global vars modified during run
declare -a _FFMPEG_ARGS
declare MEDIA_JSON

# helper
die() {
    echo "[ERROR] ${FUNCNAME[0]}: ${*}" 1>&2
    echo "Stacktrace:"
    local stackheight=${#FUNCNAME[@]}
    local stackcur=0
    
    while (( stackcur < stackheight )); do
        echo -e "  ${FUNCNAME[${stackcur}]} at line ${BASH_LINENO[${stackcur}]} in ${BASH_SOURCE[$(( stackcur + 1 ))]}"
        stackcur=$(( stackcur + 1 ))
    done

    exit 1
}

info() {
    echo "[INFO] ${*}" 1>&2
}

# json output from ffprobe, all by default or a single
# specific one with $1
jffprobe() {
    local out
    case "${1}" in
        "")
            out="$(ffprobe -i "${INFILE}" \
                -v quiet -print_format json \
                -show_streams)"
            ;;
        # this must return exactly 1 stream
        *)
            out="$(ffprobe -i "${INFILE}" \
                -v quiet -print_format json \
                -show_streams -select_streams "${1#0:}")"
            if (( $(jq '.streams | length' <<<"${out}") != 1 )); then
                die "jffprobe ${1} didn't match exactly one stream"
            fi
            ;;
    esac
    # print via jq just in case echo might mangle something
    jq <<<"${out}"
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
    local raw
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

    local query streams i

    query="[ .[\"media\"].[\"track\"][] | select(.[\"@type\"] == \"Audio\")"

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
    queries=(
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

    i=0
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

    local query result
    query="[ .[\"media\"].[\"track\"][] | select(.[\"StreamOrder\"] != null) ][${1}].[\"${2}\"]"
    result="$(mjq -r "${query}" "${MEDIA_JSON}")"
    
    if [[ "${result}" == null ]]; then
        die "stream ${1} or key ${2} not found"
    fi

    echo -n "${result}"
}

# usage: stat_video <mediainfo key>
# like stat_stream
stat_video() {
    if [[ ${#} -ne 1 ]]; then
        die "takes 1 arg"
    fi

    local query vstream result
    query="[ .[\"media\"].[\"track\"][] | select(.[\"@type\"] == \"Video\") ] | first | .[\"StreamOrder\"]"
    vstream="$(mjq -r "${query}" "${MEDIA_JSON}")"
    
    result="$(stat_stream "${vstream}" "${1}")"
    
    echo -n "${result}"
}

# get resulting video height
# no crop -> source height
# crop    -> crop height
stat_video_height() {
    case "${CROP}" in
        ""|none)
            local result
            result="$(stat_video Height)"
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
    local result expr

    result="$(stat_video FrameRate)"

    # some deinterlacing filters double framerate
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
                ASTREAMS+=( "${stream}" )
                ;;
            Text)
                SSTREAMS+=( "${stream}" )
                ;;
            *)
                die "Unknown stream (${stream}) or stream type (${type})"
                ;;
        esac
    done

    # then then best for each selected language
    for lang in "${ALANGS[@]}"; do
        ASTREAMS=( "$(best_astream "${lang}")" )
    done

    # if we don't have any audio stream selected autoselect the best one
    if [[ ${#ASTREAMS[@]} -eq 0 ]]; then
        info "Selecting best audio stream because none was selected manually"
        ASTREAMS=( "$(best_astream)" )
    fi
}

# check if video stream is interlaced
# if it is apply bwdif
filter_video_deinterlace() {
    local scantype

    scantype="$(stat_video ScanType)"

    case "${scantype}" in
        Interlaced)
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
    local result

    result="$(stat_video PixelAspectRatio)"

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
    [[ -n "${CROP}" ]] && echo -n "crop=${CROP}"
    return 0
}

# detect crop via ffmpeg cropdetect over full video
# might take a while as it decodes everything
detect_crop() {
    info "Starting crop detection. This may take a while."
    local crop
    crop="$(ffmpeg -loglevel info -i "${INFILE}" \
        -vf cropdetect -map 0:v:0 -f null - 2>&1 | \
        grep "^\[Parsed_cropdetect" | tail -1 | awk '{ print $NF }')"
    CROP="${crop#crop=}"
    info "Detected crop: ${CROP}"
    if ! grep -E '^[0-9]+:[0-9]+:[0-9]+:[0-9]+$' <<<"${CROP}" >/dev/null; then
        die "Detected crop '${CROP}' invalid."
    fi
}

# $1: stream_spec $2: tag
get_tag_for() {
    jffprobe "${1}" | jq --raw-output ".streams[0].tags.${2}"
}

check_env() {
    local stream
    # ASTREAMS
    for stream in ${ASTREAMS}; do
        if ! grep -E '^0:a:[0-9]+$' <<<"${stream}" >/dev/null; then
            die "Audio stream '${stream}' invalid. Should be '0:a:X'."
        fi
    done
    # SSTREAMS
    for stream in ${SSTREAMS}; do
        if ! grep -E '^0:s:[0-9]+$' <<<"${stream}" >/dev/null; then
            die "Subtitle stream '${stream}' invalid. Should be '0:s:X'."
        fi
    done
    # CROP
    # if auto this will be re-checked after detection
    if ! grep -E '^([0-9]+:[0-9]+:[0-9]+:[0-9]+|auto|none|)$' <<<"${CROP}" >/dev/null; then
        die "Crop '${CROP}' invalid. Should be 'XXXX:XXXX:XX:XX', 'auto' or 'none'."
    fi
    # TUNE, VCODEC, ACODEC
    # currently handled in respective functions, maybe rebase
    # to allow early check
    
    # *LANGS
    for lang in ${ALANGS} ${SLANGS}; do
        if ! grep -E '^[a-z]{2}$' <<<"${lang}" >/dev/null; then
            die "Lang '${lang}' invalid. Should be a 2 lowercase letter code."
        fi
    done

    # TODO: disallow manual astreams + alangs
}

# video related flags
add_vflags() {
    local vheight="$(stat_video_height)"
    # codec dependent options
    case "${VCODEC}" in
        libx264)
            _FFMPEG_ARGS+=( -codec:v libx264 )
            # "visually lossless"
            # at "acceptable speeds"
            # UHD-BD -> BD -> DVD
            if (( vheight > 1080 )); then
                _FFMPEG_ARGS+=(
                    -preset slow
                    -crf 18
                )
            elif (( vheight > 576 )); then
                _FFMPEG_ARGS+=(
                    -preset slower
                    -crf 17
                )
            else
                _FFMPEG_ARGS+=(
                    -preset veryslow
                    -crf 16
                )
            fi
            # optionally add a tune
            case "${TUNE}" in
                # the others don't make sense
                film|animation|grain)
                    _FFMPEG_ARGS+=( -tune "${TUNE}" )
                    ;;
                # default to film
                "")
                    _FFMPEG_ARGS+=( -tune film )
                    ;;
                # special value "none" to disable
                none) ;;
                *)
                    die "Unknown libx264 tune \"${TUNE}\""
                    ;;
            esac
            ;;
        libx265|"")
            _FFMPEG_ARGS+=( -codec:v libx265 )
            # "visually lossless"
            # at "acceptable speeds"
            # UHD-BD -> BD -> DVD
            if (( vheight > 1080 )); then
                _FFMPEG_ARGS+=(
                    -preset medium
                    -crf 18
                )
            elif (( vheight > 576 )); then
                _FFMPEG_ARGS+=(
                    -preset slow
                    -crf 17
                )
            else
                _FFMPEG_ARGS+=(
                    -preset slow
                    -crf 16
                )
            fi
            # always do 10bit
            _FFMPEG_ARGS+=( -profile:v main10 -pix_fmt yuv420p10le )
            # optionally add a tune
            case "${TUNE}" in
                # emulate a film tune
                film|"")
                    _FFMPEG_ARGS+=(
                        -x265-params "psy-rd=2.0:rdoq=2:psy-rdoq=1.5:rskip=2:deblock=-3,-3:rc-lookahead=60"
                    )
                    ;;
                animation)
                    _FFMPEG_ARGS+=(
                        -x265-params "psy-rd=0.5:rdoq=2:psy-rdoq=0.3:rskip=2:deblock=1,1:rc-lookahead=60,bframes=6:aq-strength=0.4"
                    )
                    ;;
                grain)
                    _FFMPEG_ARGS+=( -tune "${TUNE}" )
                    ;;
                # special value "none" to disable
                none) ;;
                *)
                    die "Unknown libx265 tune \"${TUNE}\""
                    ;;
            esac
            ;;
        libsvtav1)
            _FFMPEG_ARGS+=( -codec:v libsvtav1 )
            # "visually lossless"
            # at "acceptable speeds"
            # UHD-BD -> BD -> DVD
            if (( vheight > 1080 )); then
                _FFMPEG_ARGS+=(
                    -preset 5
                    -crf 10
                )
            elif (( vheight > 576 )); then
                _FFMPEG_ARGS+=(
                    -preset 5
                    -crf 10
                )
            else
                _FFMPEG_ARGS+=(
                    -preset 5
                    -crf 10
                )
            fi
            # optionally add a tune
            case "${TUNE}" in
                film|"")
                    _FFMPEG_ARGS+=( -svtav1-params "tune=0:film-grain=8:film-grain-denoise=0:asm=avx2" )
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
    _FFMPEG_ARGS+=( -g "$(stat_video_gop)" )

    # setup video filters
    local vfilters=( 
        $(filter_video_sar)
        $(filter_video_deinterlace)
        $(filter_video_crop)
    )
    IFS=","
    _FFMPEG_ARGS+=( -filter:v "${vfilters[*]}" )
    unset IFS
}

# audio related flags
add_aflags() {
    case "${ACODEC}" in
        libfdk_aac)
            _FFMPEG_ARGS+=(
                -codec:a libfdk_aac
                -vbr 5
            )
            ;;
        copy|"")
            _FFMPEG_ARGS+=(
                -codec:a copy
            )
            ;;
        #libopus)
        #    local channels=$(jffprobe)
        #    _FFMPEG_ARGS+=(
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
    _FFMPEG_ARGS+=(
        -c:s copy
    )
}

# map streams and some metadata
add_mappings() {
    local i val
    # map global metadata
    _FFMPEG_ARGS+=( -map_metadata 0 )

    # map video
    _FFMPEG_ARGS+=( -map 0:v:0 )

    # no default metadata mappings
    _FFMPEG_ARGS+=( -map_metadata:s:v -1 )
    _FFMPEG_ARGS+=( -map_metadata:s:a -1 )
    _FFMPEG_ARGS+=( -map_metadata:s:s -1 )

    # map audio and subtitles only keeping language and title metadata
    # audio
    i=0
    for s in "${ASTREAMS[@]}"; do
        _FFMPEG_ARGS+=( -map "0:${s}" )
        # make first track the default
        _FFMPEG_ARGS+=( "-disposition:a:${i}" "$([[ "${i}" -eq 0 ]] && echo -n default || echo -n 0)" )
        for tag in Language Title; do
            val="$(stat_stream "${s}" "${tag}")"
            [[ "${val}" != "null" ]] && _FFMPEG_ARGS+=( "-metadata:s:a:${i}" "${tag,,}=${val}" )
        done
        i=$(( i + 1 ))
    done

    # subtitles
    i=0
    for s in "${SSTREAMS[@]}"; do
        _FFMPEG_ARGS+=( -map "0:${s}" )
        for tag in Language Title; do
            val="$(stat_stream "${s}" "${tag}")"
            [[ "${val}" != "null" ]] && _FFMPEG_ARGS+=( "-metadata:s:s:${i}" "${tag,,}=${val}" )
        done
        i=$(( i + 1 ))
    done
}

# setup environment
for arg in "${@}"; do
    case "${arg}" in
        --streams=*)
            STREAMS=( ${arg#*=} )
            shift
            ;;
        --alangs=*)
            ALANGS=( ${arg#*=} )
            shift
            ;;
        --crop=*)
            CROP="${arg#*=}"
            shift
            ;;
        --tune=*)
            TUNE="${arg#*=}"
            shift
            ;;
        --vcodec=*)
            VCODEC="${arg#*=}"
            shift
            ;;
        --acodec=*)
            ACODEC="${arg#*=}"
            shift
            ;;
    esac
done

# needs 1 arg, a file that exists
[[ ! -f "${1}" ]] && echo "File \"${1}\" doesn't exist." && exit 1

# arg $1 is input file
INFILE="${1}"

# arg $2 is output file (defaults to ${INFILE%.*}+done.mkv)
OUTFILE="${2:-${INFILE%.*}+done.mkv}"

# setup media metada
init_media_json

# resolve streams from *LANGS
# and sort into correct *STREAMS var
setup_streams

# check if created environment is sane
#check_env

# auto detect crop by default
case "${CROP}" in
    auto|"") detect_crop ;;
    none) unset CROP ;;
    *) ;;
esac

# build ffmpeg args
_FFMPEG_ARGS+=( -i "${INFILE}" )
add_vflags
add_aflags
add_sflags
add_mappings
_FFMPEG_ARGS+=( "${OUTFILE}" )

# start ffmpeg command for encode, PRETEND only echos command
info "[cmd]: ffmpeg ${_FFMPEG_ARGS[*]}"
[[ -z "${PRETEND}" ]] && ffmpeg "${_FFMPEG_ARGS[@]}"

# add missing track stats with mkvpropedit
info "[cmd]: mkvpropedit --add-track-statistics-tags ${OUTFILE}"
[[ -z "${PRETEND}" ]] && mkvpropedit --add-track-statistics-tags "${OUTFILE}"
