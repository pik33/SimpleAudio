unit simpleaudio;

//------------------------------------------------------------------------------
// A simple audio unit for Ultibo modelled after SDL audio API
// v.0.92 beta - 20180426
// pik33@o2.pl
// gpl 2.0 or higher
//------------------------------------------------------------------------------
//
// beta changelog
//
// 0.92 - fixed the bug which caused distortions while playing at 960 kHz sample rate
// 0.91 - fixed the bug which caused 1-channel sound play badly distorted
//
//------------------------------------------------------------------------------

{$mode objfpc}{$H+}

interface

uses  Classes, SysUtils, Platform, HeapManager, Threads, GlobalConst, math;

type

// ----  I decided to use SDL-like API so this fragment is copied from SDL unit
// ----- and modified somewhat

TAudioSpecCallback = procedure(userdata: Pointer; stream: PUInt8; len:Integer );

PAudioSpec = ^TAudioSpec;

TAudioSpec = record
  freq: Integer;       // DSP frequency -- samples per second
  format: UInt16;      // Audio data format
  channels: UInt8;     // Number of channels: 1 mono, 2 stereo
  silence: UInt8;      // Audio buffer silence value (calculated)
  samples: UInt16;     // Audio buffer size in samples
  padding: UInt16;     // Necessary for some compile environments
  size: UInt32;        // Audio buffer size in bytes (calculated)

                       //     This function is called when the audio device needs more data.
                       //    'stream' is a pointer to the audio data buffer
                       //    'len' is the length of that buffer in bytes.
                       //     Once the callback returns, the buffer will no longer be valid.
                       //     Stereo samples are stored in a LRLRLR ordering.

  callback: TAudioSpecCallback;
  userdata: Pointer;
                      // 3 fields added, not in SDL

  oversample: UInt8;  // oversampling value
  range: UInt16;      // PWM range
  oversampled_size: integer; // oversampled buffer size
  end;


const

// ---------- Error codes

      freq_too_low=            -$11;
      freq_too_high=           -$12;
      format_not_supported=    -$21;
      invalid_channel_number=  -$41;
      size_too_low =           -$81;
      size_too_high=           -$81;
      callback_not_specified= -$101;

// ---------- Audio formats. Subset of SDL formats
// ---------- These are 99.99% of wave file formats:

      AUDIO_U8  = $0008; // Unsigned 8-bit samples
      AUDIO_S16 = $8010; // Signed 16-bit samples
      AUDIO_F32 = $8120; // Float 32 bit



// SDL based functions
function  OpenAudio(desired, obtained: PAudioSpec): Integer;
procedure CloseAudio;
procedure PauseAudio(p:integer);

// Functions not in SDL API
function  ChangeAudioParams(desired, obtained: PAudioSpec): Integer;
procedure SetVolume(vol:single);
procedure SetVolume(vol:integer);
procedure setDBVolume(vol:single);

// Simplified functions
function  SA_OpenAudio(freq,bits,channels,samples:integer; callback: TAudioSpecCallback):integer;
function  SA_ChangeParams(freq,bits,channels,samples:integer): Integer;
function  SA_GetCurrentFreq:integer;
function  SA_GetCurrentRange:integer;


//------------------ End of Interface ------------------------------------------

implementation

type
     PLongBuffer=^TLongBuffer;
     TLongBuffer=array[0..65535] of integer;  // 64K DMA buffer
     TCtrlBlock=array[0..7] of cardinal;
     PCtrlBlock=^TCtrlBlock;

TAudioThread= class(TThread)
private
protected
  procedure Execute; override;
public
 Constructor Create(CreateSuspended : boolean);
end;


const nocache=$C0000000;              // constant to disable GPU L2 Cache
      pll_freq=500000000;             // base PLL freq=500 MHz
      pwm_base_freq=1923077;

      divider=2;

      base_freq=pll_freq div divider;
      max_pwm_freq=pwm_base_freq div divider;

      dma_buffer_size=65536;          // max size for simplified channel

// TODO: make the sample buffer size dynamic (?)

      sample_buffer_size=32768;        // max size for sample buffer.
                                    
      sample_buffer_32_size=65536;    

