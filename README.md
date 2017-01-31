This is the audio unit independent of all the rest of the retromachine chaos. As it is now, it is written but not debugged yet so I think it is not in the working state. As I need this thing, I will now start debugging the unit.

Its API is modelled after SDL audio.

How to use this:

(1) You have to write the callback procedure. It has to be of type

TAudioSpecCallback = procedure(userdata: Pointer; stream: PUInt8; len:Integer );  

 so your procedure should look like

procedure my_callback(a: pointer; b: PUInt8; c:integer);

a will be a pointer to the user data (useless in most cases)
b will be a pointer to the empty buffer you have to fill
c will be length of this buffer in bytes

In the procedure you should fill the buffer as fast as you can with your samples.

(2) You have to declare 2 instances ot TAudioSpec record: "desired" and "obtained" 

(3) In the Desired record you have to fill the fields:
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

(4) call OpenAudio(@desired, @obtained);

(5) if all is OK, the function will return 0, and you will get the real audio parameters in Obtained (for example if you want 44100 freq in Desired, you will get 44092 in Obtained as this is real sample rate set by the hardware)

(6) from this moment on the sound is ready to play as soon as you call pauseaudio(0) and then the callback will be called when it needs more samples
 
(7) pauseaudio(1) will pause, pauseaudio(0) will resume playing

(8) you can set volume by SetVolume (0.00..1.00) or (0..4096) or SetDBVolume(0..-72) in dB

(9) if you want new audio parameters without closing the audio, use ChangeAudioParams in the same way as OpenAudio

(10) CloseAudio will return the allocated RAM to the system and switch off the hardware


