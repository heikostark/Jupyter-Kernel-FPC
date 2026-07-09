program pascalkernel;

{ Ein einfacher Jupyter/IPython-Kernel fuer Free Pascal.
  Er implementiert das Jupyter-Messaging-Protokoll (v5.3) direkt ueber
  ZeroMQ und fuehrt Code-Zellen aus, indem er sie mit "fpc" kompiliert
  und das Ergebnis ausfuehrt. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes, Process, DateUtils, fpjson, jsonparser, base64,
  uZMQ, uSHA256;

var
  ConnJSON: TJSONObject;
  Transport, IPAddr, HmacKey, SigScheme: string;
  ShellPort, IOPubPort, StdinPort, ControlPort, HBPort: Integer;
  Ctx, ShellSock, IOPubSock, StdinSock, ControlSock, HBSock: Pointer;
  SessionID: string;
  ExecCount: Integer;
  { PID des Kindprozesses (fpc-Compiler oder ausgefuehrtes Programm), der
    gerade laeuft - wird vom SIGINT-Handler genutzt, um NUR die aktuelle
    Zelle abzubrechen, statt den ganzen Kernel zu beenden. -1 = kein
    Kindprozess aktiv. }
  CurrentChildPID: {$IFDEF UNIX}TPid{$ELSE}Integer{$ENDIF} = -1;

type
  TMsg = record
    Identities: TFrames;
    Header, Parent, Metadata, Content: TJSONObject;
    MsgType: string;
  end;

{ ---------- Hilfsfunktionen ---------- }

function NewUUID: string;
var
  b: array[0..15] of Byte;
  i: Integer;
begin
  for i := 0 to 15 do
    b[i] := Random(256);
  b[6] := (b[6] and $0F) or $40;
  b[8] := (b[8] and $3F) or $80;
  Result :=
    LowerCase(HexStr(b[0],2)+HexStr(b[1],2)+HexStr(b[2],2)+HexStr(b[3],2)) + '-' +
    LowerCase(HexStr(b[4],2)+HexStr(b[5],2)) + '-' +
    LowerCase(HexStr(b[6],2)+HexStr(b[7],2)) + '-' +
    LowerCase(HexStr(b[8],2)+HexStr(b[9],2)) + '-' +
    LowerCase(HexStr(b[10],2)+HexStr(b[11],2)+HexStr(b[12],2)+HexStr(b[13],2)+HexStr(b[14],2)+HexStr(b[15],2));
end;

function NowISO8601: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', LocalTimeToUniversal(Now));
end;

function GetFPCVersion: string;
var
  P: TProcess;
  SL: TStringList;
begin
  Result := 'unbekannt';
  P := TProcess.Create(nil);
  SL := TStringList.Create;
  try
    P.Executable := 'fpc';
    P.Parameters.Add('-iV');
    P.Options := [poUsePipes, poWaitOnExit, poStderrToOutPut];
    try
      P.Execute;
      SL.LoadFromStream(P.Output);
      if SL.Count > 0 then
        Result := Trim(SL[0]);
    except
      // fpc evtl. nicht gefunden - Standardwert behalten
    end;
  finally
    SL.Free;
    P.Free;
  end;
end;

{ Fuehrt Exe mit Args aus und liefert den kombinierten stdout/stderr-Text
  sowie den Exitcode zurueck. WorkDir (falls angegeben) wird als aktuelles
  Arbeitsverzeichnis des Kindprozesses gesetzt - das erlaubt es dem
  ausgefuehrten Programm, Dateien (Bilder, HTML, ...) dort abzulegen. }
function RunProcess(const Exe: string; const Args: array of string;
  const WorkDir: string; out Output: string): Integer;
var
  P: TProcess;
  MS: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N, i: Integer;
begin
  P := TProcess.Create(nil);
  MS := TMemoryStream.Create;
  try
    P.Executable := Exe;
    for i := 0 to High(Args) do
      P.Parameters.Add(Args[i]);
    if WorkDir <> '' then
      P.CurrentDirectory := WorkDir;
    P.Options := [poUsePipes, poStderrToOutPut];
    try
      P.Execute;
      CurrentChildPID := P.ProcessID;
    except
      on E: Exception do
      begin
        Output := 'Konnte "' + Exe + '" nicht ausfuehren: ' + E.Message;
        Result := -1;
        Exit;
      end;
    end;

    repeat
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
        MS.Write(Buf, N);
    until (N <= 0) and (not P.Running);
    repeat
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
        MS.Write(Buf, N);
    until N <= 0;

    P.WaitOnExit;
    Result := P.ExitStatus;
    CurrentChildPID := -1;

    MS.Position := 0;
    SetLength(Output, MS.Size);
    if MS.Size > 0 then
      MS.ReadBuffer(Output[1], MS.Size);
  finally
    CurrentChildPID := -1;
    MS.Free;
    P.Free;
  end;
end;

{$IFDEF UNIX}
{ Wird aufgerufen, wenn JupyterLab/Jupyter "Interrupt Kernel" ausloest
  (per SIGINT an die Prozessgruppe). Der Handler beendet NUR den gerade
  laufenden Kindprozess (fpc-Compiler oder ausgefuehrtes Programm), falls
  einer aktiv ist - der Kernel selbst laeuft danach normal weiter und ist
  bereit fuer die naechste Zelle. Ist gerade nichts aktiv, passiert nichts. }
procedure SigIntHandler(Sig: LongInt); cdecl;
begin
  if CurrentChildPID > 0 then
    fpKill(CurrentChildPID, SIGTERM);
end;

procedure InstallSignalHandlers;
begin
  fpSignal(SIGINT, TSignalHandler(@SigIntHandler));
end;
{$ENDIF}

{ ---------- Rich-Output: Bilder/HTML, die das ausgefuehrte Programm erzeugt ---------- }

{ Ordnet einer Dateiendung einen Jupyter-MIME-Typ zu. Leerstring = wird
  ignoriert (kein bekannter/anzeigbarer Typ). Diese Zuordnung ist bewusst
  generisch gehalten: sie haengt nicht am Compiler/Interpreter, sondern
  greift fuer jede Datei, die ein ausgefuehrtes Programm im Arbeitsverzeichnis
  hinterlaesst - egal ob sie mit fpc, einem externen Tool oder von Hand
  erzeugt wurde. }
function GuessMimeType(const Ext: string): string;
var
  E: string;
begin
  E := LowerCase(Ext);
  if E = '.png' then Result := 'image/png'
  else if (E = '.jpg') or (E = '.jpeg') then Result := 'image/jpeg'
  else if E = '.gif' then Result := 'image/gif'
  else if E = '.bmp' then Result := 'image/bmp'
  else if E = '.svg' then Result := 'image/svg+xml'
  else if (E = '.html') or (E = '.htm') then Result := 'text/html'
  else Result := '';
end;

function IsTextMime(const Mime: string): Boolean;
begin
  Result := (Mime = 'image/svg+xml') or (Mime = 'text/html');
end;

{ Loescht alle Dateien in Dir (nicht rekursiv) und entfernt Dir selbst. }
procedure CleanupDir(const Dir: string);
var
  Info: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Name <> '.') and (Info.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(Dir) + Info.Name);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  RemoveDir(Dir);