// ------- Hardware registers addresses --------------------------------------

      _pwm_fif1_ph= $7E20C018;       // PWM FIFO input reg physical address

      _pwm_ctl=     $3F20C000;       // PWM Control Register MMU address
      _pwm_dmac=    $3F20C008;       // PWM DMA Configuration MMU address
      _pwm_rng1=    $3F20C010;       // PWM Range channel #1 MMU address
      _pwm_rng2=    $3F20C020;       // PWM Range channel #2 MMU address

      _gpfsel4=     $3F200010;       // GPIO Function Select 4 MMU address
      _pwmclk=      $3F1010a0;       // PWM Clock ctrl reg MMU address
      _pwmclk_div=  $3F1010a4;       // PWM clock divisor MMU address

      _dma_enable=  $3F007ff0;       // DMA enable register
      _dma_cs=      $3F007000;       // DMA control and status
      _dma_conblk=  $3F007004;       // DMA ctrl block address
      _dma_nextcb=  $3F00701C;       // DMA next control block

// ------- Hardware initialization constants

      transfer_info=$00050140;        // DMA transfer information
                                      // 5 - DMA peripheral code (5 -> PWM)
                                      // 1 - src address increment after read
                                      // 4 - DREQ controls write

      and_mask_40_45=  %11111111111111000111111111111000;  // AND mask for gpio 40 and 45
      or_mask_40_45_4= %00000000000000100000000000000100;  // OR mask for set Alt Function #0 @ GPIO 40 and 45

      clk_plld=     $5a000016;       // set clock to PLL D
      clk_div=      $5a000000 + divider shl 12;  //002000;       // set clock divisor to 2.0

      pwm_ctl_val=  $0000a1e1;       // value for PWM init:
                                     // bit 15: chn#2 set M/S mode=1. Use PWM mode for non-noiseshaped audio and M/S mode for oversampled noiseshaped audio
                                     // bit 13: enable fifo for chn #2
                                     // bit 8: enable chn #2
                                     // bit 7: chn #1 M/S mode on
                                     // bit 6: clear FIFO
                                     // bit 5: enable fifo for chn #1
                                     // bit 0: enable chn #1

      pwm_dmac_val= $80000707;       // PWM DMA ctrl value:
                                     // bit 31: enable DMA
                                     // bits 15..8: PANIC value
                                     // bits 7..0: DREQ value

      dma_chn= 14;                   // use DMA channel 14 (the last)


var       gpfsel4:cardinal     absolute _gpfsel4;      // GPIO Function Select 4
          pwmclk:cardinal      absolute _pwmclk;       // PWM Clock ctrl
          pwmclk_div: cardinal absolute _pwmclk_div;   // PWM Clock divisor
          pwm_ctl:cardinal     absolute _pwm_ctl;      // PWM Control Register
          pwm_dmac:cardinal    absolute _pwm_dmac;     // PWM DMA Configuration MMU address
          pwm_rng1:cardinal    absolute _pwm_rng1;     // PWM Range channel #1 MMU address
          pwm_rng2:cardinal    absolute _pwm_rng2;     // PWM Range channel #2 MMU address

          dma_enable:cardinal  absolute _dma_enable;   // DMA Enable register

          dma_cs:cardinal      absolute _dma_cs+($100*dma_chn); // DMA ctrl/status
          dma_conblk:cardinal  absolute _dma_conblk+($100*dma_chn); // DMA ctrl block addr
          dma_nextcb:cardinal  absolute _dma_nextcb+($100*dma_chn); // DMA next ctrl block addr

          dmactrl_ptr:PCardinal=nil;                   // DMA ctrl block pointer
          dmactrl_adr:cardinal absolute dmactrl_ptr;       // DMA ctrl block address
          dmabuf1_ptr:PCardinal=nil;                 // DMA data buffer #1 pointer
          dmabuf1_adr:cardinal absolute dmabuf1_ptr;   // DMA data buffer #1 address
          dmabuf2_ptr:PCardinal=nil;                 // DMA data buffer #2 pointer
          dmabuf2_adr:cardinal absolute dmabuf2_ptr;   // DMA data buffer #2 address

          ctrl1_ptr,ctrl2_ptr:PCtrlBlock;              // DMA ctrl block array pointers
          ctrl1_adr:cardinal absolute ctrl1_ptr;       // DMA ctrl block #1 array address
          ctrl2_adr:cardinal absolute ctrl2_ptr;       // DMA ctrl block #2 array address


