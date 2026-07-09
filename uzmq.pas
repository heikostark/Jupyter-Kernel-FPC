unit uZMQ;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DynLibs;

const
  ZMQ_PUB     = 1;
  ZMQ_SUB     = 2;
  ZMQ_REQ     = 3;
  ZMQ_REP     = 4;
  ZMQ_DEALER  = 5;
  ZMQ_ROUTER  = 6;

  ZMQ_RCVMORE = 13;
  ZMQ_SNDMORE = 2;
  ZMQ_POLLIN  = 1;

type
  Pzmq_msg_t = ^zmq_msg_t;
  zmq_msg_t = record
    Opaque: array[0..63] of Byte; // libzmq: unsigned char _[64]
  end;

  zmq_pollitem_t = record
    socket: Pointer;
    fd: LongInt;
    events: SmallInt;
    revents: SmallInt;
  end;

  TFrames = array of RawByteString;

var
  zmq_ctx_new: function(): Pointer; cdecl;
  zmq_ctx_destroy: function(context: Pointer): LongInt; cdecl;
  zmq_socket: function(context: Pointer; type_: LongInt): Pointer; cdecl;
  zmq_close: function(s: Pointer): LongInt; cdecl;
  zmq_bind: function(s: Pointer; addr: PAnsiChar): LongInt; cdecl;
  zmq_connect: function(s: Pointer; addr: PAnsiChar): LongInt; cdecl;
  zmq_setsockopt: function(s: Pointer; option_name: LongInt; option_value: Pointer; option_len: PtrUInt): LongInt; cdecl;
  zmq_getsockopt: function(s: Pointer; option_name: LongInt; option_value: Pointer; option_len: PPtrUInt): LongInt; cdecl;
  zmq_msg_init: function(msg: Pzmq_msg_t): LongInt; cdecl;
  zmq_msg_init_size: function(msg: Pzmq_msg_t; size: PtrUInt): LongInt; cdecl;
  zmq_msg_data: function(msg: Pzmq_msg_t): Pointer; cdecl;
  zmq_msg_size: function(msg: Pzmq_msg_t): PtrUInt; cdecl;
  zmq_msg_close: function(msg: Pzmq_msg_t): LongInt; cdecl;
  zmq_msg_send: function(msg: Pzmq_msg_t; s: Pointer; flags: LongInt): LongInt; cdecl;
  zmq_msg_recv: function(msg: Pzmq_msg_t; s: Pointer; flags: LongInt): LongInt; cdecl;
  zmq_poll: function(items: Pointer; nitems: LongInt; timeout: LongInt): LongInt; cdecl;
  zmq_errno: function(): LongInt; cdecl;
  zmq_strerror: function(errnum: LongInt): PAnsiChar; cdecl;

function LoadZMQ(const LibName: string = ''): Boolean;
function RecvMultipart(sock: Pointer): TFrames;
procedure SendMultipart(sock: Pointer; const Frames: array of RawByteString);

implementation

var
  hLib: TLibHandle = NilHandle;

function LoadZMQ(const LibName: string): Boolean;
var
  Names: array of string;
  i: Integer;
begin
  Result := False;
  if LibName <> '' then
  begin
    SetLength(Names, 1);
    Names[0] := LibName;
  end
  else
  begin
    SetLength(Names, 5);
    Names[0] := 'libzmq.so.5';
    Names[1] := 'libzmq.so';
    Names[2] := 'libzmq.5.dylib';
    Names[3] := 'libzmq.dylib';
    Names[4] := 'libzmq.dll';
  end;

  hLib := NilHandle;
  for i := 0 to High(Names) do
  begin
    hLib := LoadLibrary(Names[i]);
    if hLib <> NilHandle then Break;
  end;
  if hLib = NilHandle then Exit;

  Pointer(zmq_ctx_new)      := GetProcedureAddress(hLib, 'zmq_ctx_new');
  Pointer(zmq_ctx_destroy)  := GetProcedureAddress(hLib, 'zmq_ctx_destroy');
  Pointer(zmq_socket)       := GetProcedureAddress(hLib, 'zmq_socket');
  Pointer(zmq_close)        := GetProcedureAddress(hLib, 'zmq_close');
  Pointer(zmq_bind)         := GetProcedureAddress(hLib, 'zmq_bind');
  Pointer(zmq_connect)      := GetProcedureAddress(hLib, 'zmq_connect');
  Pointer(zmq_setsockopt)   := GetProcedureAddress(hLib, 'zmq_setsockopt');
  Pointer(zmq_getsockopt)   := GetProcedureAddress(hLib, 'zmq_getsockopt');
  Pointer(zmq_msg_init)     := GetProcedureAddress(hLib, 'zmq_msg_init');
  Pointer(zmq_msg_init_size):= GetProcedureAddress(hLib, 'zmq_msg_init_size');
  Pointer(zmq_msg_data)     := GetProcedureAddress(hLib, 'zmq_msg_data');
  Pointer(zmq_msg_size)     := GetProcedureAddress(hLib, 'zmq_msg_size');
  Pointer(zmq_msg_close)    := GetProcedureAddress(hLib, 'zmq_msg_close');
  Pointer(zmq_msg_send)     := GetProcedureAddress(hLib, 'zmq_msg_send');
  Pointer(zmq_msg_recv)     := GetProcedureAddress(hLib, 'zmq_msg_recv');
  Pointer(zmq_poll)         := GetProcedureAddress(hLib, 'zmq_poll');
  Pointer(zmq_errno)        := GetProcedureAddress(hLib, 'zmq_errno');
  Pointer(zmq_strerror)     := GetProcedureAddress(hLib, 'zmq_strerror');

  Result := Assigned(zmq_ctx_new) and Assigned(zmq_socket) and Assigned(zmq_bind)
        and Assigned(zmq_msg_send) and Assigned(zmq_msg_recv) and Assigned(zmq_poll);
end;

function RecvMultipart(sock: Pointer): TFrames;
var
  msg: zmq_msg_t;
  more: LongInt;
  moreSize: PtrUInt;
  Data: RawByteString;
  n: Integer;
begin
  SetLength(Result, 0);
  repeat
    zmq_msg_init(@msg);
    if zmq_msg_recv(@msg, sock, 0) < 0 then
    begin
      zmq_msg_close(@msg);
      Break;
    end;
    SetLength(Data, zmq_msg_size(@msg));
    if Length(Data) > 0 then
      Move(zmq_msg_data(@msg)^, Data[1], Length(Data));
    zmq_msg_close(@msg);

    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n] := Data;

    more := 0;
    moreSize := SizeOf(more);
    zmq_getsockopt(sock, ZMQ_RCVMORE, @more, @moreSize);
  until more = 0;
end;

procedure SendMultipart(sock: Pointer; const Frames: array of RawByteString);
var
  i: Integer;
  msg: zmq_msg_t;
  flags: LongInt;
begin
  for i := 0 to High(Frames) do
  begin
    if i < High(Frames) then
      flags := ZMQ_SNDMORE
    else
      flags := 0;
    zmq_msg_init_size(@msg, Length(Frames[i]));
    if Length(Frames[i]) > 0 then
      Move(Frames[i][1], zmq_msg_data(@msg)^, Length(Frames[i]));
    zmq_msg_send(@msg, sock, flags);
  end;
end;

end.