end;

{ ---------- Auto-Vervollstaendigung ---------- }

const
  PascalKeywords: array[0..49] of string = (
    'and','array','as','asm','begin','case','class','const','constructor',
    'destructor','div','do','downto','else','end','except','exports','file',
    'finalization','finally','for','function','goto','if','implementation',
    'in','inherited','initialization','inline','interface','is','label',
    'library','mod','nil','not','object','of','or','out','packed',
    'procedure','program','property','record','repeat','then','to','type',
    'unit'
  );
  PascalBuiltins: array[0..44] of string = (
    'WriteLn','Write','ReadLn','Read','Integer','String','Boolean','Real',
    'Char','Byte','Word','LongInt','Int64','QWord','Double','Single',
    'TStringList','TStrings','TObject','Exception','SysUtils','Classes',
    'Length','Copy','Pos','UpperCase','LowerCase','Trim','IntToStr',
    'StrToInt','FloatToStr','StrToFloat','Format','FormatFloat','Random',
    'Randomize','Sqrt','Abs','Round','Trunc','Ord','Chr','Inc','Dec',
    'SetLength'
  );

function IsIdentChar(C: Char): Boolean; inline;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_'];
end;

function IsIdentStartChar(C: Char): Boolean; inline;
begin
  Result := C in ['A'..'Z', 'a'..'z', '_'];