//          CurrentAudioSpec:TAudioSpec;

          SampleBuffer_ptr:pointer;
          SampleBuffer_ptr_b:PByte absolute SampleBuffer_ptr;
          SampleBuffer_ptr_si:PSmallint absolute SampleBuffer_ptr;
          SampleBuffer_ptr_f:PSingle absolute SampleBuffer_ptr;
          SampleBuffer_adr:cardinal absolute SampleBuffer_ptr;

          SampleBuffer_32_ptr:PCardinal;
          SampleBuffer_32_adr:cardinal absolute SampleBuffer_32_ptr;

          AudioThread:TAudioThread;

          AudioOn:integer=0;                 // 1 - audio worker thread is running
          volume:integer=4096;               // audio volume; 4096 -> 0 dB
          pauseA:integer=1;                   // 1 - audio is paused


          nc:cardinal;
          working:integer;
          CurrentAudioSpec:TAudioSpec;
          s_desired, s_obtained: TAudioSpec;


procedure InitAudioEx(range,t_length:integer);  forward;
function noiseshaper8(bufaddr,outbuf,oversample,len:integer):integer; forward;

// ------------------------------------------------
// A helper procedure which removes RAM RO limit
// used here to speed up the noise shaper
//-------------------------------------------------

procedure removeramlimits(addr:integer);

var Entry:TPageTableEntry;

begin
Entry:=PageTableGetEntry(addr);
Entry.Flags:=$3b2;            //executable, shareable, rw, cacheable, writeback
PageTableSetEntry(Entry);
end;

//------------------------------------------------------------------------------
//  Procedure initaudio - init the GPIO, PWM and DMA for audio subsystem.
//------------------------------------------------------------------------------


procedure InitAudioEx(range,t_length:integer);               //TODO don't init second time!!!

var i:integer;

begin
dmactrl_ptr:=GetAlignedMem(64,32);      // get 64 bytes for 2 DMA ctrl blocks
ctrl1_ptr:=PCtrlBlock(dmactrl_ptr);     // set pointers so the ctrl blocks can be accessed as array
ctrl2_ptr:=PCtrlBlock(dmactrl_ptr+8);   // second ctrl block is 8 longs further
dmabuf1_ptr:=getmem(65536);                       // allocate 64k for DMA buffer
dmabuf2_ptr:=getmem(65536);                       // .. and the second one

ctrl1_ptr^[0]:=transfer_info;             // transfer info
ctrl1_ptr^[1]:=nocache+dmabuf1_adr;       // source address -> buffer #1
ctrl1_ptr^[2]:=_pwm_fif1_ph;              // destination address
ctrl1_ptr^[3]:=t_length;                  // transfer length
ctrl1_ptr^[4]:=$0;                        // 2D length, unused
ctrl1_ptr^[5]:=nocache+ctrl2_adr;         // next ctrl block -> ctrl block #2
ctrl1_ptr^[6]:=$0;                        // unused
ctrl1_ptr^[7]:=$0;                        // unused
ctrl2_ptr^:=ctrl1_ptr^;                   // copy first block to second
ctrl2_ptr^[5]:=nocache+ctrl1_adr;         // next ctrl block -> ctrl block #1
ctrl2_ptr^[1]:=nocache+dmabuf2_adr;       // source address -> buffer #2
CleanDataCacheRange(dmactrl_adr,64);      // now push this into RAM
sleep(1);

// Init the hardware

gpfsel4:=(gpfsel4 and and_mask_40_45) or or_mask_40_45_4;  // gpio 40/45 as alt#0 -> PWM Out
pwmclk:=clk_plld;                                          // set PWM clock src=PLLD (500 MHz)
pwmclk_div:=clk_div;                                       // set PWM clock divisor=2 (250 MHz)
pwm_rng1:=range;                                           // minimum range for 8-bit noise shaper to avoid overflows
pwm_rng2:=range;                                           //
pwm_ctl:=pwm_ctl_val;                                      // pwm contr0l - enable pwm, clear fifo, use fifo
pwm_dmac:=pwm_dmac_val;                                    // pwm dma enable
dma_enable:=dma_enable or (1 shl dma_chn);                 // enable dma channel # dma_chn
dma_conblk:=nocache+ctrl1_adr;                             // init DMA ctr block to ctrl block # 1
dma_cs:=$00FF0003;                                         // start DMA
end;


