This is the audio unit independent of all the rest of the retromachine chaos. 

Version 0.90 beta

The changelog:

0.90: all functions seems to work, so beta stage reached. Now TODO: make an pure Ultibo example of using this

0.03: ChangeAudioParams works; 32-bit/stereo/96 kHz .wav tested OK 

0.02: What works: OpenAudio, PauseAudio. Now it can play 44100 Hz stereo 16-bit wav files.
The rest of functions and wave format still untested.

0.01: First commit, untested; OpenAudioEx works, the rest untested

-----------------------------------------------------------------------------
The unit allows to use the functions:

 - SDL based functions
function  OpenAudio(desired, obtained: PAudioSpec): Integer;
procedure CloseAudio;
procedure PauseAudio(p:integer);

 - additional functions not present in SDL API
function  ChangeAudioParams(desired, obtained: PAudioSpec): Integer;
procedure SetVolume(vol:single);
procedure SetVolume(vol:integer);
procedure setDBVolume(vol:single);

 - Simplified functions 
function  SA_OpenAudio(freq,bits,channels,samples:integer; callback: TAudioSpecCallback):integer;
function  SA_ChangeParams(freq,bits,channels,samples:integer): Integer;
function  SA_GetCurrentFreq:integer;
function  SA_GetCurrentRange:integer;

------------------------------------------------------------------------------

How to use this:

(1) You have to write the callback procedure. It has to be of type

TAudioSpecCallback = procedure(userdata: Pointer; stream: PUInt8; len:Integer );  

 so your procedure should look like

procedure my_callback(a: pointer; b: PUInt8; c:integer);

a will be a pointer to the user data (useless in most cases)
b will be a pointer to the empty buffer you have to fill
c will be length of this buffer in bytes

In the procedure you should fill the buffer as fast as you can with your samples.


(2) if you want to use classic SDL function, then goto 7;

(3) Let's use simplified function SA_OpenAudio. It needs frequency in Hz, bits per sample (8,16,32), channels (1 or 2), 
samples for one callback call (don't use big numbers here, for 44100/16/2 samples 384 is the maximum)- and the address 
of your callback function:

error:=SA_OpenAudio(44100,16,2,384,@my_callback);

If all go ok, you will get 0 as the result, or the error code.

(4) from this moment on the sound is ready to play as soon as you call pauseaudio(0) and then the callback will be called when it needs more samples

(5) if you want new audio parameters without closing the audio, use SA_ChangeParams. Set 0 for parameters you don't want to change

(6) use CloseAudio if you don't want it any more.

-------------------------------------------------
(7) Using SDL type fuctions:

(8) You have to declare 2 instances ot TAudioSpec record: "desired" and "obtained" 

(9) In the Desired record you have to fill the fields:
 - freq ->sample rate, from 8 to 960 kHz
 - format -> sample format, one of  (I got these from original SDL)     
      AUDIO_U8   - 8-bit unsigned
      AUDIO_S16 - 16-bit signed, CD standard
      AUDIO_F32 - 32-bit floats in range [-1..1]
 - channels - 1 or 2
 - samples - the buffer length in samples. Don't use too many samples, the maximum for 44100 stereo is about 384
 - callback - the pointer to callback procedure, from point (1) (desired.callback:=@my_callback; )
 - optional: userdata - the pointer to user data which will be then passed to the callback function

Any other fields will be ignored. They will be calculated by OpenAudio function 

(10) call OpenAudio(@desired, @obtained);

(11) if all is OK, the function will return 0, and you will get the real audio parameters in Obtained (for example if you want 44100 freq in Desired, you will get 44092 in Obtained as this is real sample rate set by the hardware)

(12) from this moment on the sound is ready to play as soon as you call pauseaudio(0) and then the callback will be called when it needs more samples
 
(13) pauseaudio(1) will pause, pauseaudio(0) will resume playing

(14) you can set volume by SetVolume (0.00..1.00) or (0..4096) or SetDBVolume(0..-72) in dB

(15) if you want new audio parameters without closing the audio, use ChangeAudioParams in the same way as OpenAudio

(16) CloseAudio will return the allocated RAM to the system and switch off the hardware


