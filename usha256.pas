unit uSHA256;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSHA256Digest = array[0..31] of Byte;

function SHA256Buf(const Data; Len: PtrInt): TSHA256Digest;
function SHA256Str(const Data: RawByteString): TSHA256Digest;
function SHA256Hex(const Digest: TSHA256Digest): string;
function HMACSHA256(const Key, Data: RawByteString): TSHA256Digest;
function HMACSHA256Hex(const Key, Data: RawByteString): string;

implementation

const
  K: array[0..63] of LongWord = (
    $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
    $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
    $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
    $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
    $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
    $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
    $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
    $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2
  );

function RotR(x: LongWord; n: Byte): LongWord; inline;
begin
  RotR := (x shr n) or (x shl (32 - n));
end;

function SHA256Buf(const Data; Len: PtrInt): TSHA256Digest;
var
  Hs: array[0..7] of LongWord;
  Msg: array of Byte;
  MsgLen, ChunkCount, i, j: PtrInt;
  W: array[0..63] of LongWord;
  a, b, c, d, e, f, g, h, T1, T2, sm0, sm1, bs0, bs1, ch, maj: LongWord;
  BitLen: QWord;
  p: PByte;
begin
  Hs[0] := $6a09e667; Hs[1] := $bb67ae85; Hs[2] := $3c6ef372; Hs[3] := $a54ff53a;
  Hs[4] := $510e527f; Hs[5] := $9b05688c; Hs[6] := $1f83d9ab; Hs[7] := $5be0cd19;

  MsgLen := Len;
  ChunkCount := ((MsgLen + 8) div 64) + 1;
  SetLength(Msg, ChunkCount * 64);
  FillChar(Msg[0], Length(Msg), 0);
  if MsgLen > 0 then
    Move(Data, Msg[0], MsgLen);
  Msg[MsgLen] := $80;

  BitLen := QWord(MsgLen) * 8;
  for i := 0 to 7 do
    Msg[Length(Msg) - 1 - i] := Byte(BitLen shr (i * 8));

  p := @Msg[0];
  for j := 0 to ChunkCount - 1 do
  begin
    for i := 0 to 15 do
      W[i] := (LongWord(p[j*64 + i*4]) shl 24) or (LongWord(p[j*64 + i*4 + 1]) shl 16)
              or (LongWord(p[j*64 + i*4 + 2]) shl 8) or LongWord(p[j*64 + i*4 + 3]);

    for i := 16 to 63 do
    begin
      sm0 := RotR(W[i-15], 7) xor RotR(W[i-15], 18) xor (W[i-15] shr 3);
      sm1 := RotR(W[i-2], 17) xor RotR(W[i-2], 19) xor (W[i-2] shr 10);
      W[i] := W[i-16] + sm0 + W[i-7] + sm1;
    end;

    a := Hs[0]; b := Hs[1]; c := Hs[2]; d := Hs[3];
    e := Hs[4]; f := Hs[5]; g := Hs[6]; h := Hs[7];

    for i := 0 to 63 do
    begin
      bs1 := RotR(e, 6) xor RotR(e, 11) xor RotR(e, 25);
      ch := (e and f) xor ((not e) and g);
      T1 := h + bs1 + ch + K[i] + W[i];
      bs0 := RotR(a, 2) xor RotR(a, 13) xor RotR(a, 22);
      maj := (a and b) xor (a and c) xor (b and c);
      T2 := bs0 + maj;
      h := g; g := f; f := e; e := d + T1;
      d := c; c := b; b := a; a := T1 + T2;
    end;

    Inc(Hs[0], a); Inc(Hs[1], b); Inc(Hs[2], c); Inc(Hs[3], d);
    Inc(Hs[4], e); Inc(Hs[5], f); Inc(Hs[6], g); Inc(Hs[7], h);
  end;

  for i := 0 to 7 do
  begin
    Result[i*4]     := Byte(Hs[i] shr 24);
    Result[i*4 + 1] := Byte(Hs[i] shr 16);
    Result[i*4 + 2] := Byte(Hs[i] shr 8);
    Result[i*4 + 3] := Byte(Hs[i]);
  end;
end;

function SHA256Str(const Data: RawByteString): TSHA256Digest;
var
  dummy: Byte;
begin
  if Length(Data) = 0 then
    Result := SHA256Buf(dummy, 0)
  else
    Result := SHA256Buf(Data[1], Length(Data));
end;

function SHA256Hex(const Digest: TSHA256Digest): string;
const
  HexChars: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, 64);
  for i := 0 to 31 do
  begin
    Result[i*2 + 1] := HexChars[Digest[i] shr 4];
    Result[i*2 + 2] := HexChars[Digest[i] and $0F];
  end;
end;

function HMACSHA256(const Key, Data: RawByteString): TSHA256Digest;
const
  BlockSize = 64;
var
  K0: array[0..BlockSize-1] of Byte;
  IPad, OPad: array[0..BlockSize-1] of Byte;
  i: Integer;
  KeyDigest, InnerHash: TSHA256Digest;
  Buf: array of Byte;
begin
  FillChar(K0, SizeOf(K0), 0);
  if Length(Key) > BlockSize then
  begin
    KeyDigest := SHA256Str(Key);
    Move(KeyDigest[0], K0[0], 32);
  end
  else if Length(Key) > 0 then
    Move(Key[1], K0[0], Length(Key));

  for i := 0 to BlockSize - 1 do
  begin
    IPad[i] := K0[i] xor $36;
    OPad[i] := K0[i] xor $5C;
  end;

  SetLength(Buf, BlockSize + Length(Data));
  Move(IPad[0], Buf[0], BlockSize);
  if Length(Data) > 0 then
    Move(Data[1], Buf[BlockSize], Length(Data));
  InnerHash := SHA256Buf(Buf[0], Length(Buf));

  SetLength(Buf, BlockSize + 32);
  Move(OPad[0], Buf[0], BlockSize);
  Move(InnerHash[0], Buf[BlockSize], 32);
  Result := SHA256Buf(Buf[0], Length(Buf));
end;

function HMACSHA256Hex(const Key, Data: RawByteString): string;
begin
  Result := SHA256Hex(HMACSHA256(Key, Data));
end;

end.