function SA_OpenAudio(freq,bits,channels,samples:integer; callback: TAudioSpecCallback):integer;

begin
s_desired.freq:=freq;
s_desired.samples:=samples;
s_desired.channels:=channels;
s_desired.samples:=samples;
s_desired.callback:=callback;
case bits of
  8:s_desired.format:= AUDIO_U8;
  16:s_desired.format:=AUDIO_S16;
  32:s_desired.format:=AUDIO_F32;
  else
    begin
    result:=format_not_supported;
    exit;
    end;
  end;
result:=OpenAudio(@s_desired,@s_obtained);
end;

function  SA_ChangeParams(freq,bits,channels,samples:integer): Integer;

begin
s_desired.freq:=freq;
s_desired.samples:=samples;
s_desired.channels:=channels;
s_desired.samples:=samples;
s_desired.callback:=nil;
case bits of
  0:s_desired.format:=0;
  8:s_desired.format:= AUDIO_U8;
  16:s_desired.format:=AUDIO_S16;
  32:s_desired.format:=AUDIO_F32;
  else
    begin
    result:=format_not_supported;
    exit;
    end;
  end;
result:=ChangeAudioParams(@s_desired,@s_obtained);
end;
// ----------------------------------------------------------------------
// OpenAudio
// Inits the audio according to specifications in 'desired' record
// The values which in reality had been set are in 'obtained' record
// Returns 0 or the error code, in this case 'obtained' is invalid
//
// You have to set the fields:
//
//     freq: samples per second, 8..960 kHz
//     format: audio data format
//     channels: number of channels: 1 mono, 2 stereo
//     samples: audio buffer size in samples. >32, not too long (<384 for stereo 44100 Hz)
//     callback: a callback function you have to write in your program
//
// The rest of fields in 'desire' will be ignored. They will be filled in 'obtained'
// ------------------------------------------------------------------------

function OpenAudio(desired, obtained: PAudioSpec): Integer;

var maxsize:double;
    over_freq:integer;

begin

result:=0;

// -----------  check if params can be used
// -----------  the frequency should be between 8 and 960 kHz

if desired^.freq<8000 then
  begin
  result:=freq_too_low;
  exit;
  end;

if desired^.freq>max_pwm_freq then
  begin
  result:=freq_too_high;
  exit;
  end;

//----------- check if the format is supported

if (desired^.format <> AUDIO_U8) and (desired^.format <> AUDIO_S16) and (desired^.format <> AUDIO_F32) then
  begin
  result:=format_not_supported;
  exit;
  end;

//----------- check the channel number

if (desired^.channels < 1) or (desired^.channels>2) then
  begin
  result:=invalid_channel_number;
  exit;
  end;

//----------- check the buffer size in samples
//----------- combined with the noise shaper should not exceed 64k
//            It is ~384 for 44 kHz S16 samples

if (desired^.samples<32) then
  begin
  result:=size_too_low;
  exit;
  end;

maxsize:=65528/max_pwm_freq*desired^.freq/desired^.channels;

if (desired^.samples>maxsize) then
  begin
  result:=size_too_high;
  exit;
  end;

if (desired^.callback=nil) then
  begin
  result:=callback_not_specified;
  exit;
  end;

// now compute the obtained parameters

obtained^:=desired^;

obtained^.oversample:=max_pwm_freq div desired^.freq;

  // the workaround for simply making 432 Hz tuned sound
  // the problem is: when going 44100->43298
  // the computed oversample changes from 21 to 22
  // and this causes the resulting DMA buffer exceed 64K
  // Also if I init the 43298 Hz soud, I will want to change it to 44100
  // without changing anything else

  if obtained^.oversample=22 then obtained^.oversample:=21;