end;

{ Sammelt alle im Code bereits vorkommenden Bezeichner (Variablen-, Typ-,
  Prozedurnamen usw.), damit auch selbstdefinierte Namen vervollstaendigt
  werden koennen - nicht nur feste Schluesselwoerter. }
procedure CollectIdentifiers(const Code: string; Target: TStringList);
var
  i, Start: Integer;
begin
  i := 1;
  while i <= Length(Code) do
  begin
    if IsIdentStartChar(Code[i]) then
    begin
      Start := i;
      while (i <= Length(Code)) and IsIdentChar(Code[i]) do
        Inc(i);
      Target.Add(Copy(Code, Start, i - Start));
    end
    else
      Inc(i);
  end;
end;



procedure LoadConnectionFile(const Path: string);
var
  SL: TStringList;
  Data: TJSONData;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(Path);
    Data := GetJSON(SL.Text);
    if not (Data is TJSONObject) then
      raise Exception.Create('Ungueltige Connection-Datei');
    ConnJSON := TJSONObject(Data);
  finally
    SL.Free;
  end;
  Transport   := ConnJSON.Get('transport', 'tcp');
  IPAddr      := ConnJSON.Get('ip', '127.0.0.1');
  HmacKey     := ConnJSON.Get('key', '');
  SigScheme   := ConnJSON.Get('signature_scheme', 'hmac-sha256');
  ShellPort   := ConnJSON.Get('shell_port', 0);
  IOPubPort   := ConnJSON.Get('iopub_port', 0);
  StdinPort   := ConnJSON.Get('stdin_port', 0);
  ControlPort := ConnJSON.Get('control_port', 0);
  HBPort      := ConnJSON.Get('hb_port', 0);
end;

function Addr(Port: Integer): string;
begin
  Result := Format('%s://%s:%d', [Transport, IPAddr, Port]);
end;

procedure SetupSockets;
begin
  Ctx := zmq_ctx_new();

  ShellSock := zmq_socket(Ctx, ZMQ_ROUTER);
  zmq_bind(ShellSock, PAnsiChar(Addr(ShellPort)));

  ControlSock := zmq_socket(Ctx, ZMQ_ROUTER);
  zmq_bind(ControlSock, PAnsiChar(Addr(ControlPort)));

  IOPubSock := zmq_socket(Ctx, ZMQ_PUB);
  zmq_bind(IOPubSock, PAnsiChar(Addr(IOPubPort)));

  StdinSock := zmq_socket(Ctx, ZMQ_ROUTER);
  zmq_bind(StdinSock, PAnsiChar(Addr(StdinPort)));

  HBSock := zmq_socket(Ctx, ZMQ_REP);
  zmq_bind(HBSock, PAnsiChar(Addr(HBPort)));
end;

{ ---------- Heartbeat ---------- }

function HeartbeatThread(P: Pointer): PtrInt;
var
  Frames: TFrames;
begin
  while True do
  begin
    Frames := RecvMultipart(HBSock);
    if Length(Frames) > 0 then
      SendMultipart(HBSock, Frames);
  end;
  Result := 0;
end;

{ ---------- Nachrichten empfangen/senden ---------- }

function RecvMsg(Sock: Pointer; out Msg: TMsg): Boolean;
var
  Frames: TFrames;
  DelimIdx, i: Integer;
  HeaderStr, ParentStr, MetaStr, ContentStr, Sig, CalcSig: string;
