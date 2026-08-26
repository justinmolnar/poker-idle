"""Render the felt sounds that are variants of the uVegas pack: the card
deal degraded three ways (the ending flood). Output: assets/audio/felt/*.ogg. Needs ffmpeg on
PATH or at the winget location below."""
import os, shutil, subprocess
FF = shutil.which("ffmpeg") or os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0-full_build\bin\ffmpeg.exe")
PACK = "assets/audio/uVegas Authentic Casino Chips & Cards Sounds/"
OUT = "assets/audio/felt"
os.makedirs(OUT, exist_ok=True)
def run(src, dst, af):
    subprocess.check_call([FF, "-y", "-v", "error", "-i", src, "-af", af, "-ac", "1", "-ar", "44100", "-c:a", "libvorbis", "-q:a", "5", os.path.join(OUT, dst)])
    print("rendered", dst)
give = PACK + "Cards/Give/give_03.wav"
# 1: bitcrushed   2: lower sample rate + crush   3: clicks (gated to the transient)
run(give, "card_degraded_1.ogg", "acrusher=bits=6:mode=log:aa=1,loudnorm=I=-18:TP=-1.5")
run(give, "card_degraded_2.ogg", "aresample=8000,aresample=44100,acrusher=bits=4:mode=log:aa=0,loudnorm=I=-18:TP=-1.5")
run(give, "card_degraded_3.ogg", "atrim=0:0.06,acrusher=bits=3:mode=lin:aa=0,highpass=f=1200,apad=pad_dur=0.05,loudnorm=I=-18:TP=-1.5")