over_freq:=desired^.freq*obtained^.oversample;
obtained^.range:=round(base_freq/over_freq);
obtained^.freq:=round(base_freq/(obtained^.range*obtained^.oversample));
if (desired^.format = AUDIO_U8) then obtained^.silence:=128 else obtained^.silence:=0;
obtained^.padding:=0;
obtained^.size:=obtained^.samples*obtained^.channels;
if obtained^.size>sample_buffer_size then
  begin
  result:=size_too_high;
  exit;
  end;

if obtained^.channels=2 then obtained^.oversampled_size:=obtained^.size*4*obtained^.oversample
                       else obtained^.oversampled_size:=obtained^.size*8*obtained^.oversample; //output is always 2 channels
if obtained^.format=AUDIO_U8 then obtained^.size:=obtained^.size;
if obtained^.format=AUDIO_S16 then obtained^.size:=obtained^.size*2;
if obtained^.format=AUDIO_F32 then obtained^.size:=obtained^.size*4;
InitAudioEx(obtained^.range,obtained^.oversampled_size);
CurrentAudioSpec:=obtained^;
samplebuffer_ptr:=getmem(sample_buffer_size);
samplebuffer_32_ptr:=getmem(sample_buffer_32_size);
removeramlimits(integer(@noiseshaper8));  // noise shaper uses local vars or it will be slower
// now create and start the audio thread
pauseA:=1;
AudioThread:=TAudioThread.Create(true);
AudioThread.start;
end;


// ---------- ChangeAudioParams -----------------------------------------
//
// This function will try to change audio parameters
// without closing and reopening the audio system (=loud click)
// The usage is the same as OpenAudio
//
// -----------------------------------------------------------------------

function ChangeAudioParams(desired, obtained: PAudioSpec): Integer;

var maxsize:double;
    over_freq:integer;

begin

// -------------- Do all things as in OpenAudio
// -------------- TODO: what is common, should go to one place

result:=0;
if desired^.freq=0 then desired^.freq:=CurrentAudioSpec.freq;
if desired^.freq<8000 then
  begin
  result:=freq_too_low;
  exit;
  end;
if desired^.freq>max_pwm_freq then
  begin
  result:=freq_too_high;
  exit;
  end;
if desired^.format=0 then desired^.format:=CurrentAudioSpec.format;
if (desired^.format <> AUDIO_U8) and (desired^.format <> AUDIO_S16) and (desired^.format <> AUDIO_F32) then
  begin
  result:=format_not_supported;
  exit;
  end;
if desired^.channels=0 then desired^.channels:=CurrentAudioSpec.channels;
if (desired^.channels < 1) or (desired^.channels>2) then
  begin
  result:=invalid_channel_number;
  exit;
  end;
if desired^.samples=0 then desired^.samples:=CurrentAudioSpec.samples ;
if (desired^.samples<32) then
  begin
  result:=size_too_low;
  exit;
  end;
maxsize:=65528/max_pwm_freq*desired^.freq/desired^.channels;
if (desired^.samples>maxsize) then
  begin
  result:=size_too_high;
  exit;
  end;
if (desired^.callback=nil) then  desired^.callback:=CurrentAudioSpec.callback;

obtained^:=desired^;
obtained^.oversample:=max_pwm_freq div desired^.freq;
  // the workaround for simply making 432 Hz tuned sound
  // the problem is: when going 44100->43298
  // the computed oversample changes from 21 to 22
  // and this causes the resulting DMA buffer exceed 64K

  if obtained^.oversample=22 then obtained^.oversample:=21;

over_freq:=desired^.freq*obtained^.oversample;
obtained^.range:=round(base_freq/over_freq);
obtained^.freq:=round(base_freq/(obtained^.range*obtained^.oversample));
if (desired^.format = AUDIO_U8) then obtained^.silence:=128 else obtained^.silence:=0;
obtained^.padding:=0;
obtained^.size:=obtained^.samples*obtained^.channels;
if obtained^.size>sample_buffer_size then
  begin
  result:=size_too_high;
  exit;
  end;

if obtained^.channels=2 then obtained^.oversampled_size:=obtained^.size*4*obtained^.oversample
                       else obtained^.oversampled_size:=obtained^.size*8*obtained^.oversample; //output is always 2 channels