begin
  Result := False;
  Frames := RecvMultipart(Sock);
  if Length(Frames) = 0 then Exit;

  DelimIdx := -1;
  for i := 0 to High(Frames) do
    if Frames[i] = '<IDS|MSG>' then
    begin
      DelimIdx := i;
      Break;
    end;
  if (DelimIdx < 0) or (DelimIdx + 5 > High(Frames)) then Exit;

  SetLength(Msg.Identities, DelimIdx);
  for i := 0 to DelimIdx - 1 do
    Msg.Identities[i] := Frames[i];

  Sig        := Frames[DelimIdx + 1];
  HeaderStr  := Frames[DelimIdx + 2];
  ParentStr  := Frames[DelimIdx + 3];
  MetaStr    := Frames[DelimIdx + 4];
  ContentStr := Frames[DelimIdx + 5];

  if HmacKey <> '' then
  begin
    CalcSig := HMACSHA256Hex(HmacKey, HeaderStr + ParentStr + MetaStr + ContentStr);
    if LowerCase(CalcSig) <> LowerCase(Sig) then
      WriteLn(StdErr, 'Warnung: Signatur stimmt nicht ueberein (ignoriert).');
  end;

  Msg.Header := TJSONObject(GetJSON(HeaderStr));
  if Trim(ParentStr) <> '' then
    Msg.Parent := TJSONObject(GetJSON(ParentStr))
  else
    Msg.Parent := TJSONObject.Create;
  if Trim(MetaStr) <> '' then
    Msg.Metadata := TJSONObject(GetJSON(MetaStr))
  else
    Msg.Metadata := TJSONObject.Create;
  Msg.Content := TJSONObject(GetJSON(ContentStr));
  Msg.MsgType := Msg.Header.Get('msg_type', '');
  Result := True;
end;

procedure SendMsg(Sock: Pointer; const Identities: TFrames; const MsgType: string;
  const Parent, Content: TJSONObject);
var
  Header: TJSONObject;
  HeaderStr, ParentStr, MetaStr, ContentStr, Sig: string;
  Frames: TFrames;
  i, Base: Integer;
begin
  Header := TJSONObject.Create;
  try
    Header.Add('msg_id', NewUUID);
    Header.Add('session', SessionID);
    Header.Add('username', 'kernel');
    Header.Add('date', NowISO8601);
    Header.Add('msg_type', MsgType);
    Header.Add('version', '5.3');
    HeaderStr := Header.AsJSON;
  finally
    Header.Free;
  end;

  if Assigned(Parent) then
    ParentStr := Parent.AsJSON
  else
    ParentStr := '{}';

  MetaStr := '{}';

  if Assigned(Content) then
    ContentStr := Content.AsJSON
  else
    ContentStr := '{}';

  if HmacKey <> '' then
    Sig := HMACSHA256Hex(HmacKey, HeaderStr + ParentStr + MetaStr + ContentStr)
  else
    Sig := '';

  Base := Length(Identities);
  SetLength(Frames, Base + 6);
  for i := 0 to Base - 1 do
    Frames[i] := Identities[i];
  Frames[Base]     := '<IDS|MSG>';
  Frames[Base + 1] := Sig;
  Frames[Base + 2] := HeaderStr;
  Frames[Base + 3] := ParentStr;
  Frames[Base + 4] := MetaStr;
  Frames[Base + 5] := ContentStr;

  SendMultipart(Sock, Frames);
end;

function TopicFrame(const Topic: string): TFrames;
begin
  SetLength(Result, 1);
  Result[0] := Topic;
end;

procedure SendStatus(const Parent: TJSONObject; const State: string);
var
  C: TJSONObject;
begin
  C := TJSONObject.Create;
  try
    C.Add('execution_state', State);
    SendMsg(IOPubSock, TopicFrame('status'), 'status', Parent, C);
  finally
    C.Free;
  end;
end;

{ Liest eine Datei ein und veroeffentlicht sie als "display_data"-Nachricht
  auf dem iopub-Socket - Bilder/SVG/HTML werden so im Notebook direkt neben
  dem Text angezeigt. }
procedure PublishFile(const Parent: TJSONObject; const FilePath: string);
var
  Mime: string;
  Content, DataObj, MetaObj: TJSONObject;
  FS: TFileStream;
  RawBytes: RawByteString;
