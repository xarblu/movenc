#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys

class TrackNotFoundError(Exception):
    def __init__(self, msg: str):
        super().__init__(msg)

class MediaFile():
    def __init__(self, file: str):
        p = subprocess.run(["mediainfo", "--version"], capture_output=True, check=True, text=True)
        print(f"MediaFile: Using {" ".join(p.stdout.splitlines())}", file=sys.stderr)

        if not file:
            self.file = ""
            self.mediainfo = {}
        else:
            if not os.path.isfile(file):
                raise FileNotFoundError(f"{file} doesn't exist")

            self.file = file

            p = subprocess.run(["mediainfo", "--output=JSON", self.file], capture_output=True, check=True, text=True)
            self.mediainfo = json.loads(p.stdout)

    # params:
    #  language: str -> only select tracks of language
    # returns:
    #  mediainfo audio track dict
    def getBestAudioTrack(self, language: str = "") -> dict:
        if not self.file:
            raise RuntimeError("No file was loaded via loadFile()")

        if language and len(language) != 2:
            raise ValueError("language must be 2 letter identifier")
        
        tracks = [track for track in self.mediainfo["media"]["track"] if track["@type"] == "Audio"]

        if language:
            tracks = [track for track in tracks if track["Language"] == language]

        if not tracks:
            msg = "No tracks found" + f"for language {language}" if language else ""
            raise TrackNotFoundError(msg)

        # select by highest channelcount
        maxchannels = 0
        for track in tracks:
            channels = int(track["Channels"])
            if channels > maxchannels:
                maxchannels = channels

        try:
            found = [track for track in tracks if int(track["Channels"]) == maxchannels]
        except KeyError:
            found = []
        if found:
            tracks = found
        if len(tracks) == 1:
            return tracks[0]

        # select lossless audio
        try:
            found = [track for track in tracks if track["Compression_Mode"] == "Lossless"]
        except KeyError:
            found = []
        if found:
            tracks = found
        if len(tracks) == 1:
            return tracks[0]

        # select by highest bitrate
        maxbitrate = 0
        for track in tracks:
            # sometimes BitRate field is "num / num" (e.g. for PCM)
            # in that case pick the first
            bitrate = int(track["BitRate"].split("/")[0])
            if bitrate > maxbitrate:
                maxbitrate = bitrate

        try:
            found = [track for track in tracks if int(track["BitRate"].split("/")[0]) == maxbitrate]
        except KeyError:
            found = []
        if found:
            tracks = found
        if len(tracks) == 1:
            return tracks[0]

        # fallback to first
        return tracks[0]

    # params:
    #  id: int -> stream id
    #  tracktype: str -> select among tracks of this type only
    # returns:
    #  mediainfo track
    def getTrack(self, id: int, tracktype: str = "") -> dict:
        if tracktype not in ["", "Video", "Audio", "Text"]:
            raise ValueError(f"Unknown tracktype: {tracktype}")
        
        # only tracks with StreamOrder defined are valid
        tracks = [track for track in self.mediainfo["media"]["track"] if "StreamOrder" in track]

        # select the tracktypes
        if tracktype:
            tracks = [track for track in self.mediainfo["media"]["track"] if track["@type"] == tracktype]

        try:
            return tracks[id]
        except IndexError:
            msg = f"Couldn't find track {id}" + (f" of type {tracktype}" if tracktype else "")
            raise TrackNotFoundError(msg)