if obtained^.format=AUDIO_S16 then obtained^.size:=obtained^.size * 2;
if obtained^.format=AUDIO_F32 then obtained^.size:=obtained^.size * 4;

// Here the common part ends.
//
// Now we cannot "InitAudio" as it is already init and running
// Instead we will change - only when needed:
//
// - PWM range
// - DMA transfer length

if obtained^.range<>CurrentAudioSpec.range then
  begin
  pwm_ctl:=0;                   // stop PWM
  pwm_rng1:=obtained^.range;    // set a new range
  pwm_rng2:=obtained^.range;
  pwm_ctl:=pwm_ctl_val;         // start PWM
  end;

if obtained^.oversampled_size<>CurrentAudioSpec.oversampled_size then
  begin
  repeat sleep(0) until dma_nextcb=nocache+ctrl2_adr;
  ctrl1_ptr^[3]:=obtained^.oversampled_size;
  repeat sleep(0) until dma_nextcb=nocache+ctrl1_adr;
  ctrl2_ptr^[3]:=obtained^.oversampled_size;
  end;

repeat until working=1;
repeat until working=0;
CurrentAudioSpec:=obtained^;
end;


procedure CloseAudio;

begin

// Stop audio worker thread

//PauseAudio(1);
AudioThread.terminate;
repeat sleep(1) until AudioOn=1;

// ...then switch off DMA...

ctrl1_ptr^[5]:=0;
ctrl2_ptr^[5]:=0;

// up to 8 ms of audio can still reside in the buffer

sleep(20);

// Now disable PWM...

pwm_ctl:=0;

//... and return the memory to the system

dispose(dmabuf1_ptr);
dispose(dmabuf2_ptr);
freemem(dmactrl_ptr);
freemem(samplebuffer_ptr);
end;

procedure pauseaudio(p:integer);

begin
if p=1 then pauseA:=1;
if p=0 then pausea:=0;
end;

procedure SetVolume(vol:single);
// Setting the volume as float in range 0..1

begin
if (vol>=0) and (vol<=1) then volume:=round(vol*4096);
end;

procedure SetVolume(vol:integer);

// Setting the volume as integer in range 0..4096

begin
if (vol>=0) and (vol<=4096) then volume:=vol;
end;

procedure setDBVolume(vol:single);

// Setting decibel volume. This has to be negative number in range ~-72..0)

begin
if (vol<0) and (vol>=-72) then volume:=round(4096*power(10,vol/20));
if vol<-72 then volume:=0;
if vol>=0 then volume:=4096;
end;


function noiseshaper8(bufaddr,outbuf,oversample,len:integer):integer;

label p101,p102,p999,i1l,i1r,i2l,i2r;

// -- rev 20170126

begin
                 asm
                 push {r0-r10,r12,r14}
                 ldr r3,i1l            // init integerators
                 ldr r4,i1r
                 ldr r7,i2l
                 ldr r8,i2r
                 ldr r5,bufaddr        // init buffers addresses
                 ldr r2,outbuf
                 ldr r14,oversample    // yes, lr used here, I am short of regs :(
                 ldr r0,len            // outer loop counter

 p102:           mov r1,r14            // inner loop counter
                 ldr r6,[r5],#4        // new input value left
                 ldr r12,[r5],#4       // new input value right

 p101:           add r3,r6             // inner loop: do oversampling
                 add r4,r12
                 add r7,r3
                 add r8,r4
                 mov r9,r7,asr #20
                 mov r10,r9,lsl #20
                 sub r3,r10
                 sub r7,r10
                 add r9,#1            // kill the negative bug :) :)
                 str r9,[r2],#4
                 mov r9,r8,asr #20
                 mov r10,r9,lsl #20
                 sub r4,r10
                 sub r8,r10
                 add r9,#1
                 str r9,[r2],#4
                 subs r1,#1
                 bne p101
                 subs r0,#1
                 bne p102

                 str r3,i1l
                 str r4,i1r
                 str r7,i2l
                 str r8,i2r
                 str r2,result

                 b p999

i1l:            .long 0
i1r:            .long 0
i2l:            .long 0
i2r:            .long 0

p999:           pop {r0-r10,r12,r14}
                end;