begin
  Mime := GuessMimeType(ExtractFileExt(FilePath));
  if Mime = '' then Exit;

  try
    FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(RawBytes, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(RawBytes[1], FS.Size);
    finally
      FS.Free;
    end;
  except
    Exit; // Datei evtl. inzwischen geloescht o.ae. - einfach ignorieren
  end;

  DataObj := TJSONObject.Create;
  if IsTextMime(Mime) then
    DataObj.Add(Mime, RawBytes)
  else
    DataObj.Add(Mime, EncodeStringBase64(RawBytes));
  DataObj.Add('text/plain', Format('<Ausgabedatei: %s>', [ExtractFileName(FilePath)]));

  Content := TJSONObject.Create;
  try
    Content.Add('data', DataObj);
    MetaObj := TJSONObject.Create;
    Content.Add('metadata', MetaObj);
    SendMsg(IOPubSock, TopicFrame('display_data'), 'display_data', Parent, Content);
  finally
    Content.Free; // gibt DataObj und MetaObj mit frei
  end;
end;

{ Durchsucht Dir nach Dateien mit anzeigbarem MIME-Typ (siehe GuessMimeType)
  und veroeffentlicht jede davon. ExcludeFiles (z.B. Quelltext/Binary)
  werden uebersprungen. }
procedure PublishGeneratedFiles(const Parent: TJSONObject; const Dir: string;
  const ExcludeFiles: array of string);
var
  Info: TSearchRec;
  Skip: Boolean;
  i: Integer;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Name = '.') or (Info.Name = '..') then Continue;
      Skip := False;
      for i := 0 to High(ExcludeFiles) do
        if SameFileName(Info.Name, ExcludeFiles[i]) then
        begin
          Skip := True;
          Break;
        end;
      if not Skip then
        PublishFile(Parent, IncludeTrailingPathDelimiter(Dir) + Info.Name);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
end;

{ ---------- Nachrichtentypen behandeln ---------- }

procedure HandleKernelInfo(const Msg: TMsg);
var
  Content, LangInfo: TJSONObject;
begin
  Content := TJSONObject.Create;
  try
    Content.Add('status', 'ok');
    Content.Add('protocol_version', '5.3');
    Content.Add('implementation', 'freepascal_kernel');
    Content.Add('implementation_version', '0.1.0');

    LangInfo := TJSONObject.Create;
    LangInfo.Add('name', 'pascal');
    LangInfo.Add('version', GetFPCVersion);
    LangInfo.Add('mimetype', 'text/x-pascal');
    LangInfo.Add('file_extension', '.pas');
    Content.Add('language_info', LangInfo);

    Content.Add('banner',
      'Free Pascal Kernel fuer Jupyter'#10 +
      'Kompiliert jede Code-Zelle mit "fpc" und fuehrt das Ergebnis aus.'#10 +
      'Dateien (PNG/JPG/GIF/BMP/SVG/HTML), die das Programm erzeugt, werden '#10 +
      'automatisch als Bild/HTML im Notebook angezeigt. Tab-Vervollstaendigung '#10 +
      'fuer Schluesselwoerter, Standardbezeichner und im Code verwendete Namen '#10 +
      'wird unterstuetzt.');

    SendMsg(ShellSock, Msg.Identities, 'kernel_info_reply', Msg.Header, Content);
  finally
    Content.Free;
  end;
end;

procedure HandleIsComplete(const Msg: TMsg);
var
  Content: TJSONObject;
begin
  Content := TJSONObject.Create;
  try
    Content.Add('status', 'complete');
    SendMsg(ShellSock, Msg.Identities, 'is_complete_reply', Msg.Header, Content);
  finally
    Content.Free;
  end;
end;

procedure HandleComplete(const Msg: TMsg);
var
  Code, Prefix, W: string;
  CursorPos, StartPos, i: Integer;
  Matches, IdentList: TStringList;
  Content, MetaObj: TJSONObject;
  MatchArr: TJSONArray;