class Muxer():
    def __init__(self, infile: str, outfile: str, implementation: str = "mkvmerge"):
        if implementation == "mkvmerge":
            p = subprocess.run(["mkvmerge", "--version"], capture_output=True, check=True, text=True)
            print(f"Muxer: Using {p.stdout.strip()}", file=sys.stderr)
            self.impl = implementation
        elif implementation == "ffmpeg":
            p = subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True, text=True)
            print(f"Muxer: Using {p.stdout.splitlines()[0].strip()}", file=sys.stderr)
            self.impl = implementation
        else:
            raise ValueError(f"Unsopported implementation: {implementation}")

        if os.path.isfile(outfile):
            raise RuntimeError(f"Output file {outfile} exists")

        outdir = os.path.dirname(outfile)
        if not os.path.isdir(outdir if outdir else "."):
            raise FileNotFoundError(f"Output dir for file {outfile} doesn't exist")

        self.infile: MediaFile = MediaFile(infile)
        self.outfile: str = outfile
        self.videotracks: list = []
        self.audiotracks: list = []
        self.texttracks: list = []

    def addTrack(self, id: str):
        # handle forced tag
        if id.endswith("!"):
            forced = True
        else:
            forced = False

        id = id.rstrip("!")

        # if we can convert id to int it's a global id
        try:
            id = int(id)
            tracktype = ""
        except ValueError:
            tracktype, id = id.split(":")
            # convert
            if tracktype == "v":
                tracktype = "Video"
            if tracktype == "a":
                tracktype = "Audio"
            if tracktype == "s":
                tracktype = "Text"
            id = int(id)

        # query
        track = self.infile.getTrack(id=id, tracktype=tracktype)

        # change default and forced state
        track["Default"] = "No" # TODO
        track["Forced"] = "Yes" if forced else "No"

        # add
        if track["@type"] == "Video":
            self.videotracks.append(track)
        elif track["@type"] == "Audio":
            self.audiotracks.append(track)
        elif track["@type"] == "Text":
            self.texttracks.append(track)
        else:
            raise TypeError(f"Don't know how to handle track type {track['@type']}")

    def addLangAudioTrack(self, language: str):
        # special values
        # "any" add the overally best stream if none exists
        if language == "any":
            if not self.audiotracks:
                self.audiotracks.append(self.infile.getBestAudioTrack())
            return

        # <lang> and <lang>? tracks
        if len(language) == 2:
            optional = False
        elif len(language) == 3 and language[-1] == "?":
            language = language[:2]
            optional = True
        else:
            raise ValueError(f"Invalid language identifier {language}")

        # don't add if language already exists (e.g. because manually selected prior)
        for track in self.audiotracks:
            if track["Language"] == language:
                print(f"Language {language} already selected by {track['StreamOrder']}", file=sys.stderr)
                return

        try:
            self.addTrack(id=self.infile.getBestAudioTrack(language=language)["StreamOrder"])
        except TrackNotFoundError:
            if not optional:
                raise TrackNotFoundError(f"Could not find required track for language {language}")

    def getMkvmergeCmd(self):
        # ensure a video stream exists, if not select the first
        videotracks = self.videotracks if self.videotracks else [self.infile.getTrack(id=0, tracktype="Video")]

        audiotracks = self.audiotracks
        texttracks = self.texttracks

        # IDs of tracks we need (others will be dropped)
        videotrackids = [track["StreamOrder"] for track in videotracks]
        audiotrackids = [track["StreamOrder"] for track in audiotracks]
        texttrackids = [track["StreamOrder"] for track in texttracks]

        # order of tracks in output file
        trackorder = []
        for track in videotracks + audiotracks + texttracks:
            # for now we only support 1 infile
            trackorder += ["0:" + track["StreamOrder"]]

        # init cmd
        cmd = ["mkvmerge"]

        # global options
        cmd += ["--track-order", ",".join(trackorder)]
        cmd += ["-o", self.outfile]

        # per infile options
        # included tracks
        
        # add tracks
        if videotracks:
            cmd += ["--video-tracks", ",".join(videotrackids)]
        else:
            cmd += ["--no-video"]

        if audiotracks:
            cmd += ["--audio-tracks", ",".join(audiotrackids)]
        else:
            cmd += ["--no-audio"]

        if texttracks:
            cmd += ["--subtitle-tracks", ",".join(texttrackids)]
        else:
            cmd += ["--no-subtitles"]

        # setup other flags
        for track in videotracks + audiotracks + texttracks:
            cmd += ["--default-track-flag",
                    track["StreamOrder"] + (":1" if track["Default"] == "Yes" else ":0")]
            cmd += ["--forced-display-flag",
                    track["StreamOrder"] + (":1" if track["Forced"] == "Yes" else ":0")]
            #cmd += ["--compression", track["StreamOrder"] + ":none"]

        # add file
        cmd += [self.infile.file]

        return cmd

    def getFfmpegCmd(self):
        # ensure a video stream exists, if not select the first
        videotracks = self.videotracks if self.videotracks else [self.infile.getTrack(id=0, tracktype="Video")]

        audiotracks = self.audiotracks
        texttracks = self.texttracks

        # order of tracks in output file
        trackorder = []
        for track in videotracks + audiotracks + texttracks:
            # for now we only support 1 infile
            trackorder += ["0:" + track["StreamOrder"]]

        # init cmd
        cmd = ["ffmpeg", "-analyzeduration", "200M", "-probesize", "1G"]
        cmd += ["-i", self.infile.file]

        # we only mux
        cmd += ["-c", "copy"]

        # setup tracks
        outid = 0
        for track in videotracks + audiotracks + texttracks:
            # mapping
            cmd += ["-map", "0:" + track["StreamOrder"]]

            # disposition tags
            cmd += ["-disposition:" + str(outid)]
            disposition = []
            if track["Default"] == "Yes":
                disposition += ["default"]
            if track["Forced"] == "Yes":
                disposition += ["forced"]
            if disposition:
                cmd += ["+".join(disposition)]
            else:
                cmd += ["0"]

            outid += 1

        # copy timestamps (avoids audio desync)
        cmd += ["-start_at_zero", "-copyts", "-avoid_negative_ts", "disabled"]

        # add outfile
        cmd += [self.outfile]

        return cmd

    def start(self, pretend: bool = False):
        if self.impl == "mkvmerge":
            cmd = self.getMkvmergeCmd()
        elif self.impl == "ffmpeg":
            cmd = self.getFfmpegCmd()
        else:
            # should not be reachable but eh
            raise RuntimeError()
        # print and run
        print("CMD: " + str(cmd))
        if pretend:
            return
        subprocess.run(cmd, check=True)