CleanDataCacheRange(outbuf,$10000);
end;

// Audio thread
// After the audio is opened it calls audiocallback when needed


constructor TAudioThread.Create(CreateSuspended : boolean);

begin
FreeOnTerminate := True;
inherited Create(CreateSuspended);
end;



procedure TAudioThread.Execute;

var
    i:integer;
    ns_size:integer;

begin
AudioOn:=1;
ThreadSetCPU(ThreadGetCurrent,CPU_ID_1);
ThreadSetPriority(ThreadGetCurrent,7);
threadsleep(1);
  repeat
  repeat threadsleep(1) until (dma_cs and 2) <>0 ;
  working:=1;
  nc:=dma_nextcb;
  if pauseA>0 then  // clean the buffers
    begin
    if nc=nocache+ctrl1_adr then for i:=0 to 16383 do dmabuf1_ptr[i]:=CurrentAudioSpec.range div 2;
    if nc=nocache+ctrl2_adr then for i:=0 to 16383 do dmabuf2_ptr[i]:=CurrentAudioSpec.range div 2;
    if nc=nocache+ctrl1_adr then CleanDataCacheRange(dmabuf1_adr,$10000);
    if nc=nocache+ctrl2_adr then CleanDataCacheRange(dmabuf2_adr,$10000);
    end
  else
    begin

    // if not pause then we should call audiocallback to fill the buffer

    if CurrentAudioSpec.callback<>nil then CurrentAudioSpec.callback(CurrentAudioSpec.userdata, samplebuffer_ptr, CurrentAudioSpec.size);

    // the buffer has to be converted to 2 chn 32bit integer

    if CurrentAudioSpec.channels=2 then // stereo
      begin
      case CurrentAudioSpec.format of
        AUDIO_U8:  for i:=0 to 2*CurrentAudioSpec.samples-1 do samplebuffer_32_ptr[i]:= volume*256*samplebuffer_ptr_b[i];
        AUDIO_S16: for i:=0 to 2*CurrentAudioSpec.samples-1 do samplebuffer_32_ptr[i]:= volume*samplebuffer_ptr_si[i]+$8000000;
        AUDIO_F32: for i:=0 to 2*CurrentAudioSpec.samples-1 do samplebuffer_32_ptr[i]:= round(volume*32768*samplebuffer_ptr_f[i])+$8000000;
        end;
      end
    else
      begin
      case CurrentAudioSpec.format of
        AUDIO_U8:  for i:=0 to CurrentAudioSpec.samples-1 do begin samplebuffer_32_ptr[2*i]:= volume*256*samplebuffer_ptr_b[i]; samplebuffer_32_ptr[2*i+1]:= samplebuffer_32_ptr[2*i]; end;
        AUDIO_S16: for i:=0 to CurrentAudioSpec.samples-1 do begin samplebuffer_32_ptr[2*i]:= volume*samplebuffer_ptr_si[i]+$8000000; samplebuffer_32_ptr[2*i+1]:= samplebuffer_32_ptr[2*i]; end;
        AUDIO_F32: for i:=0 to CurrentAudioSpec.samples-1 do begin samplebuffer_32_ptr[2*i]:= round(volume*32768*samplebuffer_ptr_f[i])+$8000000; samplebuffer_32_ptr[2*i+1]:= samplebuffer_32_ptr[2*i]; end;
        end;
      end;
    if nc=nocache+ctrl1_adr then noiseshaper8(samplebuffer_32_adr,dmabuf1_adr,CurrentAudioSpec.oversample,CurrentAudioSpec.samples)
    else noiseshaper8(samplebuffer_32_adr,dmabuf2_adr,CurrentAudioSpec.oversample,CurrentAudioSpec.samples);
    if nc=nocache+ctrl1_adr then CleanDataCacheRange(dmabuf1_adr,$10000) else CleanDataCacheRange(dmabuf2_adr,$10000);
    end;
  dma_cs:=$00FF0003;
  working:=0;
  until terminated;
AudioOn:=0;
end;

function  SA_GetCurrentFreq:integer;

begin
result:=CurrentAudioSpec.freq;
end;

function  SA_GetCurrentRange:integer;

begin
result:=CurrentAudioSpec.range;
end;

end.