begin
  Code := Msg.Content.Get('code', '');
  CursorPos := Msg.Content.Get('cursor_pos', Length(Code));
  if CursorPos > Length(Code) then CursorPos := Length(Code);
  if CursorPos < 0 then CursorPos := 0;

  { Jupyter zaehlt cursor_pos als Anzahl der Zeichen vor dem Cursor;
    das entspricht in einem 1-basierten Pascal-String direkt dem Index
    des letzten Zeichens vor dem Cursor. }
  StartPos := CursorPos;
  while (StartPos > 0) and IsIdentChar(Code[StartPos]) do
    Dec(StartPos);
  Prefix := Copy(Code, StartPos + 1, CursorPos - StartPos);

  Matches := TStringList.Create;
  Matches.Sorted := True;
  Matches.Duplicates := dupIgnore;
  Matches.CaseSensitive := False;
  try
    if Prefix <> '' then
    begin
      for i := 0 to High(PascalKeywords) do
        if Pos(LowerCase(Prefix), LowerCase(PascalKeywords[i])) = 1 then
          Matches.Add(PascalKeywords[i]);
      for i := 0 to High(PascalBuiltins) do
        if Pos(LowerCase(Prefix), LowerCase(PascalBuiltins[i])) = 1 then
          Matches.Add(PascalBuiltins[i]);

      { zusaetzlich: Bezeichner, die im aktuellen Code bereits auftauchen }
      IdentList := TStringList.Create;
      try
        CollectIdentifiers(Code, IdentList);
        for i := 0 to IdentList.Count - 1 do
        begin
          W := IdentList[i];
          if (CompareText(W, Prefix) <> 0) and (Pos(LowerCase(Prefix), LowerCase(W)) = 1) then
            Matches.Add(W);
        end;
      finally
        IdentList.Free;
      end;
    end;

    Content := TJSONObject.Create;
    try
      MatchArr := TJSONArray.Create;
      for i := 0 to Matches.Count - 1 do
        MatchArr.Add(Matches[i]);
      Content.Add('matches', MatchArr);
      Content.Add('cursor_start', StartPos);
      Content.Add('cursor_end', CursorPos);
      MetaObj := TJSONObject.Create;
      Content.Add('metadata', MetaObj);
      Content.Add('status', 'ok');
      SendMsg(ShellSock, Msg.Identities, 'complete_reply', Msg.Header, Content);
    finally
      Content.Free;
    end;
  finally
    Matches.Free;
  end;
end;

procedure HandleExecute(const Msg: TMsg);
var
  Code, TmpDir, SrcFile, ExeFile, CompileOut, RunOut: string;
  CompileRes, RunRes: Integer;
  EIC, StreamC, ErrC, ReplyC: TJSONObject;
  TB: TJSONArray;