def parse_args():
    parser = argparse.ArgumentParser(
            prog = os.path.basename(sys.argv[0]),
            description = "MUX MOVies"
            )
    parser.add_argument("infile", type = str, nargs = 1,
                        help = "Input file")
    parser.add_argument("outfile", type = str, nargs = 1,
                        help = "Output file")
    parser.add_argument("--langs",  type = str, nargs = 1, required = True,
                        help = "Audio Languages - 2 letter country codes, optional if suffixed with '?' or special values 'any', 'none'")
    parser.add_argument("--tracks", type = str, nargs = 1,
                        help = "Manual track selection - global id, type id (<type>:id), optional suffix '!' - mark 'forced'")
    parser.add_argument("--pretend", const = True, default = False, action = "store_const",
                        help = "Print commands instead of executing")
    parser.add_argument("--muxer", type = str, nargs = 1,
                        help = "Muxer implementation (mkvmerge or ffmpeg)")
    args = parser.parse_args()

    return {
            "infile": args.infile[0],
            "outfile": args.outfile[0],
            "langs": args.langs[0].split() if args.langs else [],
            "tracks": args.tracks[0].split() if args.tracks else [],
            "pretend": args.pretend,
            "muxer": args.muxer[0] if args.muxer else "ffmpeg"
            }
        
def main():
    args = parse_args()

    # the main muxer object
    muxer = Muxer(args["infile"], args["outfile"], args["muxer"])

    # add manual tracks first
    for track in args["tracks"]:
        muxer.addTrack(track)

    # then audio language tracks
    # "none" completely skips language based track detection
    if "none" not in args["langs"]:
        for lang in args["langs"]:
            muxer.addLangAudioTrack(lang)
    
    # run the muxer
    muxer.start(args["pretend"])

if __name__ == "__main__":
    sys.exit(main())