begin
  Code := Msg.Content.Get('code', '');
  Inc(ExecCount);

  EIC := TJSONObject.Create;
  try
    EIC.Add('code', Code);
    EIC.Add('execution_count', ExecCount);
    SendMsg(IOPubSock, TopicFrame('execute_input'), 'execute_input', Msg.Header, EIC);
  finally
    EIC.Free;
  end;

  TmpDir := IncludeTrailingPathDelimiter(GetTempDir(False) + 'pask_' + IntToStr(Random(MaxInt)));
  CreateDir(TmpDir);
  SrcFile := TmpDir + 'prog.pas';
  ExeFile := TmpDir + 'prog';

  with TStringList.Create do
  try
    Text := Code;
    SaveToFile(SrcFile);
  finally
    Free;
  end;

  CompileRes := RunProcess('fpc', ['-O2', '-Fu~/fpcupdeluxe/fpc/units/x86_64-linux/rtl/', '-v0', '-Sew', '-o' + ExeFile, SrcFile], '', CompileOut);

  if CompileRes <> 0 then
  begin
    StreamC := TJSONObject.Create;
    try
      StreamC.Add('name', 'stderr');
      StreamC.Add('text', CompileOut);
      SendMsg(IOPubSock, TopicFrame('stream'), 'stream', Msg.Header, StreamC);
    finally
      StreamC.Free;
    end;

    ErrC := TJSONObject.Create;
    try
      ErrC.Add('ename', 'CompileError');
      ErrC.Add('evalue', 'Kompilierung fehlgeschlagen');
      TB := TJSONArray.Create;
      TB.Add(CompileOut);
      ErrC.Add('traceback', TB);
      SendMsg(IOPubSock, TopicFrame('error'), 'error', Msg.Header, ErrC);
    finally
      ErrC.Free;
    end;

    ReplyC := TJSONObject.Create;
    try
      ReplyC.Add('status', 'error');
      ReplyC.Add('execution_count', ExecCount);
      ReplyC.Add('ename', 'CompileError');
      ReplyC.Add('evalue', 'Kompilierung fehlgeschlagen');
      TB := TJSONArray.Create;
      TB.Add(CompileOut);
      ReplyC.Add('traceback', TB);
      SendMsg(ShellSock, Msg.Identities, 'execute_reply', Msg.Header, ReplyC);
    finally
      ReplyC.Free;
    end;
  end
  else
  begin
    RunRes := RunProcess(ExeFile, [], TmpDir, RunOut);

    if RunOut <> '' then
    begin
      StreamC := TJSONObject.Create;
      try
        StreamC.Add('name', 'stdout');
        StreamC.Add('text', RunOut);
        SendMsg(IOPubSock, TopicFrame('stream'), 'stream', Msg.Header, StreamC);
      finally
        StreamC.Free;
      end;
    end;

    { Generisches Rich-Output: alle Dateien, die das Programm im
      Arbeitsverzeichnis abgelegt hat und die einen bekannten
      MIME-Typ haben (Bilder, SVG, HTML), werden als display_data
      veroeffentlicht - unabhaengig davon, wie sie erzeugt wurden. }
    PublishGeneratedFiles(Msg.Header, TmpDir, ['prog.pas', 'prog']);

    if RunRes <> 0 then
    begin
      StreamC := TJSONObject.Create;
      try
        StreamC.Add('name', 'stderr');
        StreamC.Add('text', Format('[Programm beendet mit Exitcode %d]', [RunRes]));
        SendMsg(IOPubSock, TopicFrame('stream'), 'stream', Msg.Header, StreamC);
      finally
        StreamC.Free;
      end;
    end;

    ReplyC := TJSONObject.Create;
    try
      ReplyC.Add('status', 'ok');
      ReplyC.Add('execution_count', ExecCount);
      ReplyC.Add('user_expressions', TJSONObject.Create);
      SendMsg(ShellSock, Msg.Identities, 'execute_reply', Msg.Header, ReplyC);
    finally
      ReplyC.Free;
    end;
  end;

  CleanupDir(TmpDir);
end;

procedure HandleShutdown(const Msg: TMsg);
var
  Content: TJSONObject;
begin
  Content := TJSONObject.Create;
  try
    Content.Add('restart', Msg.Content.Get('restart', False));
    SendMsg(ControlSock, Msg.Identities, 'shutdown_reply', Msg.Header, Content);
  finally
    Content.Free;
  end;
  Halt(0);
end;

procedure FreeMsg(var Msg: TMsg);
begin
  Msg.Header.Free;
  Msg.Parent.Free;
  Msg.Metadata.Free;
  Msg.Content.Free;
end;

procedure HandleCommInfo(const Msg: TMsg);
var
  Content, CommsObj: TJSONObject;
begin
  { Unser Kernel unterstuetzt keine Comms (Widgets); wir antworten trotzdem
    korrekt mit einer leeren Liste, damit Frontends, die beim Verbindungs-
    aufbau routinemaessig danach fragen, nicht auf eine fehlende Antwort
    warten. }
  Content := TJSONObject.Create;
  try
    CommsObj := TJSONObject.Create;
    Content.Add('comms', CommsObj);
    Content.Add('status', 'ok');
    SendMsg(ShellSock, Msg.Identities, 'comm_info_reply', Msg.Header, Content);
  finally
    Content.Free;
  end;
end;

{ Fuehrt die zum Nachrichtentyp passende Behandlung aus. Nach Jupyter-
  Messaging-Spec wird JEDE auf dem shell- oder control-Kanal empfangene
  Anfrage mit einem "busy"/"idle"-Status-Paar auf iopub eingerahmt - nicht
  nur execute_request. JupyterLab (im Unterschied zu "jupyter console")
  prueft das beim Verbindungsaufbau aktiv: es wartet per "Nudge"-Mechanismus
  auf eine Shell-Antwort UND mindestens eine iopub-Nachricht, um sicher-
  zustellen, dass die PUB/SUB-Verbindung wirklich steht (ZeroMQ-Slow-Joiner-
  Problem). Ohne dieses busy/idle-Paar bleibt der Nudge fuer immer haengen
  und JupyterLab wirft eine Exception beim Oeffnen des Kanals. }
procedure DispatchShell(var Msg: TMsg);
begin
  SendStatus(Msg.Header, 'busy');
  try
    if Msg.MsgType = 'kernel_info_request' then
      HandleKernelInfo(Msg)
    else if Msg.MsgType = 'execute_request' then
      HandleExecute(Msg)
    else if Msg.MsgType = 'is_complete_request' then
      HandleIsComplete(Msg)
    else if Msg.MsgType = 'complete_request' then
      HandleComplete(Msg)
    else if Msg.MsgType = 'comm_info_request' then
      HandleCommInfo(Msg)
    else if Msg.MsgType = 'shutdown_request' then
      HandleShutdown(Msg)
    else
      WriteLn(StdErr, 'Unbekannter Nachrichtentyp: ', Msg.MsgType);
  finally
    SendStatus(Msg.Header, 'idle');
  end;
end;

{ ---------- Hauptschleife ---------- }

procedure MainLoop;
var
  Items: array[0..1] of zmq_pollitem_t;
  RC: LongInt;
  Msg: TMsg;
begin
  FillChar(Items, SizeOf(Items), 0);
  Items[0].socket := ShellSock;
  Items[0].events := ZMQ_POLLIN;
  Items[1].socket := ControlSock;
  Items[1].events := ZMQ_POLLIN;

  while True do
  begin
    RC := zmq_poll(@Items[0], 2, -1);
    if RC <= 0 then Continue;

    if (Items[0].revents and ZMQ_POLLIN) <> 0 then
    begin
      if RecvMsg(ShellSock, Msg) then
      begin
        DispatchShell(Msg);
        FreeMsg(Msg);
      end;
    end;

    if (Items[1].revents and ZMQ_POLLIN) <> 0 then
    begin
      if RecvMsg(ControlSock, Msg) then
      begin
        if Msg.MsgType = 'shutdown_request' then
          HandleShutdown(Msg)
        else
          DispatchShell(Msg);
        FreeMsg(Msg);
      end;
    end;
  end;
end;

{ ---------- Programmstart ---------- }

begin
  Randomize;

  {$IFDEF UNIX}
  InstallSignalHandlers;
  {$ENDIF}

  if ParamCount < 1 then
  begin
    WriteLn('Verwendung: ', ExtractFileName(ParamStr(0)), ' <connection_file>');
    Halt(1);
  end;

  if not LoadZMQ() then
  begin
    WriteLn(StdErr, 'Konnte libzmq nicht laden. Bitte ZeroMQ installieren ',
      '(z.B. "apt install libzmq5").');
    Halt(1);
  end;

  LoadConnectionFile(ParamStr(1));
  SessionID := NewUUID;
  ExecCount := 0;

  SetupSockets;
  BeginThread(@HeartbeatThread);

  { Kurze Pause + initiale "starting"-Statusmeldung: reale Jupyter-Kernel
    tun dies beim Start, und es hilft zusaetzlich gegen das ZeroMQ-PUB/SUB-
    "Slow-Joiner"-Problem, bei dem frueh gesendete iopub-Nachrichten
    verloren gehen koennen, waehrend sich das SUB-Abonnement des Frontends
    noch aufbaut. }
  Sleep(200);
  SendStatus(nil, 'starting');

  WriteLn(StdErr, 'Free Pascal Kernel gestartet (Session ', SessionID, ')');

  MainLoop;
end.
